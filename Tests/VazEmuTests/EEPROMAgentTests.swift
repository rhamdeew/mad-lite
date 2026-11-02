import Foundation
import Testing
import VazCore
@testable import VazEmu

@Suite struct EEPROMAgentTests {
    func rom() throws -> [UInt8] {
        Array(try Data(contentsOf: firmwareDir.appendingPathComponent("j5/j5v05l19/J5V05L19.BIN")))
    }

    /// Reads the modeled 24C04 back byte for byte through the bit-banged I²C agent.
    @Test func readsEEPROM() async throws {
        let line = BootstrapEmulatorTransport(image: try rom())
        var ee = (0..<512).map { UInt8(($0 * 7 + 3) & 0xFF) }   // a recognizable pattern
        await line.setEEPROM(ee)
        ee = await line.getEEPROM()
        let loader = BootstrapClient(transport: line)
        try await loader.synchronize()
        try await loader.startEEPROMAgent()
        let read = try await loader.readEEPROM(size: 512)
        #expect(read == ee)
    }

    /// Writes an EEPROM image (with the immobilizer defeated) and reads it back.
    @Test func writesEEPROM() async throws {
        let line = BootstrapEmulatorTransport(image: try rom())
        var trained = [UInt8](repeating: 0xFF, count: 512)
        for i in Immobilizer.stateRange { trained[i] = [0xFF, 0x7F][i % 2] }
        await line.setEEPROM(trained)
        let loader = BootstrapClient(transport: line)
        try await loader.synchronize()
        try await loader.startEEPROMAgent()
        let defeated = Immobilizer.defeat(eeprom: try await loader.readEEPROM(size: 512))
        try await loader.programEEPROM(defeated)   // write + read-back verify (ACK-polled)
        #expect(await line.getEEPROM() == defeated)
        #expect(!Immobilizer.isTrained(eeprom: await line.getEEPROM()))
    }
}
