import Foundation

/// Calibration layout for one or more software versions, loaded from JSON
/// (see `tools/gen_j5_definitions.py` and `Definitions/*.json`).
public struct CalibrationDefinition: Codable, Sendable {
    public var softwareIDs: [String]
    public var family: String
    public var source: String?
    public var axes: [String: AxisDefinition]
    public var tables: [TableDefinition]
    /// Code bytes that must be in the image for the layout to apply: builds sharing a software
    /// ID can differ (J5V05J16 and its HIP9011 build). Nil — matched by ID alone.
    public var check: [CodeCheck]?

    public struct CodeCheck: Codable, Sendable {
        @HexAddress public var address: Int
        /// Hex, e.g. "EAC423541FFBEAC4".
        public var bytes: String
    }

    /// Whether every check holds in `data`.
    public func matches(_ data: Data) -> Bool {
        (check ?? []).allSatisfy { c in
            let expected = stride(from: 0, to: c.bytes.count, by: 2).compactMap { i -> UInt8? in
                let start = c.bytes.index(c.bytes.startIndex, offsetBy: i)
                return UInt8(c.bytes[start ..< c.bytes.index(start, offsetBy: 2)], radix: 16)
            }
            guard c.address >= 0, c.address + expected.count <= data.count else { return false }
            let from = data.startIndex + c.address
            return Array(data[from ..< from + expected.count]) == expected
        }
    }
}

/// How confident we are about a table's meaning.
public enum Confidence: String, Codable, Sendable {
    /// Verified against code and physical behaviour.
    case confirmed
    /// Strong evidence from code, not verified on a car.
    case likely
    /// Only shape and axes are known.
    case auto
}

public struct TableDefinition: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var group: String
    @HexAddress public var address: Int
    public var rows: Int
    public var cols: Int
    public var xAxis: String?
    public var yAxis: String?
    public var scale: Double?
    public var offset: Double?
    public var unit: String?
    public var dataType: DataType?
    /// value = reciprocal / raw instead of raw · scale + offset (CTP "inverted" conversions).
    public var reciprocal: Double?
    /// Bits of each byte that hold the value (e.g. 0x0C); other bits are left untouched on write.
    public var mask: Int?
    public var confidence: Confidence
    public var notes: String?
    public var access: [String]?

    public enum DataType: String, Codable, Sendable {
        case u8, s8
        /// 16-bit, low byte first (as the 8051 code loads r0 = [a], r1 = [a+1]).
        case u16le
        /// 16-bit split into two pages: the low bytes of all cells, then their high bytes
        /// (`address + count + i`). The J5 MAF table reads `[T + code]` and `[T + 100h + code]`.
        case u16split

        public var size: Int { self == .u8 || self == .s8 ? 1 : 2 }

        public var range: ClosedRange<Int> {
            switch self {
            case .u8: 0...255
            case .s8: -128...127
            case .u16le, .u16split: 0...65535
            }
        }
    }

    public var type: DataType { dataType ?? .u8 }
    public var count: Int { rows * cols }
    public var byteCount: Int { count * type.size }
    public var byteRange: Range<Int> { address ..< address + byteCount }
    public var isScalar: Bool { count == 1 }

    /// Image offsets of cell `index` (row-major), low byte first.
    public func offsets(ofCell index: Int) -> [Int] {
        if type == .u16split { return [address + index, address + count + index] }
        return Array(address + index * type.size ..< address + (index + 1) * type.size)
    }

    /// Range of the stored integer: the type's range, or the masked bits shifted down.
    public var rawRange: ClosedRange<Int> {
        guard let mask, mask > 0 else { return type.range }
        return 0...(mask >> mask.trailingZeroBitCount)
    }

    /// Physical value for a raw stored integer.
    public func value(fromRaw raw: Int) -> Double {
        if let reciprocal { return raw == 0 ? .infinity : reciprocal / Double(raw) }
        return Double(raw) * (scale ?? 1) + (offset ?? 0)
    }

    /// Raw stored integer for a physical value, rounded and clamped to the raw range.
    public func raw(fromValue value: Double) -> Int {
        let exact = reciprocal.map { value == 0 ? Double(rawRange.upperBound) : $0 / value }
            ?? (value - (offset ?? 0)) / (scale ?? 1)
        guard exact.isFinite else { return rawRange.upperBound }
        return min(max(Int(exact.rounded()), rawRange.lowerBound), rawRange.upperBound)
    }

    /// Little-endian / single-byte encoding of a raw integer.
    func encode(_ raw: Int) -> [UInt8] {
        switch type {
        case .u8: [UInt8(raw)]
        case .s8: [UInt8(bitPattern: Int8(raw))]
        case .u16le, .u16split: [UInt8(raw & 0xFF), UInt8(raw >> 8)]
        }
    }

    func decode(_ bytes: ArraySlice<UInt8>) -> Int {
        let b = Array(bytes)
        if let mask, mask > 0 { return (Int(b[0]) & mask) >> mask.trailingZeroBitCount }
        switch type {
        case .u8: return Int(b[0])
        case .s8: return Int(Int8(bitPattern: b[0]))
        case .u16le, .u16split: return Int(b[0]) | Int(b[1]) << 8
        }
    }
}

public struct AxisDefinition: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// `start + i * step`.
        case linear
        /// Grid stored as a monotonic mapping table: node k is the input x
        /// where `table[x] == k * step`, reported as `x * scale`.
        case inverseLookup
        /// Январь 5.1 load grid: row = ((X − offset) >> 3) · gain >> 8, node = X / divisor.
        case j5Load
    }

    public var kind: Kind
    public var points: Int
    public var unit: String?
    public var start: Double?
    public var step: Double?
    public var scale: Double?
    @OptionalHexAddress public var address: Int?
    public var length: Int?
    @OptionalHexAddress public var offsetAddress: Int?
    @OptionalHexAddress public var gainAddress: Int?
    public var divisor: Double?

    /// Axis node values for `data`; nil when the definition can't be evaluated.
    public func values(in data: Data) -> [Double]? {
        let step = self.step ?? 1
        switch kind {
        case .linear:
            let start = self.start ?? 0
            return (0..<points).map { start + Double($0) * step }

        case .inverseLookup:
            guard let address, let length, address + length <= data.count else { return nil }
            let table = Array(data[data.startIndex + address ..< data.startIndex + address + length])
            return (0..<points).map { k in
                Self.inverse(table, target: Double(k) * step) * (scale ?? 1)
            }

        case .j5Load:
            guard let offsetAddress, let gainAddress, gainAddress < data.count else { return nil }
            let lo = Double(data[data.startIndex + offsetAddress])
            let hi = Double(data[data.startIndex + offsetAddress + 1])
            let gain = Double(data[data.startIndex + gainAddress])
            guard gain > 0 else { return nil }
            let offset = hi * 256 + lo
            let divisor = self.divisor ?? 1
            let rawPerIndex = 256.0 * 8.0 / gain
            return (0..<points).map { k -> Double in
                let raw = offset + Double(k) * step * rawPerIndex
                return raw / divisor
            }
        }
    }

    /// Input x (fractional) where a non-decreasing `table` reaches `target`.
    /// For the flat start of the table (target == table[0]) the last x of the plateau is used.
    static func inverse(_ table: [UInt8], target: Double) -> Double {
        guard let first = table.first else { return 0 }
        if target <= Double(first) {
            let plateau = table.firstIndex(where: { Double($0) > Double(first) }) ?? table.count
            return Double(plateau - 1)
        }
        for x in 1..<table.count where Double(table[x]) >= target {
            let lo = Double(table[x - 1]), hi = Double(table[x])
            return Double(x - 1) + (hi == lo ? 1 : (target - lo) / (hi - lo))
        }
        return Double(table.count - 1)
    }
}

/// Decodes addresses written as "0x6AC8" (or plain integers) in JSON.
@propertyWrapper
public struct HexAddress: Codable, Sendable, Hashable {
    public var wrappedValue: Int

    public init(wrappedValue: Int) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) {
            wrappedValue = n
        } else if let n = HexFormatter.parseOffset(try c.decode(String.self)) {
            wrappedValue = n
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Ожидался адрес вида 0x6AC8")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode("0x" + HexFormatter.offset(wrappedValue, digits: 4))
    }
}

@propertyWrapper
public struct OptionalHexAddress: Codable, Sendable, Hashable {
    public var wrappedValue: Int?

    public init(wrappedValue: Int?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        wrappedValue = try HexAddress(from: decoder).wrappedValue
    }

    public func encode(to encoder: Encoder) throws {
        if let wrappedValue { try HexAddress(wrappedValue: wrappedValue).encode(to: encoder) }
    }
}

extension KeyedDecodingContainer {
    // Lets optional hex fields be absent from the JSON.
    public func decode(_ type: OptionalHexAddress.Type, forKey key: Key) throws -> OptionalHexAddress {
        try decodeIfPresent(type, forKey: key) ?? OptionalHexAddress(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    public mutating func encode(_ value: OptionalHexAddress, forKey key: Key) throws {
        if value.wrappedValue != nil { try encodeIfPresent(value, forKey: key) }
    }
}

public enum DefinitionStore {
    /// Definitions bundled with VazCore.
    public static let bundled: [CalibrationDefinition] = {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Definitions") ?? []
        // Linux Foundation types the array as NSURL; Apple platforms bridge it to URL.
        return urls.compactMap { try? JSONDecoder().decode(CalibrationDefinition.self, from: Data(contentsOf: $0 as URL)) }
    }()

    public static func definition(forSoftwareID id: String?) -> CalibrationDefinition? {
        guard let id else { return nil }
        return bundled.first { $0.softwareIDs.contains(id) }
    }

    /// Definition for an image: same software ID and its code checks pass (a build with the
    /// same ID but other code gets none rather than a wrong layout).
    public static func definition(forSoftwareID id: String?, data: Data) -> CalibrationDefinition? {
        guard let id else { return nil }
        return bundled.first { $0.softwareIDs.contains(id) && $0.matches(data) }
    }
}

extension Firmware {
    /// Bytes occupied by `table`.
    public func bytes(of table: TableDefinition) -> [UInt8] {
        guard table.byteRange.upperBound <= data.count else { return [] }
        return Array(data[data.startIndex + table.address ..< data.startIndex + table.byteRange.upperBound])
    }

    /// Stored integers of `table`, row-major.
    public func rawValues(of table: TableDefinition) -> [Int] {
        let bytes = bytes(of: table)
        guard !bytes.isEmpty else { return [] }
        return (0..<table.count).map { i in
            table.decode(ArraySlice(table.offsets(ofCell: i).map { bytes[$0 - table.address] }))
        }
    }

    public func values(of table: TableDefinition) -> [Double] {
        rawValues(of: table).map(table.value(fromRaw:))
    }

    public mutating func setValue(_ value: Double, of table: TableDefinition, row: Int, col: Int) {
        setRaw(table.raw(fromValue: value), of: table, row: row, col: col)
    }

    public mutating func setRaw(_ raw: Int, of table: TableDefinition, row: Int, col: Int) {
        precondition(row < table.rows && col < table.cols)
        let clamped = min(max(raw, table.rawRange.lowerBound), table.rawRange.upperBound)
        let offsets = table.offsets(ofCell: row * table.cols + col)
        if let mask = table.mask, mask > 0 {
            let old = Int(data[data.startIndex + offsets[0]])
            write([UInt8((old & ~mask) | (clamped << mask.trailingZeroBitCount) & mask)], at: offsets[0])
        } else {
            for (offset, byte) in zip(offsets, table.encode(clamped)) { write([byte], at: offset) }
        }
    }
}
