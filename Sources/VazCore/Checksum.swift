import Foundation

/// ROM checksum of Январь 5.1 / 7.2 64 KB images.
///
/// The ECU adds all 65536 bytes into a 16-bit sum (0xE41B at start-up, 0x527B in
/// the background for J5V05L19) and compares it with the little-endian word at
/// 0xFFFE. The word at 0xFFFA holds its bitwise inverse ("mirror"), so the four
/// checksum bytes always add up to 0x1FE and the checksum is simply
/// `sum of all other bytes + 0x1FE`. Verified on all 61 raw 64 KB J5/J7.2 images.
///
/// Some J7.2 versions (I205DM53) also keep partial sums of calibration blocks
/// elsewhere; those are version-specific and not handled here.
public enum Checksum {
    public static let imageSize = 0x10000
    public static let storedOffset = 0xFFFE
    public static let mirrorOffset = 0xFFFA

    public struct Status: Equatable, Sendable {
        public let computed: UInt16
        public let stored: UInt16
        public let mirror: UInt16
        public var mirrorValid: Bool { mirror == ~stored }
        public var isValid: Bool { computed == stored && mirrorValid }
    }

    public enum FixError: Error, Equatable, LocalizedError {
        case unsupportedSize(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSize(let size):
                "Пересчёт КС поддерживается только для образов 64 КБ (этот — \(size) Б)"
            }
        }
    }

    public struct FixResult: Equatable, Sendable {
        public let before: Status
        public let after: Status
        public var storedChanged: Bool { before.stored != after.stored }
    }

    public static func status(of data: Data) -> Status? {
        guard data.count == imageSize else { return nil }
        return Status(computed: sum(data), stored: word(data, storedOffset), mirror: word(data, mirrorOffset))
    }

    public static func sum(_ data: Data) -> UInt16 {
        UInt16(truncatingIfNeeded: data.reduce(0) { $0 &+ Int($1) })
    }

    static func word(_ data: Data, _ offset: Int) -> UInt16 {
        let b = data.startIndex
        return UInt16(data[b + offset]) | UInt16(data[b + offset + 1]) << 8
    }

    /// Checksum the ECU expects for this image: sum of all bytes except the
    /// checksum and mirror words, plus 0x1FE (= the four bytes of a word and its inverse).
    public static func expected(for data: Data) -> UInt16 {
        let b = data.startIndex
        var body = Int(sum(data))
        for offset in [mirrorOffset, mirrorOffset + 1, storedOffset, storedOffset + 1] {
            body -= Int(data[b + offset])
        }
        return UInt16(truncatingIfNeeded: body + 0x1FE)
    }

    /// Whether the firmware's own code reads the checksum word: `mov dptr,#FFFE; clr a;
    /// movc a,@a+dptr` (0xE437 in J5V05L19). Present in all 61 factory J5/J7.2 images;
    /// absent in J5LS N35, whose author removed the ROM check (FFFE = FF00, no mirror).
    /// Without it the checksum bytes are not ours to rewrite.
    public static func isCheckedByFirmware(_ data: Data) -> Bool {
        data.firstRange(of: Data([0x90, 0xFF, 0xFE, 0xE4, 0x93])) != nil
    }

    /// Whether the image carries the January checksum convention — FFFA holds ~FFFE — so
    /// loaders (Combiloader) and CTP verify FFFE at write time even when the firmware never
    /// reads it at runtime (J5LS V43 and J5TRS: valid CS kept only for tool compatibility).
    /// A dummy word without a mirror (J5LS N35: FFFE = FF00) returns false — not ours to set.
    public static func maintainsStructure(_ data: Data) -> Bool {
        status(of: data)?.mirrorValid == true
    }

    /// Writes the expected checksum to 0xFFFE and its inverse to 0xFFFA.
    @discardableResult
    public static func fix(_ data: inout Data) throws -> FixResult {
        guard data.count == imageSize else { throw FixError.unsupportedSize(data.count) }
        let before = status(of: data)!
        let value = expected(for: data)
        let b = data.startIndex
        data[b + storedOffset] = UInt8(value & 0xFF)
        data[b + storedOffset + 1] = UInt8(value >> 8)
        data[b + mirrorOffset] = UInt8(~value & 0xFF)
        data[b + mirrorOffset + 1] = UInt8(~value >> 8)
        let after = status(of: data)!
        precondition(after.isValid)
        return FixResult(before: before, after: after)
    }
}

extension Firmware {
    /// ROM checksum status, or nil when the image isn't a 64 KB raw ROM.
    public var checksum: Checksum.Status? {
        format == .raw ? Checksum.status(of: data) : nil
    }

    @discardableResult
    public mutating func fixChecksum() throws -> Checksum.FixResult {
        var copy = data
        let result = try Checksum.fix(&copy)
        write(Array(copy[copy.startIndex + Checksum.mirrorOffset ..< copy.endIndex]), at: Checksum.mirrorOffset)
        return result
    }
}
