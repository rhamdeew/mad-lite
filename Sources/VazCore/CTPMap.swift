import Foundation

/// ChipTuningPRO calibration map (`.j5`, header "CTM"): a tree of folders, constants,
/// curves, 3D tables and flag bytes for one firmware line (e.g. J5LS V43).
///
/// Layout follows the open-source parser `cmgt/ecusystems/CtpMaps` (DataTypes/*.cs):
/// strings are a length byte + fixed cp1251 buffer, numbers little-endian, the first
/// address of every entry is XORed with 0x28A6FBB8. Description: docs/ctp-maps.md.
public struct CTPMap: Sendable {
    public enum Kind: UInt8, Sendable {
        case folder = 0
        /// y = f(x), "1D" in CTP terms.
        case curve = 1
        /// y = f(x, z).
        case table = 2
        case constant = 3
        /// Up to 8 bytes with named bits (configuration flags, error masks).
        case flags = 4
        /// Identification strings.
        case ident = 5
    }

    /// Physical value = (raw − offset1) · step / divStep − offset2,
    /// or inverted / (raw · divStep) when `inverted` ≠ 0.
    public struct Conversion: Equatable, Sendable {
        public var divStep, offset2, inverted, step, offset1: Double
    }

    public struct Entry: Sendable {
        public var name: String
        public var level: Int
        public var kind: Kind
        public var address: Int?
        public var units = ""
        public var xUnits = "", zUnits = ""
        /// Axis source: "" — linear from start to end, otherwise a CTP axis id
        /// such as "!002-613C-40" (RPM quantization table at 0x613C, 40 rpm per step).
        public var xTable = "", zTable = ""
        public var xPoints = 1, zPoints = 1
        public var xStart = 0.0, xEnd = 0.0, zStart = 0.0, zEnd = 0.0
        public var lowerLimit = 0.0, upperLimit = 0.0
        /// 0 u8, 1 s8, 2 u16 LE, 3 s16 LE, 4 u16 BE, 5 s16 BE, 6 split u16 (MAF calibration).
        public var constType: UInt8 = 0
        /// Bit mask of the value inside each byte; 0 or 0xFFFF — whole byte.
        public var shiftMask: UInt16 = 0xFFFF
        public var conversion: Conversion?
        /// Flags: byte addresses (nil = unused slot), item names and bit names [item][bit].
        public var flagAddresses: [Int?] = []
        public var itemNames: [String] = []
        public var bitNames: [[String]] = []
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case notACTPMap
        case truncated(entry: Int)
        /// Addresses decode to nonsense: the map is encrypted with a per-licence XOR key
        /// (seen in 1499 copies of J5LS_N35.j5, one per licence folder).
        case foreignKey

        public var errorDescription: String? {
            switch self {
            case .notACTPMap: "это не карта ChipTuningPRO (нет заголовка CTM)"
            case .truncated(let n): "файл обрывается на записи \(n + 1)"
            case .foreignKey: "адреса в карте зашифрованы ключом лицензии, а не общим — нужна карта без привязки"
            }
        }
    }

    public static let xorKey: UInt32 = 0x28A6_FBB8

    public var version: Int
    public var entries: [Entry]

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count > 22, bytes.starts(with: Array("CTM".utf8)) else { throw ParseError.notACTPMap }
        version = Int(bytes[3])
        // Version 1 is the OpenOLT variant without XOR and checksums; version 7 has 35 more header bytes.
        let olt = version == 1
        var r = Reader(bytes: bytes, position: 22 + (version == 7 ? 35 : 0))
        entries = []
        while r.position < bytes.count {
            do {
                entries.append(try Self.entry(&r, olt: olt))
            } catch {
                throw ParseError.truncated(entry: entries.count)
            }
        }
        let addresses = entries.compactMap(\.address)
        if !addresses.isEmpty, addresses.filter({ $0 > 0xFFFF }).count * 2 > addresses.count {
            throw ParseError.foreignKey
        }
    }

    private static func entry(_ r: inout Reader, olt: Bool) throws -> Entry {
        var e = Entry(name: try r.string(64), level: Int(try r.byte()), kind: .folder)
        let rawKind = try r.byte()
        let length = Int(try r.u16())
        let body = r.position
        e.kind = Kind(rawValue: rawKind) ?? .folder
        let key = olt ? 0 : xorKey
        let padding = olt ? 4 : 8

        switch e.kind {
        case .constant, .curve, .table:
            _ = try r.u32() // compare id
            e.address = Int(try r.u32() ^ key)
            try r.skip(padding)
            if e.kind == .constant {
                e.units = try r.string(16)
                e.lowerLimit = try r.double()
                e.upperLimit = try r.double()
                e.constType = try r.byte()
                _ = try r.byte() // precision
            } else {
                e.xUnits = try r.string(32)
                e.units = try r.string(32)
                if e.kind == .table { e.zUnits = try r.string(32) }
                e.xTable = try r.string(255)
                if e.kind == .table { e.zTable = try r.string(255) }
                e.xPoints = Int(try r.u16())
                e.shiftMask = try r.u16()
                if e.kind == .table { e.zPoints = Int(try r.byte()) }
                e.xStart = try r.double()
                e.xEnd = try r.double()
                try r.skip(1)
                e.lowerLimit = try r.double()
                e.upperLimit = try r.double()
                try r.skip(1)
                if e.kind == .table {
                    e.zStart = try r.double()
                    e.zEnd = try r.double()
                    try r.skip(1)
                    e.constType = try r.byte()
                    try r.skip(4) // 00, throttle/GBC selector, FF 00
                } else {
                    e.constType = try r.byte()
                    try r.skip(3)
                }
            }
            e.conversion = Conversion(divStep: try r.double(), offset2: try r.double(), inverted: try r.double(),
                                      step: try r.double(), offset1: try r.double())
            try r.skip(8) // RAM capture id, RT type, palette, reserved
            if !olt { try r.skip(2) }

        case .flags:
            _ = try r.u32()
            var addresses = try (0..<8).map { _ in try r.u32() }
            addresses[0] ^= key
            e.flagAddresses = addresses.map { $0 == 0xFFFF_FFFF ? nil : Int($0 & 0xFFFF) }
            try r.skip(padding)
            e.itemNames = try (0..<8).map { _ in try r.string(64) }
            e.bitNames = try (0..<8).map { _ in try (0..<8).map { _ in try r.string(64) } }
            if !olt { try r.skip(18) }

        case .folder, .ident:
            try r.skip(length)
        }
        // Trust the declared length: it keeps the reader aligned even for unknown layouts.
        if e.kind != .folder { r.position = body + length }
        return e
    }

    struct Reader {
        let bytes: [UInt8]
        var position: Int

        struct EndOfData: Error {}

        mutating func byte() throws -> UInt8 {
            guard position < bytes.count else { throw EndOfData() }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func skip(_ n: Int) throws {
            guard position + n <= bytes.count else { throw EndOfData() }
            position += n
        }

        mutating func u16() throws -> UInt16 {
            UInt16(try byte()) | UInt16(try byte()) << 8
        }

        mutating func u32() throws -> UInt32 {
            UInt32(try u16()) | UInt32(try u16()) << 16
        }

        mutating func double() throws -> Double {
            Double(bitPattern: UInt64(try u32()) | UInt64(try u32()) << 32)
        }

        /// Length byte + fixed-size cp1251 buffer.
        mutating func string(_ size: Int) throws -> String {
            let length = min(Int(try byte()), size)
            guard position + size <= bytes.count else { throw EndOfData() }
            let text = Self.cp1251(bytes[position ..< position + length])
            position += size
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func cp1251(_ bytes: ArraySlice<UInt8>) -> String {
            String(data: Data(bytes), encoding: .windowsCP1251) ?? String(decoding: bytes, as: UTF8.self)
        }
    }
}
