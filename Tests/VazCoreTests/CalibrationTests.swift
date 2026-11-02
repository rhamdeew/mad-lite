import Foundation
import Testing
@testable import VazCore

@Suite struct CalibrationTests {
    let fw: Firmware
    let def: CalibrationDefinition

    init() throws {
        fw = try load("j5/j5v05l19/J5V05L19.BIN")
        def = try #require(fw.definition)
    }

    func table(_ id: String) throws -> TableDefinition {
        try #require(def.tables.first { $0.id == id })
    }

    @Test func definitionIsFoundBySoftwareID() {
        #expect(def.softwareIDs == ["J5V05L19"])
        #expect(def.tables.count > 200)
    }

    @Test func tablesStayInsideCalibrationArea() {
        for t in def.tables {
            // 0x5Fxx holds a few constants used by the fuel code (e.g. minimum pulse at 0x5FA8).
            #expect(t.address >= 0x5F00 && t.byteRange.upperBound <= 0xA000, "\(t.id)")
        }
    }

    /// Nodes of the 16-point RPM grid derived from the 0x613C mapping table.
    @Test func rpmGrid() throws {
        let rpm = try #require(def.axes["rpm16"]?.values(in: fw.data))
        #expect(rpm.map { Int($0.rounded()) } ==
            [600, 720, 840, 990, 1170, 1380, 1650, 1950, 2310, 2730, 3210, 3840, 4530, 5340, 6300, 7470])
    }

    @Test func loadGrid() throws {
        // offset 0x00F0 = 240, gain 171: node k = (240 + k·16·2048/171) / 6
        let load = try #require(def.axes["load16"]?.values(in: fw.data))
        #expect(load.count == 16)
        #expect(abs(load[0] - 40) < 0.01)
        #expect(abs(load[1] - load[0] - 31.94) < 0.01)
    }

    @Test func temperatureGrid() throws {
        let temp = try #require(def.axes["temp"]?.values(in: fw.data))
        #expect(temp.first == -40 && temp[12] == 20 && temp.count == 39)
    }

    @Test func ignitionMapValues() throws {
        let ign = try table("t6AC8")
        #expect(ign.rows == 16 && ign.cols == 16 && ign.xAxis == "rpm16" && ign.yAxis == "load16")
        let values = fw.values(of: ign)
        #expect(values.count == 256)
        #expect(values[0] == 21) // raw 0x2A · 0.5°
        #expect(values[15] == 33) // raw 0x42
    }

    @Test func editingWritesRawByte() throws {
        var copy = fw
        let ign = try table("t6AC8")
        copy.setValue(25.5, of: ign, row: 0, col: 1)
        #expect(copy.data[0x6AC9] == 51)
        #expect(FirmwareDiff.ranges(fw.data, copy.data) == [0x6AC9 ..< 0x6ACA])
    }

    /// Ignition maps are signed (CTP maps; the KWP frame reports УОЗ as signed E/2 too).
    @Test func rawConversionClamps() throws {
        let ign = try table("t6AC8")
        #expect(ign.type == .s8)
        #expect(ign.raw(fromValue: 1000) == 127)
        #expect(ign.raw(fromValue: -5) == -10)
    }

    /// Mixture maps use the KWP AFR formula 14.7·(E+128)/256, so 128 reads as 14.7.
    @Test func mixtureMapInClosedLoopIsStoichiometric() throws {
        let values = fw.values(of: try table("t6713"))
        #expect(values.allSatisfy { abs($0 - 14.7) < 0.001 })
    }

    @Test func idleTargetAtOperatingTemperature() throws {
        let idle = try table("t6F56")
        let temp = try #require(def.axes["temp"]?.values(in: fw.data))
        let i = try #require(temp.firstIndex(of: 90))
        #expect(fw.values(of: idle)[i] == 800)
    }

    @Test func throttleGrid() throws {
        let thr = try #require(def.axes["throttle16"]?.values(in: fw.data))
        #expect(thr.count == 16)
        #expect(thr.first == 0 && thr[1] == 2 && thr.last == 98)
    }

    @Test func minimumInjectionPulseIs16Bit() throws {
        let t = try table("t5FA8")
        #expect(t.type == .u16le && t.byteCount == 2)
        #expect(abs(fw.values(of: t)[0] - 1.6) < 1e-9) // 0x00C8 · 8 µs
        var copy = fw
        copy.setValue(2.0, of: t, row: 0, col: 0) // 250 = 0x00FA
        #expect(copy.bytes(of: t) == [0xFA, 0x00])
    }

    @Test func injectorDeadTimeAt14V() throws {
        let t = try table("t71D8")
        let volts = try #require(def.axes["voltage16"]?.values(in: fw.data))
        let i = try #require(volts.firstIndex { abs($0 - 14.0) < 0.01 })
        #expect(abs(fw.values(of: t)[i] - 0.4) < 1e-9) // 0x32 · 8 µs
    }

    /// Warm-up enrichment fades to 1.0 (0x80) on a warm engine and is strongest when cold.
    @Test func warmUpEnrichment() throws {
        let values = fw.values(of: try table("t7F67"))
        #expect(values.count == 39)
        #expect(values[26] == 1.0) // 90 °C
        #expect(values[0] > 1.9) // −40 °C, 0xFF
    }

    @Test func inverseLookupPlateau() {
        #expect(AxisDefinition.inverse([0, 0, 0, 16, 32], target: 0) == 2)
        #expect(AxisDefinition.inverse([0, 0, 0, 16, 32], target: 8) == 2.5)
        #expect(AxisDefinition.inverse([0, 0, 0, 16, 32], target: 32) == 4)
    }
}
