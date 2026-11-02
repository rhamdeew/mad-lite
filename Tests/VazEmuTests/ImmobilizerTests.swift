import Foundation
import Testing
import VazCore
@testable import VazEmu

@Suite struct ImmobilizerTests {
    /// State helpers on raw EEPROM bytes.
    @Test func stateDetection() {
        var e = [UInt8](repeating: 0xFF, count: 512)
        #expect(!Immobilizer.isTrained(eeprom: e))        // blank = not trained
        #expect(!Immobilizer.needsDefeat(eeprom: e))
        for i in Immobilizer.stateRange { e[i] = [0xFF, 0x7F][i % 2] } // F47D copies bit7=0
        #expect(Immobilizer.isTrained(eeprom: e))
        #expect(Immobilizer.needsDefeat(eeprom: e))
        let d = Immobilizer.defeat(eeprom: e)
        #expect(!Immobilizer.isTrained(eeprom: d))
        #expect(Array(d[Immobilizer.stateRange]) == [UInt8](repeating: 0xFF, count: 6))
        #expect(Array(d[0x08...]) == Array(e[0x08...]))   // nothing else touched
    }

    /// End to end in the emulator: a trained EEPROM blocks the engine (rpm 0); the defeated
    /// copy lets it run again.
    @Test func defeatLetsEngineRun() async throws {
        func rpm(eeprom: [UInt8]) async throws -> Double {
            let rom = try Data(contentsOf: firmwareDir.appendingPathComponent("j5/j5v05l19/J5V05L19.BIN"))
            let line = EmulatorTransport(rom: Array(rom))
            await line.setADC(channel: Sensors.coolantChannel, value: Sensors.coolant(celsius: 90))
            await line.setADC(channel: Sensors.voltageChannel, value: Sensors.supply(volts: 14))
            await line.setADC(channel: Sensors.mafChannel, value: Sensors.voltage(1.0))
            await line.setEEPROM(Array(eeprom[Immobilizer.stateRange]), at: 2)
            try await line.boot()
            let c = KWPClient(transport: line)
            try await c.connect()
            await line.setCrank(rpm: 1500)
            var last = 0.0
            for _ in 0..<7 { try await line.run(ms: 1000); last = try await c.readLiveData().rpm }
            return last
        }
        var trained = [UInt8](repeating: 0xFF, count: 512)
        for i in Immobilizer.stateRange { trained[i] = [0xFF, 0x7F][i % 2] }
        #expect(try await rpm(eeprom: trained) == 0)                        // blocked
        #expect(try await rpm(eeprom: Immobilizer.defeat(eeprom: trained)) > 1000) // runs
    }
}
