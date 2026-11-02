import Foundation
import Testing
import VazCore
@testable import VazEmu

/// What the J5LS builds we have (N35, V2) answer, as a forecast for later builds.
@Suite(.serialized) struct J5LSFrameTests {
    func session(_ path: String, adc: [Int: UInt16] = [:]) async throws -> (EmulatorTransport, KWPClient) {
        let line = EmulatorTransport(rom: Array(try Data(contentsOf: firmwareDir.appendingPathComponent(path))))
        for (channel, value) in adc { await line.setADC(channel: channel, value: value) }
        try await line.boot()
        let client = KWPClient(transport: line)
        try await client.connect()
        return (line, client)
    }

    /// N35's `21 0D` is the 2020 layout, only shorter: each value sits at its documented offset.
    @Test(.enabled(if: hasFirmware("j5ls/J5LS_N35.BIN"))) func n35RecordFollowsTheDocument() async throws {
        let (line, c) = try await session("j5ls/J5LS_N35.BIN",
                                          adc: [0: 200, 1: 600, 3: 100, 4: 300, 10: 90, 14: 500, 12: Sensors.heaterCurrentOK])
        #expect(try await c.detectExtendedRecord() == 0x0D)
        await line.setCrank(rpm: 2000)
        try await line.run(ms: 1500)
        let e = try await c.readExtended(record: 0x0D)
        #expect(e.raw.count == 61)
        #expect(abs(e.mafOrMapVolts - 200 * 5 / 1024) < 0.03)
        #expect(abs(e.throttleVolts - 100 * 5 / 1024) < 0.03)
        #expect(abs(e.coolantVolts - 300 * 5 / 1024) < 0.03)
        #expect(abs(e.airTempVolts - 500 * 5 / 1024) < 0.03) // pin 51 (channel 14)
        #expect(abs(e.rpm - 2000) <= 40)
        #expect(abs(e.preciseRPM - 2000) < 20)
        // Pressure bytes 52–54 are sent but stay zero (N35 has no MAP pressure grid yet);
        // idle error (71), knock A/D (72–75) and gear (76) are past the end.
        #expect(e.has(54) && e.manifoldPressure == 0 && !e.has(71))
        // The log gets empty cells, not zeros, for what the record lacks.
        let row = LogSchema.values(base: try await c.readLiveData(), extended: e)
        let ids = LogSchema.channels(extended: true).map(\.id)
        #expect(ids.count == row.count)
        #expect(row[ids.firstIndex(of: "gear")!].isNaN)
        #expect(!row[ids.firstIndex(of: "map_kpa")!].isNaN)
    }

    /// V2 has no extended record yet; like N35 it answers `21 03` and service `30`.
    @Test(arguments: available(["j5ls/J5LS_V2.bin", "j5ls/J5LS_N35.BIN"]))
    func inputsAndControl(_ path: String) async throws {
        let (line, c) = try await session(path)
        if path.hasSuffix("V2.bin") { #expect(try await c.detectExtendedRecord() == nil) }
        #expect(try await c.readInputs() != nil)
        try await c.control(.output(.checkEngine, on: true))
        try await line.run(ms: 300)
        #expect(await line.outputDriverImage.map { $0 & 0x10 != 0 } == true)
        try await c.control(.returnControl(ActuatorCommand.Output.checkEngine.rawValue))
    }
}
