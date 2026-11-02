import Foundation

/// Wraps a K-line transport and keeps a timestamped record of every byte sent and received
/// (and every read that timed out), so a failed loader session can be logged byte by byte.
/// Added 2026-10-31: the EEPROM agent load failed in the app at «блок 1» while the same
/// blocks loaded fine from a script.
public actor TracingTransport: KLineTransport {
    public enum Direction: String, Sendable { case tx = "→", rx = "←", timeout = "⌛" }
    public struct Event: Sendable {
        public let time: Duration
        public let direction: Direction
        public let bytes: [UInt8]
        public let note: String
    }

    let inner: any KLineTransport
    private let start = ContinuousClock.now
    public private(set) var events: [Event] = []
    public nonisolated let echoesWrites: Bool

    public init(_ inner: any KLineTransport) {
        self.inner = inner
        echoesWrites = inner.echoesWrites
    }

    private func record(_ d: Direction, _ bytes: [UInt8], _ note: String = "") {
        events.append(Event(time: ContinuousClock.now - start, direction: d, bytes: bytes, note: note))
        if events.count > 4000 { events.removeFirst(1000) }
    }

    public func fastInit() async throws { try await inner.fastInit() }

    public func write(_ bytes: [UInt8]) async throws {
        record(.tx, bytes)
        try await inner.write(bytes)
    }

    /// Short reads go byte by byte so a timeout still shows what did arrive; long reads
    /// (flash chunks) are delegated whole.
    public func read(count: Int, timeout: Duration) async throws -> [UInt8] {
        guard count <= 256 else {
            do {
                let r = try await inner.read(count: count, timeout: timeout)
                record(.rx, r)
                return r
            } catch let KLineError.timeout(expected, received) {
                record(.timeout, [], "ждали \(expected), пришло \(received)")
                throw KLineError.timeout(expected: expected, received: received)
            }
        }
        let deadline = ContinuousClock.now + timeout
        var got: [UInt8] = []
        while got.count < count {
            let left = deadline - ContinuousClock.now
            guard left > .zero, let b = try? await inner.read(count: 1, timeout: left) else {
                if !got.isEmpty { record(.rx, got) }
                record(.timeout, [], "ждали \(count), пришло \(got.count)")
                throw KLineError.timeout(expected: count, received: got.count)
            }
            got += b
        }
        record(.rx, got)
        return got
    }

    public func flush() async throws {
        record(.rx, [], "flush")
        try await inner.flush()
    }

    /// The last `limit` events as text lines: `+1.234 s → 01 D2 99 …`.
    public func dump(last limit: Int = 40) -> [String] {
        events.suffix(limit).map { e in
            let ms = Double(e.time.components.seconds) + Double(e.time.components.attoseconds) / 1e18
            let hex = e.bytes.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " ")
            let more = e.bytes.count > 48 ? " … (\(e.bytes.count) Б)" : (e.bytes.isEmpty ? "" : " (\(e.bytes.count) Б)")
            return String(format: "+%.3f с ", ms) + e.direction.rawValue + " " + hex + more + (e.note.isEmpty ? "" : " " + e.note)
        }
    }
}
