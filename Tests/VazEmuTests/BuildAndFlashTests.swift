import Foundation
import Testing
import VazCore
@testable import VazEmu

/// End-to-end: take a clean J5LS V43 base, set the wiring flags for a
/// car (MAP on pin 40, IAT on 44, 20–300 kPa sensor slope), fix the checksum, flash it into a block
/// through the C509 loader, then boot the *flashed* image as a normal ECU and confirm it runs
/// and reads the MAP sensor. Also flashes a defeated EEPROM and confirms the engine isn't
/// immobilizer-blocked. All in the emulator.
@Suite(.serialized) struct BuildAndFlashTests {
    func fw(_ p: String) throws -> [UInt8] {
        Array(try Data(contentsOf: firmwareDir.appendingPathComponent(p)))
    }

    /// A V43 base: MAP on 40, IAT on 44, slope 65.88 kPa/V (20–300 kPa sensor), CS fixed.
    func userBase() throws -> [UInt8] {
        var d = Data(try fw("j5ls/J5LS_V43.bin"))
        d[0x5F07] |= 0x0C
        d[0x6051] |= 0x10
        let slope = UInt16(65.88 * 500)
        d[0x60D2] = UInt8(slope & 0xFF); d[0x60D3] = UInt8(slope >> 8)
        d[0x60D4] = 0
        try Checksum.fix(&d)
        return Array(d)
    }

    @Test(.enabled(if: hasFirmware("j5ls/J5LS_V43.bin"))) func flashBaseThenItRuns() async throws {
        let base = try userBase()

        // Flash the base into a block that currently holds N35, through the loader.
        let line = BootstrapEmulatorTransport(image: try fw("j5ls/J5LS_N35.BIN"))
        let loader = BootstrapClient(transport: line)
        try await loader.synchronize()
        try await loader.startWriteAgent()
        try await loader.programImage(base)          // erase + write + read-back verify
        let flashed = await line.flashWindow
        #expect(flashed == base)

        // Boot the freshly flashed image as a normal ECU with the user's wiring.
        let ecu = EmulatorTransport(rom: flashed)
        await ecu.setADC(channel: Sensors.coolantChannel, value: Sensors.coolant(celsius: 90))
        await ecu.setADC(channel: Sensors.voltageChannel, value: Sensors.supply(volts: 14))
        await ecu.setADC(channel: Sensors.throttleChannel, value: Sensors.voltage(1.0))
        await ecu.setADC(channel: Sensors.mapChannel, value: Sensors.voltage(1.6))      // ~100 kPa
        await ecu.setADC(channel: Sensors.airTempChannel, value: Sensors.airTemp(celsius: 20, pullUp: 1000))
        try await ecu.boot()
        let c = KWPClient(transport: ecu, interRequestDelay: .zero)
        try await c.connect()
        try await c.startDiagnosticSession()
        await ecu.setCrank(rpm: 2000)
        try await ecu.run(ms: 4000)
        #expect(try await c.readLiveData().rpm == 2000)                 // engine runs
        let rec = try #require(try await c.detectExtendedRecord())      // J5LS extended frame
        let x = try await c.readExtended(record: rec)
        #expect((95...110).contains(x.manifoldPressure), "ДАД \(x.manifoldPressure)")  // MAP read on pin 40
        #expect(x.cycleAir > 0)
    }

    @Test func flashedEEPROMDefeatsImmobilizer() async throws {
        // Block with a trained immobilizer; defeat it through the EEPROM agent.
        let line = BootstrapEmulatorTransport(image: try fw("j5/j5v05l19/J5V05L19.BIN"))
        var trained = [UInt8](repeating: 0xFF, count: 512)
        for i in Immobilizer.stateRange { trained[i] = [0xFF, 0x7F][i % 2] }
        await line.setEEPROM(trained)
        let loader = BootstrapClient(transport: line)
        try await loader.synchronize()
        try await loader.startEEPROMAgent()
        let defeated = Immobilizer.defeat(eeprom: try await loader.readEEPROM(size: 512))
        try await loader.programEEPROM(defeated)
        let flashed = await line.flashWindow                           // unchanged firmware
        let ee = await line.getEEPROM()
        #expect(!Immobilizer.isTrained(eeprom: ee))

        // Boot that firmware with the defeated EEPROM: the engine must run.
        let ecu = EmulatorTransport(rom: flashed)
        await ecu.setADC(channel: Sensors.coolantChannel, value: Sensors.coolant(celsius: 90))
        await ecu.setADC(channel: Sensors.voltageChannel, value: Sensors.supply(volts: 14))
        await ecu.setADC(channel: Sensors.mafChannel, value: Sensors.voltage(1.0))
        await ecu.setEEPROM(Array(ee[Immobilizer.stateRange]), at: 2)
        try await ecu.boot()
        let c = KWPClient(transport: ecu)
        try await c.connect()
        await ecu.setCrank(rpm: 1500)
        var rpm = 0.0
        for _ in 0..<6 { try await ecu.run(ms: 1000); rpm = try await c.readLiveData().rpm }
        #expect(rpm > 1000)                                            // not immobilizer-blocked
    }
}
