import Foundation
import Testing
import VazCore
@testable import VazEmu

@Suite struct BootstrapLoaderTests {
    func image(_ path: String = "j5/j5v05l19/J5V05L19.BIN") throws -> [UInt8] {
        Array(try Data(contentsOf: firmwareDir.appendingPathComponent(path)))
    }

    /// Manual figure 10-5: the first byte goes to checksum #2, the second to #1, each
    /// added and rotated left.
    @Test func flashChecksumAlternatesRegisters() {
        #expect(BootstrapLoader.flashChecksum([0x01, 0x02]) == (0x04, 0x02))
        #expect(BootstrapLoader.flashChecksum([0x80, 0x00, 0x80]) == (0x00, 0x03))
    }

    /// Mode 0 framing: full DATA blocks while the rest does not fit the EOT block, whose
    /// first data byte counts the valid bytes after it.
    @Test func loadBlocksFraming() {
        let code: [UInt8] = Array(1...10)
        let blocks = BootstrapLoader.loadBlocks(code, at: 0xF420, blockLength: 6)
        #expect(blocks[0] == [0x00, 0x00, 0xF4, 0x20, 0x00, 0x00, 0x06, 0xD2] as [UInt8])
        #expect(blocks.dropFirst().allSatisfy { $0.count == 6 })
        #expect(blocks[1] == [0x01, 1, 2, 3, 4, 0x05] as [UInt8])
        #expect(blocks.last == [0x02, 2, 9, 10, 0, 0x03] as [UInt8])
        #expect(blocks.count == 4)
    }

    /// Full path on the model: sync, load the read agent with mode 0, start it with
    /// mode 1, read the flash ID and the whole 64 KB window back.
    @Test func readAgentReadsTheWholeFlash() async throws {
        let rom = try image()
        let line = BootstrapEmulatorTransport(image: rom)
        let loader = BootstrapClient(transport: line)
        try await loader.synchronize()
        try await loader.startReadAgent()
        let id = try await loader.flashID()
        #expect(id.manufacturer == 0x01 && id.device == 0x20)
        let read = try await loader.readFlash()
        #expect(read == rom)
        // Autoselect left the chip in read mode and nothing was written.
        let writes = await line.flashWrites
        #expect(writes.programmed == 0 && writes.erased.isEmpty)
    }

    /// Live spare ECU, 2026-10-31: the XOR of chunk C000 of J5V05N35 is 52h ('R'); its
    /// K-line echo stayed in S0BUF and the agent took it for the next command, so the read
    /// broke at D000. The agent now drops its own echo before each command.
    @Test func ownEchoIsNotACommand() async throws {
        let rom = try image("j5/j5v05n35/J5V05N35.bin")
        #expect(BootstrapLoader.xor(rom[0xC000..<0xD000]) == UInt8(ascii: "R"))
        let line = BootstrapEmulatorTransport(image: rom)
        let loader = BootstrapClient(transport: line)
        try await loader.synchronize()
        try await loader.startReadAgent()
        let id = try await loader.flashID()
        #expect(id.manufacturer == 0x01 && id.device == 0x20)
        let read = try await loader.readFlash(from: 0xC000, count: 0x2000)
        #expect(read == Array(rom[0xC000..<0xE000]))
    }

    /// 'B' selects the other 64 KB half (P6.0 = 0) and back; only reads, nothing written.
    @Test func readsTheOtherFlashHalf() async throws {
        let rom = try image()
        let line = BootstrapEmulatorTransport(image: rom)
        let other = (0..<0x10000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) }
        await line.withFlash { f in for i in 0..<0x10000 { f.memory[0x10000 + i] = other[i] } }
        let loader = BootstrapClient(transport: line)
        try await loader.synchronize()
        try await loader.startReadAgent()
        #expect(try await loader.readFlash(count: 0x1000) == Array(rom[0..<0x1000]))
        try await loader.selectFlashHalf(defaultHalf: false)
        #expect(try await loader.readFlash() == other)
        try await loader.selectFlashHalf(defaultHalf: true)
        #expect(try await loader.readFlash(from: 0xF000, count: 0x1000) == Array(rom[0xF000..<0x10000]))
        let writes = await line.flashWrites
        #expect(writes.programmed == 0 && writes.erased.isEmpty)
    }

    /// Mode 2 compares the computed checksum with the two bytes at start + length + 1/2.
    @Test func checkFlashMode() async throws {
        var rom = try image()
        let (c1, c2) = BootstrapLoader.flashChecksum(rom[0x1000..<0x1100])
        rom[0x1101] = c1; rom[0x1102] = c2
        let loader = BootstrapClient(transport: BootstrapEmulatorTransport(image: rom))
        try await loader.synchronize()
        #expect(try await loader.checkFlash(from: 0x1000, length: 0x100))
        #expect(try await !loader.checkFlash(from: 0x1000, length: 0x0FF))
    }

    /// Corrupted blocks are rejected with FEh and may be resent.
    @Test func badChecksumIsRejected() async throws {
        let loader = BootstrapClient(transport: BootstrapEmulatorTransport(image: try image()))
        try await loader.synchronize()
        var header = BootstrapLoader.header(.checkFlash, address: 0x1000, (0, 4, 0))
        header[7] ^= 0xFF
        #expect(try await loader.exchange(header) == BootstrapLoader.checksumError)
    }

    /// A valid info block at 6000h/C000h locks the loader: phase I starts that code.
    @Test func infoBlockLocksTheLoader() throws {
        var rom = try image()
        let body = Array(rom[0x600A..<0x6020])
        let (c1, c2) = BootstrapLoader.flashChecksum(body)
        rom.replaceSubrange(0x6000..<0x600A, with: BootstrapLoader.infoBlockID + [0x60, 0x0A, 0x00, 0x16, c1, c2])
        #expect(BootstrapLoader.lockingInfoBlock(in: rom) == 0x6000)
        let machine = BootstrapBoard(image: rom)
        #expect(machine.startedFromInfoBlock == 0x6000 && machine.board.cpu.pc == 0x600A)
        // Serial factory images carry no info block.
        #expect(BootstrapLoader.lockingInfoBlock(in: try image()) == nil)
        if hasFirmware("j5ls/J5LS_V43.bin") {
            #expect(BootstrapLoader.lockingInfoBlock(in: try image("j5ls/J5LS_V43.bin")) == nil)
        }
    }
}
