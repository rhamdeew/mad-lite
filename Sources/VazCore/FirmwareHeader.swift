import Foundation

/// Version block at 0x6000 shared by Январь 5.1 and 7.2 images:
///
///     0x6000..0x6010  platform, e.g. "J5.1" / "J7.2" (position varies by a byte)
///     0x6020          software ID, 8 chars, e.g. "J5V05L19"
///     0x6030          build timestamp, e.g. "08/05/2003 12:00"
///     0x6040          model, e.g. "2112"
public struct FirmwareHeader: Equatable, Sendable {
    public static let baseOffset = 0x6000
    public static let softwareIDOffset = 0x6020
    public static let buildDateOffset = 0x6030
    public static let modelOffset = 0x6040

    public let platform: String?
    public let softwareID: String?
    public let buildDate: String?
    public let model: String?

    public init?(parsing data: Data) {
        guard data.count >= Self.modelOffset + 16 else { return nil }
        let base = data.startIndex
        platform = Self.findPlatform(in: data[base + Self.baseOffset ..< base + Self.baseOffset + 0x10])
        softwareID = Self.ascii(data, at: Self.softwareIDOffset, maxLength: 8)
        buildDate = Self.ascii(data, at: Self.buildDateOffset, maxLength: 16)
        model = Self.ascii(data, at: Self.modelOffset, maxLength: 4)
        guard platform != nil || softwareID != nil else { return nil }
    }

    /// Looks for "<digit>.<digit>" and returns it as "J5.1" / "J7.2".
    /// The leading "J" is not matched: in some 7.2 images it is overwritten by code bytes.
    private static func findPlatform(in slice: Data) -> String? {
        let bytes = Array(slice)
        let isDigit = { (b: UInt8) in (0x30...0x39).contains(b) }
        for i in 0..<max(0, bytes.count - 2) where isDigit(bytes[i]) && bytes[i + 1] == UInt8(ascii: ".") && isDigit(bytes[i + 2]) {
            return "J" + String(decoding: bytes[i...i + 2], as: UTF8.self)
        }
        return nil
    }

    /// Printable ASCII run starting at `offset`, terminated by NUL or a non-printable byte.
    static func ascii(_ data: Data, at offset: Int, maxLength: Int) -> String? {
        let start = data.startIndex + offset
        var bytes: [UInt8] = []
        for b in data[start ..< min(start + maxLength, data.endIndex)] {
            guard (0x20...0x7E).contains(b) else { break }
            bytes.append(b)
        }
        let s = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}

/// Identification block reported to diagnostic testers, e.g.
/// "1411010-41" · "SAMARA-1.5L,16V" · "08-05-2003" · "J5V05L19".
/// Its location differs between versions, so it is found by searching for "1411010-".
public struct DiagnosticIdentification: Equatable, Sendable {
    public let offset: Int
    public let softwareCode: String
    public let engine: String?
    public let date: String?
    public let softwareID: String?

    public init?(parsing data: Data) {
        guard let range = data.firstRange(of: Data("1411010-".utf8)) else { return nil }
        let start = range.lowerBound
        let window = data[start ..< min(start + 64, data.endIndex)]
        // Fields are printable runs separated by non-printable bytes.
        let fields = window.split(whereSeparator: { !(0x20...0x7E).contains($0) })
            .filter { $0.count >= 3 }
            .map { String(decoding: Self.trimFrameChecksum($0, in: data), as: UTF8.self) }
        guard let code = fields.first else { return nil }
        offset = start - data.startIndex
        softwareCode = code
        engine = fields.count > 1 ? fields[1] : nil
        date = fields.count > 2 ? fields[2] : nil
        softwareID = fields.count > 3 ? fields[3] : nil
    }

    /// J5V26K23 stores each field as a ready `5A` response frame: `8C F1 10 5A 94 <text> CS 00`.
    /// The checksum byte can be printable and would stick to the text, so a field that follows
    /// such a header is cut to the length the format byte gives (length − SId − option).
    static func trimFrameChecksum(_ field: Data.SubSequence, in data: Data) -> Data.SubSequence {
        let h = field.startIndex - 5
        guard h >= data.startIndex, data[h] & 0xC0 == 0x80,
              data[h + 1] == 0xF1, data[h + 2] == 0x10, data[h + 3] == 0x5A else { return field }
        let length = Int(data[h] & 0x3F) - 2
        return field.prefix(max(length, 0))
    }
}
