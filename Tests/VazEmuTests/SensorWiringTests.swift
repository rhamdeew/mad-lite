import Foundation
import Testing
import VazCore
@testable import VazEmu

@Suite struct SensorWiringTests {
    func rom(_ path: String) throws -> [UInt8] {
        Array(try Data(contentsOf: firmwareDir.appendingPathComponent(path)))
    }

    @Test func stockFirmwareUsesMAF() throws {
        let w = Sensors.Wiring.detect(rom: try rom("j5/j5v05l19/J5V05L19.BIN"), softwareID: "J5V05L19")
        #expect(!w.isJ5LS && !w.usesMAP && w.mapChannel == Sensors.mafChannel)
    }

    /// J5LS_N35 as shipped is configured for a MAF (5F05.2 clear) and without intake air sensor
    /// (6051.4 clear); with the flags set the MAP sensor moves to pin 40 and the IAT is read.
    @Test(.enabled(if: hasFirmware("j5ls/J5LS_N35.BIN"))) func j5lsFlagsPickTheInputs() throws {
        var image = try rom("j5ls/J5LS_N35.BIN")
        let shipped = Sensors.Wiring.detect(rom: image, softwareID: "J5LS_N35")
        #expect(shipped.isJ5LS && !shipped.usesMAP && !shipped.hasAirTemp)
        image[0x5F05] |= 0x04
        image[0x6051] |= 0x10
        #expect(Sensors.Wiring.detect(rom: image, softwareID: "J5LS_N35").mapChannel == Sensors.mafChannel)
        image[0x5F07] |= 0x08
        let map = Sensors.Wiring.detect(rom: image, softwareID: "J5LS_N35")
        #expect(map.usesMAP && map.mapChannel == Sensors.mapChannel && map.hasAirTemp)
    }

    /// The heater current sense between the diagnostic thresholds removes P0135, and a
    /// mid-range oxygen sensor voltage the "high signal" fault.
    @Test func heaterCurrentClearsTheHeaterFault() async throws {
        func faults(heater: Bool) async throws -> (live: [String], codes: [String]) {
            let line = EmulatorTransport(rom: try rom("j5/j5v05l19/J5V05L19.BIN"))
            await line.setADC(channel: Sensors.coolantChannel, value: Sensors.coolant(celsius: 90))
            await line.setADC(channel: Sensors.voltageChannel, value: Sensors.supply(volts: 14))
            await line.setADC(channel: Sensors.throttleChannel, value: Sensors.voltage(0.6))
            if heater {
                await line.setADC(channel: Sensors.heaterCurrentChannel, value: Sensors.heaterCurrentOK)
                await line.setADC(channel: Sensors.lambdaChannel, value: Sensors.voltage(0.45))
            }
            try await line.boot()
            let client = KWPClient(transport: line, interRequestDelay: .zero)
            try await client.connect()
            await line.setCrank(rpm: 2000)
            for _ in 0..<5 { try await line.run(ms: 1000); _ = try await client.readLiveData() }
            return (try await client.readLiveData().activeFaults, try await client.readDTCs().map(\.code))
        }
        let without = try await faults(heater: false)
        #expect(without.live.contains("нагреватель ДК") && without.codes.contains("P0135"))
        let with = try await faults(heater: true)
        #expect(!with.live.contains("нагреватель ДК") && !with.codes.contains("P0135"))
        #expect(!with.live.contains("ДК: высокий сигнал"))
    }
}
