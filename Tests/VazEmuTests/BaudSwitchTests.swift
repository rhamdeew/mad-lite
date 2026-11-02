import Foundation
import Testing
import VazCore
@testable import VazEmu

/// `10 81 <baud>` (OpenOLT's «скорость соединения»): J5LS builds really retune UART 0, the stock
/// J5V05L19 answers `50 81` but stays at 10400. V43 code at `C68E`: `26` → S0REL `3F3`
/// (38462 baud), `39` → `3F7` (55556 baud, not 57600 — set the port to 55556), anything else
/// keeps `3D0` (10417). Emulator, 28.10.2026; not tried on a live ECU.
@Suite(.serialized) struct BaudSwitchTests {
    func reload(after code: UInt8, _ path: String) async throws -> (answer: [UInt8], reload: Int) {
        let line = EmulatorTransport(rom: Array(try Data(contentsOf: firmwareDir.appendingPathComponent(path))))
        try await line.boot()
        let c = KWPClient(transport: line)
        try await c.connect()
        let answer = try await c.request([0x10, 0x81, code])
        try await line.run(ms: 50)
        return (answer, await line.serialReload())
    }

    @Test(arguments: available(["j5ls/J5LS_V43.bin", "j5ls/J5LS_N35.BIN", "j5ls/J5TRS243_olt.bin", "j5ls/J5LS_L43.bir"]))
    func j5lsSwitchesSpeed(_ path: String) async throws {
        #expect(try await reload(after: 0x26, path) == ([0x50, 0x81], 0x3F3))
        #expect(try await reload(after: 0x39, path) == ([0x50, 0x81], 0x3F7))
    }

    @Test func stockFirmwareAcknowledgesButStaysAt10400() async throws {
        #expect(try await reload(after: 0x39, "j5/j5v05l19/J5V05L19.BIN") == ([0x50, 0x81], 0x3D0))
    }
}
