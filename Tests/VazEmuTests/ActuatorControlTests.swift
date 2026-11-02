import Foundation
import Testing
import VazCore
@testable import VazEmu

/// Service 30 against the real firmware in the emulator.
@Suite(.serialized) struct ActuatorControlTests {
    func idlingECU(_ path: String) async throws -> (KWPClient, EmulatorTransport) {
        let line = EmulatorTransport(rom: Array(try Data(contentsOf: firmwareDir.appendingPathComponent(path))))
        await line.setADC(channel: Sensors.coolantChannel, value: Sensors.coolant(celsius: 90))
        await line.setADC(channel: Sensors.voltageChannel, value: Sensors.supply(volts: 14))
        await line.setADC(channel: Sensors.mafChannel, value: Sensors.voltage(1.2))
        await line.setADC(channel: Sensors.throttleChannel, value: Sensors.voltage(0.5))
        try await line.boot()
        let client = KWPClient(transport: line, interRequestDelay: .zero)
        try await client.connect()
        await line.setCrank(rpm: 850)
        try await line.run(ms: 3000)
        return (client, line)
    }

    /// `30 42 07 N` takes over the idle target: the `21 01` desired idle speed follows it.
    @Test func idleTargetFollowsTheCommand() async throws {
        let (client, line) = try await idlingECU("j5/j5v05l19/J5V05L19.BIN")
        #expect(try await client.control(.idleRPM(1200)).prefix(3) == [0x70, 0x42, 0x07])
        try await line.run(ms: 1500)
        #expect(try await client.readLiveData().idleRpmTarget == 1200)
        #expect(try await client.returnAllControl().contains(0x42))
    }

    /// The idle air valve command is build-specific: J5V05L19 rejects it (12), J5V07G26 takes it.
    @Test func iacPositionDependsOnTheBuild() async throws {
        let (l19, _) = try await idlingECU("j5/j5v05l19/J5V05L19.BIN")
        await #expect(throws: KWPError.negativeResponse(service: 0x30, code: 0x12)) {
            try await l19.control(.iacPosition(60))
        }
        let (g26, _) = try await idlingECU("j5/j5v07g26/J5V07G26.BIN")
        #expect(try await g26.control(.iacPosition(60)) == [0x70, 0x61, 0x08, 60])
    }

    /// Relays: on / off are echoed; returning control is acknowledged.
    @Test func relaysOnOffAndReturn() async throws {
        let (client, _) = try await idlingECU("j5/j5v05l19/J5V05L19.BIN")
        #expect(try await client.control(.output(.fan, on: true)) == [0x70, 0x0A, 0x06, 0x01])
        #expect(try await client.control(.output(.checkEngine, on: false)) == [0x70, 0x0C, 0x06, 0x00])
        #expect(try await client.returnAllControl(ids: [0x0A, 0x0C]) == [0x0A, 0x0C])
    }

    @Test func requestsAreClamped() {
        #expect(ActuatorCommand.idleRPM(9000).request == [0x30, 0x42, 0x07, 255])
        #expect(ActuatorCommand.iacPosition(0).request == [0x30, 0x61, 0x08, 8])
    }
}
