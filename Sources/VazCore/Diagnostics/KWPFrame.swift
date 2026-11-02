import Foundation

/// One KWP2000 (ISO 14230) message: `Fmt Tgt Src [Len] Data… CS`.
public struct KWPMessage: Equatable, Sendable {
    public var target: UInt8
    public var source: UInt8
    /// Service id followed by parameters.
    public var data: [UInt8]

    public init(target: UInt8, source: UInt8, data: [UInt8]) {
        self.target = target
        self.source = source
        self.data = data
    }
}

public enum KWPFrameError: Error, Equatable, LocalizedError {
    case badFormat(UInt8)
    case badChecksum(expected: UInt8, actual: UInt8)
    case emptyData
    case tooLong(Int)

    public var errorDescription: String? {
        switch self {
        case .badFormat(let f): String(format: "Неизвестный формат кадра 0x%02X", f)
        case .badChecksum(let e, let a): String(format: "Ошибка КС кадра: ожидалось 0x%02X, получено 0x%02X", e, a)
        case .emptyData: "Пустой кадр"
        case .tooLong(let n): "Кадр слишком длинный: \(n) байт"
        }
    }
}

public enum KWPFrame {
    /// Physical addressing, bits 7–6 of Fmt = 10.
    static let physical: UInt8 = 0x80

    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(0, &+)
    }

    /// Encodes with a 3-byte header when the data fits in Fmt (≤ 63 bytes), else with a Len byte.
    public static func encode(_ m: KWPMessage) throws -> [UInt8] {
        guard !m.data.isEmpty else { throw KWPFrameError.emptyData }
        guard m.data.count <= 255 else { throw KWPFrameError.tooLong(m.data.count) }
        var bytes: [UInt8] = m.data.count <= 63
            ? [physical | UInt8(m.data.count), m.target, m.source]
            : [physical, m.target, m.source, UInt8(m.data.count)]
        bytes += m.data
        bytes.append(checksum(bytes))
        return bytes
    }

    /// Bytes still needed before a frame starting with `prefix` is complete;
    /// nil if the header itself isn't complete yet.
    public static func totalLength(prefix: [UInt8]) throws -> Int? {
        guard let fmt = prefix.first else { return nil }
        guard fmt & 0xC0 == physical else { throw KWPFrameError.badFormat(fmt) }
        let short = Int(fmt & 0x3F)
        if short > 0 { return 3 + short + 1 }
        guard prefix.count >= 4 else { return nil }
        return 4 + Int(prefix[3]) + 1
    }

    public static func decode(_ bytes: [UInt8]) throws -> KWPMessage {
        guard let total = try totalLength(prefix: bytes), bytes.count >= total else {
            throw KWPFrameError.emptyData
        }
        let headerLength = bytes[0] & 0x3F == 0 ? 4 : 3
        let expected = checksum(bytes[0 ..< total - 1])
        guard expected == bytes[total - 1] else {
            throw KWPFrameError.badChecksum(expected: expected, actual: bytes[total - 1])
        }
        return KWPMessage(target: bytes[1], source: bytes[2], data: Array(bytes[headerLength ..< total - 1]))
    }
}
