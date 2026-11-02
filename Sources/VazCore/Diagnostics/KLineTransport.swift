import Foundation

/// Byte-level access to a K-line: a KKL cable, or the firmware emulator.
public protocol KLineTransport: Sendable {
    /// ISO 14230 fast init: K low for 25 ms, high for 25 ms. Must leave the
    /// line ready for the first request at 10400 baud.
    func fastInit() async throws
    func write(_ bytes: [UInt8]) async throws
    /// Reads exactly `count` bytes or throws `KLineError.timeout`.
    func read(count: Int, timeout: Duration) async throws -> [UInt8]
    /// Drops any bytes already received.
    func flush() async throws
    /// True when every written byte comes back (half-duplex KKL adapters).
    var echoesWrites: Bool { get }
}

public enum KLineError: Error, Equatable, LocalizedError {
    case timeout(expected: Int, received: Int)
    case echoMismatch
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .timeout(let e, let r): "Нет ответа от ЭБУ: ожидалось \(e) байт, получено \(r)"
        case .echoMismatch: "Эхо не совпало с отправленными байтами — проверьте адаптер и линию"
        case .notConnected: "Нет связи с ЭБУ"
        }
    }
}
