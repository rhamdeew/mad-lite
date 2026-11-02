import Foundation
import Testing
@testable import VazCore

/// firmware/ directory at the repository root.
let firmwareDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("firmware")

/// Images outside firmware/j5 and firmware/j72 are not in the public edition: tests on them
/// use `.enabled(if:)` or `available(_:)`, so they run where the image exists.
func hasFirmware(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: firmwareDir.appendingPathComponent(path).path)
}

func available(_ paths: [String], in folder: String = "") -> [String] {
    paths.filter { hasFirmware(folder + $0) }
}

func load(_ path: String) throws -> Firmware {
    try Firmware(contentsOf: firmwareDir.appendingPathComponent(path))
}

@Suite struct FirmwareParsingTests {
    @Test func january51Header() throws {
        let fw = try load("j5/j5v05l19/J5V05L19.BIN")
        #expect(fw.format == .raw)
        #expect(fw.size == 0x10000)
        #expect(fw.family == .january51)
        #expect(fw.softwareID == "J5V05L19")
        #expect(fw.header?.buildDate == "08/05/2003 12:00")
        #expect(fw.header?.model == "2112")
    }

    @Test func january51Identification() throws {
        let id = try #require(try load("j5/j5v05l19/J5V05L19.BIN").identification)
        #expect(id.softwareCode == "1411010-41")
        #expect(id.engine == "SAMARA-1.5L,16V")
        #expect(id.date == "08-05-2003")
        #expect(id.softwareID == "J5V05L19")
    }

    @Test func january72Header() throws {
        let fw = try load("j72/i203el36/I203el36.bin")
        #expect(fw.family == .january72)
        #expect(fw.softwareID == "I203EL36")
        #expect(fw.header?.model == "2111")
        #expect(fw.identification?.softwareCode == "1411010-82")
        #expect(fw.identification?.engine == "SAMARA-1.5L, 8V")
    }

    @Test func smsSoftCompressedIsDetected() throws {
        let fw = try load("j72/i201co58/I201CO58.bin")
        #expect(fw.format == .smsSoftCompressed)
        #expect(fw.header == nil)
        #expect(fw.family == .unknown)
    }

    @Test func emptyDataThrows() {
        #expect(throws: FirmwareError.empty) { try Firmware(data: Data()) }
    }

    /// Every raw 64 KB image from the test set must yield a software ID and a known family.
    @Test func allRawImagesHaveSoftwareID() throws {
        let files = FileManager.default.enumerator(at: firmwareDir, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { ["bin", "abs"].contains($0.pathExtension.lowercased()) && !$0.path.contains("/archives/") }
        var checked = 0
        for url in files {
            let fw = try Firmware(contentsOf: url)
            guard fw.format == .raw, fw.size >= 0x10000 else { continue }
            #expect(fw.softwareID != nil, "\(url.lastPathComponent)")
            #expect(fw.family != .unknown, "\(url.lastPathComponent)")
            checked += 1
        }
        #expect(checked > 50)
    }
}

@Suite struct FirmwareDiffTests {
    @Test func identicalDataHasNoRanges() {
        let d = Data([1, 2, 3])
        #expect(FirmwareDiff.ranges(d, d).isEmpty)
    }

    @Test func separateAndMergedRanges() {
        let a = Data([0, 0, 0, 0, 0, 0])
        let b = Data([1, 0, 1, 1, 0, 0])
        #expect(FirmwareDiff.ranges(a, b) == [0..<1, 2..<4])
        #expect(FirmwareDiff.ranges(a, b, mergeGap: 1) == [0..<4])
    }

    @Test func sizeMismatchReportsTail() {
        #expect(FirmwareDiff.ranges(Data([1, 2]), Data([1, 2, 3, 4])) == [2..<4])
    }

    /// "a" variants have ROM checksum control disabled, so they differ from the original only slightly.
    @Test func romCheckDisabledVariantDiffersSlightly() throws {
        let original = try load("j5/j5v05l19/J5V05L19.BIN")
        let patched = try load("j5/j5v05l19a/J5v05l19a.bin")
        let ranges = FirmwareDiff.ranges(original.data, patched.data)
        #expect(!ranges.isEmpty)
        #expect(FirmwareDiff.byteCount(ranges) < 64)
    }
}

@Suite struct HexFormatterTests {
    @Test func formatting() {
        #expect(HexFormatter.offset(0x6020) == "06020")
        #expect(HexFormatter.byte(0x0A) == "0A")
        #expect(HexFormatter.asciiChar(0x41) == "A")
        #expect(HexFormatter.asciiChar(0x00) == ".")
    }

    @Test func parseOffset() {
        #expect(HexFormatter.parseOffset("6020") == 0x6020)
        #expect(HexFormatter.parseOffset("0x6020") == 0x6020)
        #expect(HexFormatter.parseOffset("$FF") == 0xFF)
        #expect(HexFormatter.parseOffset("zz") == nil)
    }
}
