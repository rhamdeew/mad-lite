import Foundation
import Testing
@testable import VazCore

@Suite struct SensorLogTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vazlog-\(UUID().uuidString)")
    }

    @Test func valuesMatchChannelCount() throws {
        let base = try J5LiveData(response: KWPClientTests.liveFrame)
        let ext = try J5LSLiveData(response: J5LSExtendedTests.record)
        #expect(LogSchema.values(base: base, extended: nil).count == LogSchema.channels(extended: false).count)
        #expect(LogSchema.values(base: base, extended: ext).count == LogSchema.channels(extended: true).count)
    }

    /// Later J5LS V43 on a live ECU (27.10.2026, MAP plugged in): byte 52 stays `3C` (1.172 V) whatever
    /// the sensor does, the pin 40 voltage is byte 26 (`3B`, 1.152 V, same as `21 03`).
    @Test func mapVoltageComesFromPin40Byte() throws {
        let hex = "61 0D 11 04 03 00 00 00 00 00 33 00 16 00 00 00 00 00 6D 6D 80 1E 00 00 00 00 00 00 3B 4D 00 18 B7 13 5D 00 00 00 91 AB DB 00 00 48 FF 00 00 00 00 00 00 00 00 96 3C 14 1D 00 00 00 FF 00 00 DB 1D 2D 2D 2D 2D C2 8E 01 00 00 00 00 00 00 00 00 00 FF 00 2D 00 00 00 00 00 00 00 00 00 09 80 FA FD AB 38 45 1A 00 00 00 80 01 49 18 14"
        let ext = try J5LSLiveData(response: hex.split(separator: " ").map { UInt8($0, radix: 16)! })
        let base = try J5LiveData(response: KWPClientTests.liveFrame)
        let channels = LogSchema.channels(extended: true)
        let row = LogSchema.values(base: base, extended: ext)
        let mapV = row[channels.firstIndex { $0.id == "map_v" }!]
        #expect(abs(mapV - 59 * 5 / 256.0) < 0.001)
        #expect(abs(ext.manifoldPressure - 74.44) < 0.01)
    }

    @Test func troubleCodesGoToSessionAndTimeline() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = LogSession(started: start, softwareID: nil, romChecksum: nil, source: "test",
                                 extendedRecord: nil, appVersion: "0", notes: "", channels: LogSchema.base)
        let log = try SensorLogWriter(directory: dir, name: "log", session: session)
        let dtcs = try DTC.parse(response: [0x58, 0x01, 0x01, 0x22, 0x20])
        log.recordTroubleCodes(dtcs, at: start.addingTimeInterval(0.5))
        try log.append(LogSchema.values(base: try J5LiveData(response: KWPClientTests.liveFrame), extended: nil),
                       at: start.addingTimeInterval(0.6))
        let read = try SensorLog(directory: dir)
        #expect(read.markers.first?.text == "коды: P0122")
        #expect(read.session?.troubleCodes?.first?.timeMs == 500)
        #expect(read.session?.troubleCodes?.first?.codes == ["P0122 Низкий уровень сигнала с датчика положения дросселя (статус 20)"])
    }

    @Test func marksBeforeTheSameRowAreJoined() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = LogSession(started: start, softwareID: nil, romChecksum: nil, source: "test",
                                 extendedRecord: nil, appVersion: "0", notes: "", channels: LogSchema.base)
        let log = try SensorLogWriter(directory: dir, name: "log", session: session)
        let base = try J5LiveData(response: KWPClientTests.liveFrame)
        log.mark("обрыв связи", at: start)
        log.mark("связь восстановлена", at: start.addingTimeInterval(1))
        try log.append(LogSchema.values(base: base, extended: nil), at: start.addingTimeInterval(1.2))
        let read = try SensorLog(directory: dir) // before finish(): the session file is already current
        #expect(read.markers.first?.text == "обрыв связи; связь восстановлена")
        #expect(read.session?.markers.count == 2)
    }

    /// Raw exchanges go to log.kwp.txt, named in the session description.
    @Test func rawFramesAreKept() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = LogSession(started: start, softwareID: "J5V05L19", romChecksum: nil, source: "test",
                                 extendedRecord: nil, appVersion: "0", notes: "", channels: LogSchema.base)
        let log = try SensorLogWriter(directory: dir, name: "log", session: session)
        try log.appendRaw(request: [0x21, 0x01], response: [0x61, 0x01, 0x0A], at: start.addingTimeInterval(0.25))
        try log.finish()
        let text = try String(contentsOf: log.rawURL, encoding: .utf8)
        #expect(log.rawURL.lastPathComponent == "log.kwp.txt")
        #expect(text == "250 > 21 01 < 61 01 0A\n")
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        #expect(try d.decode(LogSession.self, from: Data(contentsOf: log.jsonURL)).rawFrames == "log.kwp.txt")
    }

    @Test func writesCSVAndSession() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = LogSession(started: start, softwareID: "J5V05L19", romChecksum: "7602", source: "test",
                                 extendedRecord: "8C", appVersion: "0", notes: "",
                                 channels: LogSchema.channels(extended: true))
        let log = try SensorLogWriter(directory: dir, name: "run", session: session)
        let base = try J5LiveData(response: KWPClientTests.liveFrame)
        let ext = try J5LSLiveData(response: J5LSExtendedTests.record)
        try log.append(LogSchema.values(base: base, extended: ext), at: start.addingTimeInterval(0.1))
        log.mark("провал, при разгоне", at: start.addingTimeInterval(0.15))
        try log.append(LogSchema.values(base: base, extended: ext), at: start.addingTimeInterval(0.2))
        try log.finish()

        let lines = try String(contentsOf: log.csvURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("time_ms,rpm,coolant,throttle,ignition"))
        #expect(lines[0].hasSuffix(",map_kpa,air_temp,wb_afr,target_afr,rpm_precise,knock1,knock2,knock3,knock4,knock_v1,knock_v2,knock_v3,knock_v4,inj_phase,accel_fuel_thr,accel_fuel_map,idle_rpm_err,octane,boost_duty,gear,fuel_press,oil_press,ign_volt,tps_v,map_v,clt_v,iat_v,marker"))
        #expect(lines[1].hasPrefix("100,3000,90,12,14.0,8.000,14.70")) // RPM, throttle, injection from the record
        #expect(lines[1].contains(",101.32,25,14.70,"))
        #expect(lines[1].hasSuffix(","))
        #expect(lines[2].hasPrefix("200,"))
        #expect(lines[2].hasSuffix(",\"провал, при разгоне\""))

        let saved = try { () throws -> LogSession in
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return try d.decode(LogSession.self, from: Data(contentsOf: log.jsonURL))
        }()
        #expect(saved.rows == 2)
        #expect(saved.markers == [LogMarker(timeMs: 150, text: "провал, при разгоне")])
        #expect(saved.channels.first?.name == "Обороты")
    }
}
