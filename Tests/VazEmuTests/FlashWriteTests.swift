import Foundation
import Testing
import VazCore
@testable import VazEmu

@Suite struct FlashWriteTests {
    func image(_ path: String = "j5/j5v05l19/J5V05L19.BIN") throws -> [UInt8] {
        Array(try Data(contentsOf: firmwareDir.appendingPathComponent(path)))
    }

    /// Erase then program a different image into a blank chip, verifying by read-back.
    @Test func programImageEraseWriteVerify() async throws {
        let blank = try image("j5/j5v05n35/J5V05N35.bin")
        let target = try image("j5/j5v05l19/J5V05L19.BIN")
        let line = BootstrapEmulatorTransport(image: blank)
        let loader = BootstrapClient(transport: line)
        try await loader.synchronize()
        try await loader.startWriteAgent()
        // programImage erases, writes, then reads back and compares byte for byte.
        try await loader.programImage(target)
        let writes = await line.flashWrites
        #expect(!writes.erased.isEmpty && writes.programmed > 0)
        // The flash holds the target image.
        #expect(await line.flashWindow == target)
    }

    /// Chip erase leaves every byte FFh.
    @Test func chipErase() async throws {
        let line = BootstrapEmulatorTransport(image: try image())
        let loader = BootstrapClient(transport: line)
        try await loader.synchronize()
        try await loader.startWriteAgent()
        try await loader.eraseChip()
        let read = try await loader.readFlash(count: 0x200)
        #expect(read.allSatisfy { $0 == 0xFF })
    }

    /// Erase then a small write at an offset, read back.
    @Test func eraseThenSmallWrite() async throws {
        let line = BootstrapEmulatorTransport(image: try image())
        let loader = BootstrapClient(transport: line)
        try await loader.synchronize()
        try await loader.startWriteAgent()
        try await loader.eraseChip()
        try await loader.writeFlash([0xAA, 0x55, 0x10, 0x20], from: 0x100)
        let read = try await loader.readFlash(from: 0x100, count: 4)
        #expect(read == [0xAA, 0x55, 0x10, 0x20] as [UInt8])
    }

    // MARK: - Safe programming (2026-10-31, before the first live write)

    func ready(_ rom: [UInt8]) async throws -> (BootstrapEmulatorTransport, BootstrapClient) {
        let line = BootstrapEmulatorTransport(image: rom)
        let loader = BootstrapClient(transport: line)
        try await loader.synchronize()
        try await loader.startWriteAgent()
        return (line, loader)
    }

    /// Sector erase only: the other 64 KB bank of the 128 KB chip keeps its contents.
    @Test func programImageLeavesTheOtherBankAlone() async throws {
        let (line, loader) = try await ready(try image("j5/j5v05n35/J5V05N35.bin"))
        let otherBank = (0..<0x10000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        await line.withFlash { f in for i in 0..<0x10000 { f.memory[0x10000 + i] = otherBank[i] } }
        let target = try image("j5/j5v05l19/J5V05L19.BIN")
        let report = try await loader.programImage(target)
        #expect(await line.flashWindow == target)
        #expect(await line.withFlash { Array($0.memory[0x10000..<0x20000]) } == otherBank)
        #expect(await line.flashWrites.erased.allSatisfy { $0 < 4 })
        #expect(!report.sectors.isEmpty)
    }

    /// The same image: nothing is erased or programmed; `force` rewrites all four sectors.
    @Test func identicalImageIsNotRewrittenUnlessForced() async throws {
        let rom = try image("j5/j5v05n35/J5V05N35.bin")
        let (line, loader) = try await ready(rom)
        let none = try await loader.programImage(rom)
        #expect(none.sectors.isEmpty && none.differingBytes == 0)
        let w0 = await line.flashWrites
        #expect(w0.erased.isEmpty && w0.programmed == 0)
        let all = try await loader.programImage(rom, force: true)
        #expect(all.sectors == [0, 1, 2, 3])
        #expect(await line.flashWindow == rom)
        #expect(await line.flashWrites.erased.sorted() == [0, 1, 2, 3])
    }

    /// Only the sectors that differ are erased and written.
    @Test func onlyDifferingSectorsAreErased() async throws {
        let rom = try image()
        var edited = rom
        edited[0x9000] ^= 0x01
        edited[0x9001] ^= 0x01
        let (line, loader) = try await ready(rom)
        let report = try await loader.programImage(edited)
        #expect(report.sectors == [2] && report.differingBytes == 2)
        #expect(await line.flashWindow == edited)
    }

    /// An image with a bootstrap info block would lock out the serial loader: refused
    /// before anything is erased.
    @Test func infoBlockImageIsRefused() async throws {
        var rom = try image()
        let (line, loader) = try await ready(rom)
        let start = 0x7000, length = 0x10
        let (c1, c2) = BootstrapLoader.flashChecksum(rom[start..<start + length])
        rom.replaceSubrange(0xC000..<0xC00A, with: BootstrapLoader.infoBlockID + [0x70, 0x00, 0x00, 0x10, c1, c2])
        #expect(FlashWriteAgent.refusalReason(rom) != nil)
        await #expect(throws: FlashWriteError.self) { try await loader.programImage(rom) }
        let w = await line.flashWrites
        #expect(w.erased.isEmpty && w.programmed == 0)
    }

    /// A sector that will not erase (DQ5): the agent answers E5 instead of hanging.
    @Test func eraseFailureIsReported() async throws {
        let rom = try image()
        let (line, loader) = try await ready(rom)
        await line.withFlash { $0.faultySectors = [1] }
        await #expect(throws: FlashWriteError.eraseFailed(FlashWriteAgent.eraseFailed)) {
            try await loader.programImage(rom, force: true)
        }
        // The agent is still alive and the chip back in read mode: sector 0 reads back.
        let back = try await loader.readFlash(count: 0x100)
        #expect(back.count == 0x100)
    }

    /// A byte that will not program (DQ5): the agent resets the chip, swallows the rest of
    /// the chunk and answers the XOR inverted → `programFailed`, then keeps serving.
    @Test func programFailureIsReported() async throws {
        let rom = try image()
        let (line, loader) = try await ready(rom)
        try await loader.eraseSector(3)
        await line.withFlash { $0.faultySectors = [3] }
        await #expect(throws: FlashWriteError.programFailed(address: 0xC000)) {
            try await loader.writeFlash(Array(rom[0xC000..<0xC400]), from: 0xC000)
        }
        let id = try await loader.flashID()
        #expect(id.manufacturer == 0x01 && id.device == 0x20)
    }
}
