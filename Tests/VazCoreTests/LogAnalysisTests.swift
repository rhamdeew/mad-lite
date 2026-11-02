import Foundation
import Testing
@testable import VazCore

@Suite struct LogAnalysisTests {
    let fw: Firmware
    let def: CalibrationDefinition

    init() throws {
        fw = try load("j5/j5v05l19/J5V05L19.BIN")
        def = try #require(fw.definition)
    }

    func table(_ id: String) throws -> TableDefinition { try #require(def.tables.first { $0.id == id }) }

    /// One CSV row every 200 ms with the channels the analysis reads.
    func csv(_ rows: [(rpm: Double, load: Double, trim: Double, lambda: Int, coolant: Double, throttle: Double)]) -> String {
        var text = "time_ms,rpm,coolant,throttle,cycle_air,inj_corr,f_lambda,f_fuel_cut,f_power,marker\n"
        for (n, r) in rows.enumerated() {
            text += "\(n * 200),\(r.rpm),\(r.coolant),\(r.throttle),\(r.load),\(r.trim),\(r.lambda),0,0,\n"
        }
        return text
    }

    @Test func readsBackWhatTheWriterWrote() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vazlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = LogSession(started: start, softwareID: "J5V05L19", romChecksum: "7602", source: "test",
                                 extendedRecord: nil, appVersion: "0", notes: "",
                                 channels: LogSchema.channels(extended: false))
        let writer = try SensorLogWriter(directory: dir, name: "log", session: session)
        let base = try J5LiveData(response: KWPClientTests.liveFrame)
        try writer.append(LogSchema.values(base: base, extended: nil), at: start.addingTimeInterval(0.1))
        writer.mark("провал, при \"разгоне\"", at: start.addingTimeInterval(0.15))
        try writer.append(LogSchema.values(base: base, extended: nil), at: start.addingTimeInterval(0.3))
        try writer.finish()

        let log = try SensorLog(directory: dir)
        #expect(log.count == 2 && log.timeMs == [100, 300])
        #expect(log.channels == LogSchema.channels(extended: false).map(\.id))
        #expect(log.column("rpm") == [800, 800])
        #expect(log.column("afr")?.first == 14.7)
        #expect(log.column("faults")?.first == Double(0x0008_0000)) // ДТОЖ low, word 2 bit 3
        #expect(log.markers.count == 1 && log.markers[0].row == 1 && log.markers[0].text == "провал, при \"разгоне\"")
        #expect(log.session?.softwareID == "J5V05L19")
    }

    @Test func rowOnANodeGoesToOneCell() throws {
        let t = try table("t6813")
        let rpm = try #require(def.axes["rpm16"]?.values(in: fw.data))
        let load = try #require(def.axes["load16"]?.values(in: fw.data))
        let rows = Array(repeating: (rpm: rpm[8], load: load[5], trim: 1.08, lambda: 1, coolant: 90.0, throttle: 20.0),
                         count: 20)
        let a = try FuelCorrectionAnalysis(log: SensorLog(csv: csv(rows)), table: t, definition: def, firmware: fw.data)
        #expect(a.xChannel == "rpm" && a.yChannel == "cycle_air" && a.relation == .proportional)
        // A steady state needs ≥ 0.5 s of history: rows at 0, 200 and 400 ms can't prove it.
        #expect(a.usedRows == 17)
        #expect(abs(a[5, 8].weight - 17) < 1e-9 && abs(a[5, 8].visits - 20) < 1e-9)
        #expect(abs(try #require(a[5, 8].factor) - 1.08) < 1e-9)
        #expect(a.cells.enumerated().allSatisfy { $0.offset == 5 * 16 + 8 || $0.element.visits == 0 })
    }

    @Test func rowBetweenNodesIsSplitLikeTheInterpolation() throws {
        let t = try table("t6813")
        let rpm = try #require(def.axes["rpm16"]?.values(in: fw.data))
        let load = try #require(def.axes["load16"]?.values(in: fw.data))
        let row = (rpm: (rpm[3] + rpm[4]) / 2, load: load[2] + (load[3] - load[2]) / 4, trim: 0.95, lambda: 1,
                   coolant: 90.0, throttle: 10.0)
        let a = try FuelCorrectionAnalysis(log: SensorLog(csv: csv(Array(repeating: row, count: 41))), table: t,
                                           definition: def, firmware: fw.data)
        #expect(abs(a[2, 3].weight - 38 * 0.375) < 1e-6 && abs(a[3, 4].weight - 38 * 0.125) < 1e-6)
        #expect(abs(try #require(a[2, 3].meanTrim) - 0.95) < 1e-9)
    }

    @Test func openLoopColdAndTransientRowsAreDropped() throws {
        let t = try table("t6813")
        let rpm = try #require(def.axes["rpm16"]?.values(in: fw.data))
        let load = try #require(def.axes["load16"]?.values(in: fw.data))
        var rows = Array(repeating: (rpm: rpm[6], load: load[4], trim: 1.0, lambda: 1, coolant: 90.0, throttle: 15.0),
                         count: 10)
        rows += Array(repeating: (rpm: rpm[6], load: load[4], trim: 1.3, lambda: 0, coolant: 90.0, throttle: 15.0),
                      count: 5) // open loop: trim is meaningless
        rows += Array(repeating: (rpm: rpm[6], load: load[4], trim: 1.3, lambda: 1, coolant: 40.0, throttle: 15.0),
                      count: 5) // warm-up
        rows.append((rpm: rpm[6], load: load[4], trim: 1.3, lambda: 1, coolant: 90.0, throttle: 40.0)) // tip-in
        let a = try FuelCorrectionAnalysis(log: SensorLog(csv: csv(rows)), table: t, definition: def, firmware: fw.data)
        #expect(a.rejected["нет регулирования по ДК"] == 5)
        #expect(a.rejected["холодный двигатель"] == 5)
        #expect(a.rejected["переходный режим"] == 4) // three rows at the log start + the tip-in
        #expect(a[4, 6].meanTrim == 1.0)
    }

    /// AFR targets work the other way: 5 % more fuel needed → AFR target 5 % lower.
    @Test func afrMapIsCorrectedInversely() throws {
        let t = try table("t6613")
        let rpm = try #require(def.axes["rpm16"]?.values(in: fw.data))
        let load = try #require(def.axes["load16"]?.values(in: fw.data))
        let rows = Array(repeating: (rpm: rpm[10], load: load[7], trim: 1.05, lambda: 1, coolant: 90.0, throttle: 30.0),
                         count: 12)
        let a = try FuelCorrectionAnalysis(log: SensorLog(csv: csv(rows)), table: t, definition: def, firmware: fw.data)
        #expect(a.relation == .inverse)
        let before = fw.values(of: t)
        let after = a.corrected(before)
        let k = 7 * 16 + 10
        #expect(abs(after[k] - before[k] / 1.05) < 1e-9)
        #expect(after[0] == before[0])
    }

    /// Without the firmware: stock RPM nodes × manifold pressure (J5LS) up to the logged maximum.
    @Test func genericGridWithoutFirmware() throws {
        var text = "time_ms,rpm,coolant,throttle,cycle_air,inj_corr,f_lambda,map_kpa,marker\n"
        for n in 0..<20 { text += "\(n * 200),2310,90,20,150,1.06,1,\(n < 10 ? 60 : 95),\n" }
        let log = try SensorLog(csv: text)
        let grid = try #require(AxisMapping.generic(for: log))
        #expect(grid.x.channel == "rpm" && grid.x.nodes == AxisMapping.stockRPM)
        #expect(grid.y.channel == "map_kpa" && grid.y.nodes.first == 20 && grid.y.nodes.last == 100)
        let a = try FuelCorrectionAnalysis(log: log, x: grid.x, y: grid.y)
        #expect(a.rows == 16 && a.cols == 16 && a.yNodes == grid.y.nodes)
        #expect(a.cells.compactMap(\.meanTrim).allSatisfy { abs($0 - 1.06) < 1e-9 })
        // No pressure in the log: cycle air on the stock grid.
        let noMap = try SensorLog(csv: text.replacingOccurrences(of: ",map_kpa", with: ",x"))
        #expect(AxisMapping.generic(for: noMap)?.y.channel == "cycle_air")
        // Pressure bytes sent but never filled (J5LS N35 logs 0 kPa): not a pressure axis either.
        var zero = "time_ms,rpm,coolant,throttle,cycle_air,inj_corr,f_lambda,map_kpa,marker\n"
        for n in 0..<20 { zero += "\(n * 200),2310,90,20,150,1.06,1,0.00,\n" }
        #expect(AxisMapping.generic(for: try SensorLog(csv: zero))?.y.channel == "cycle_air")
    }

    @Test func throttleAxisUsesThrottleColumn() throws {
        let t = try table("t75EF")
        let rows = Array(repeating: (rpm: 2000.0, load: 150.0, trim: 1.0, lambda: 1, coolant: 90.0, throttle: 20.0),
                         count: 8)
        let a = try FuelCorrectionAnalysis(log: SensorLog(csv: csv(rows)), table: t, definition: def, firmware: fw.data)
        #expect(a.yChannel == "throttle")
    }
}
