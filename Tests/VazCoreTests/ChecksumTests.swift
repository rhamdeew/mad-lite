import Foundation
import Testing
@testable import VazCore

@Suite struct ChecksumTests {
    func rawImages() throws -> [(URL, Firmware)] {
        try FileManager.default.enumerator(at: firmwareDir, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { ["bin", "abs"].contains($0.pathExtension.lowercased()) && !$0.path.contains("/archives/") }
            // Tuned J5LS images and bases built on them: not factory, no ROM check.
            .filter { !$0.path.contains("/j5ls/") && !$0.path.contains("/base/") }
            .map { ($0, try Firmware(contentsOf: $0)) }
            .filter { $0.1.checksum != nil }
    }

    /// Every raw 64 KB factory image (J5.1 and J7.2): sum of all bytes == word at 0xFFFE,
    /// and the word at 0xFFFA is its inverse.
    @Test func allFactoryImagesAreValid() throws {
        let images = try rawImages()
        #expect(images.count > 55)
        for (url, fw) in images {
            let s = try #require(fw.checksum)
            #expect(s.isValid, "\(url.lastPathComponent): \(s)")
            #expect(Checksum.expected(for: fw.data) == s.stored, "\(url.lastPathComponent)")
        }
    }

    /// Published КС values from chiptuner.ru match the stored word.
    @Test func publishedChecksums() throws {
        #expect(try load("j5/j5v05l19/J5V05L19.BIN").checksum?.stored == 0x7602)
        #expect(try load("j5/j5v05l19/J5V05L19.BIN").checksum?.mirror == 0x89FD)
        #expect(try load("j5/j5v13i02/J5v13i02.bin").checksum?.stored == 0xB4CE)
        #expect(try load("j5/j5v26l52/j5v26l52.bin").checksum?.stored == 0xDD82)
    }

    @Test func fixRewritesOnlyChecksumAndMirror() throws {
        let original = try load("j5/j5v05l19/J5V05L19.BIN")
        var fw = original
        fw.write([fw.data[0x6AC9] &+ 10], at: 0x6AC9)
        #expect(fw.checksum?.isValid == false)
        let result = try fw.fixChecksum()
        #expect(fw.checksum?.isValid == true)
        #expect(result.after.stored == 0x7602 &+ 10)
        let changed = FirmwareDiff.ranges(original.data, fw.data)
        // +10 without carry: only the low bytes of the checksum and its mirror change.
        #expect(changed == [0x6AC9 ..< 0x6ACA, 0xFFFA ..< 0xFFFB, 0xFFFE ..< 0xFFFF])
    }

    @Test func randomEditsAlwaysFixable() throws {
        var rng = SystemRandomNumberGenerator()
        let base = try load("j5/j5v05m30/j5v05m30.bin")
        for _ in 0..<20 {
            var fw = base
            for _ in 0..<Int.random(in: 1...300, using: &rng) {
                fw.write([UInt8.random(in: 0...255, using: &rng)], at: Int.random(in: 0x6050..<0xA000, using: &rng))
            }
            try fw.fixChecksum()
            #expect(fw.checksum?.isValid == true)
        }
    }

    /// Factory images read [FFFE] in code; J5LS N35 has no ROM check (FFFE = FF00, no mirror),
    /// J5LS V2 keeps L19's start-up check but its file has a stale sum.
    @Test func romCheckCode() throws {
        for (_, fw) in try rawImages() { #expect(Checksum.isCheckedByFirmware(fw.data), "\(fw.name)") }
    }

    @Test(.enabled(if: hasFirmware("j5ls/J5LS_N35.BIN"))) func romCheckCodeInJ5LS() throws {
        let n35 = try load("j5ls/J5LS_N35.BIN")
        #expect(!Checksum.isCheckedByFirmware(n35.data))
        #expect(n35.checksum?.stored == 0xFF00 && n35.checksum?.mirror == 0)
        let v2 = try load("j5ls/J5LS_V2.bin")
        #expect(Checksum.isCheckedByFirmware(v2.data) && v2.checksum?.isValid == false)
    }

    /// J5LS V43 and J5TRS carry a valid January checksum (mirror = ~FFFE) but never read it
    /// at runtime — editing calibrations needs no checksum-defeat, yet FFFE must stay valid
    /// for CTP/Combiloader. N35's dummy FFFE (no mirror) is not maintained.
    @Test(.enabled(if: hasFirmware("j5ls/J5LS_V43.bin"))) func calibrationCheckIsAbsentButStructureMaintained() throws {
        let v43 = try load("j5ls/J5LS_V43.bin")
        #expect(!Checksum.isCheckedByFirmware(v43.data))        // no runtime ROM/calibration check
        #expect(Checksum.maintainsStructure(v43.data))          // valid January CS structure
        #expect(v43.checksum?.isValid == true)
        let trs = try load("j5ls/J5TRS243_olt.bin")
        #expect(!Checksum.isCheckedByFirmware(trs.data) && Checksum.maintainsStructure(trs.data))
        let n35 = try load("j5ls/J5LS_N35.BIN")
        #expect(!Checksum.maintainsStructure(n35.data))         // dummy FFFE, no mirror → leave alone
    }

    @Test func otherSizesAreRejected() throws {
        var data = Data(count: 0x20000)
        #expect(throws: Checksum.FixError.unsupportedSize(0x20000)) { try Checksum.fix(&data) }
    }
}
