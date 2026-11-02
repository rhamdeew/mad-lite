#if os(macOS)
import Darwin
import Foundation
import VazCore

/// K-line over a KKL adapter (FTDI FT232R) seen by macOS as `/dev/cu.usbserial-*`.
///
/// - 10400 baud is non-standard, so it is set with the IOSSIOSPEED ioctl.
/// - Fast init (K low 25 ms, high 25 ms) is generated with a line break.
/// - KKL adapters are half-duplex: every written byte comes back as an echo,
///   which `KWPClient` checks and drops.
///
/// Port open, 10400 baud and break checked with the user's FT232RL cable without OBD power
/// (26.10.2026); talking to an ECU not yet verified.
public actor SerialKLineTransport: KLineTransport {
    public nonisolated let echoesWrites = true
    public let path: String
    private let fd: Int32

    // ioctl numbers from <IOKit/serial/ioss.h> and <sys/ttycom.h>; Swift does not import these macros.
    private static let IOSSIOSPEED: UInt = 0x8008_5402 // _IOW('T', 2, speed_t)
    private static let TIOCSBRK: UInt = 0x2000_747B    // _IO('t', 123)
    private static let TIOCCBRK: UInt = 0x2000_747A    // _IO('t', 122)

    public enum OpenError: Error, LocalizedError {
        case open(String, Int32)
        case configure(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .open(let path, let e): "Не удалось открыть \(path): \(String(cString: strerror(e)))"
            case .configure(let what, let e): "Не удалось настроить порт (\(what)): \(String(cString: strerror(e)))"
            }
        }
    }

    /// Serial ports that look like USB adapters.
    public static func availablePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.SLAB") }
            .sorted().map { "/dev/" + $0 }
    }

    /// `stopBits: 2` for the C509 bootstrap loader (8N2); KWP uses 8N1.
    public init(path: String, baud: Int = 10400, stopBits: Int = 1) throws {
        self.path = path
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw OpenError.open(path, errno) }
        do {
            try Self.configure(fd, baud: baud, stopBits: stopBits)
        } catch {
            Darwin.close(fd)
            throw error
        }
        self.fd = fd
    }

    deinit { Darwin.close(fd) }

    private static func configure(_ fd: Int32, baud: Int, stopBits: Int) throws {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw OpenError.configure("tcgetattr", errno) }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        t.c_cflag = (t.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS8)
        if stopBits == 2 { t.c_cflag |= tcflag_t(CSTOPB) }
        // Non-blocking reads; timing is handled with poll().
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 0
        }
        cfsetspeed(&t, speed_t(B9600)) // placeholder; the real rate is set below
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { throw OpenError.configure("tcsetattr", errno) }
        var speed = speed_t(baud)
        guard ioctl(fd, IOSSIOSPEED, &speed) == 0 else { throw OpenError.configure("IOSSIOSPEED \(baud)", errno) }
        tcflush(fd, TCIOFLUSH)
    }

    public func fastInit() async throws {
        // TIdle before the first init: the line must be idle (high) for > 200 ms… the
        // caller is expected to have waited (e.g. after ignition on); keep a short guard.
        try await Task.sleep(for: .milliseconds(300))
        guard ioctl(fd, Self.TIOCSBRK) == 0 else { throw OpenError.configure("break on", errno) }
        try await Task.sleep(for: .milliseconds(25))
        guard ioctl(fd, Self.TIOCCBRK) == 0 else { throw OpenError.configure("break off", errno) }
        try await Task.sleep(for: .milliseconds(25))
        tcflush(fd, TCIFLUSH) // drop anything the break produced
    }

    public func write(_ bytes: [UInt8]) async throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                guard errno == EAGAIN else { throw OpenError.configure("write", errno) }
                try await Task.sleep(for: .milliseconds(1))
                continue
            }
            offset += n
        }
        tcdrain(fd)
    }

    public func read(count: Int, timeout: Duration) async throws -> [UInt8] {
        var result: [UInt8] = []
        let deadline = ContinuousClock.now + timeout
        var buffer = [UInt8](repeating: 0, count: 256)
        while result.count < count {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else {
                throw KLineError.timeout(expected: count, received: result.count)
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(min(remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000, 50))
            if poll(&p, 1, max(ms, 1)) > 0 {
                let want = min(buffer.count, count - result.count)
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, want) }
                if n > 0 { result += buffer[0..<n] }
            }
            try Task.checkCancellation()
        }
        return result
    }

    public func flush() async throws {
        tcflush(fd, TCIFLUSH)
    }

    public enum CableCheck: Equatable, Sendable {
        /// Every byte came back: the K-line transceiver is powered and the line idles high.
        case echoOK
        /// Nothing came back: no 12 V on OBD pin 16 / ground on 4–5, or a dead cable.
        case noEcho
        /// Something else came back: noise, poor ground, another device talking.
        case badEcho(sent: [UInt8], received: [UInt8])
    }

    /// Sends a few bytes and listens for the adapter's own echo (KKL cables are half-duplex).
    /// No init and no ECU address: the ECU ignores them. Checked without OBD power: no echo.
    public func checkEcho() async throws -> CableCheck {
        let probe: [UInt8] = [0x55, 0x00, 0xFF, 0xAA]
        tcflush(fd, TCIOFLUSH)
        try await write(probe)
        var received: [UInt8] = []
        while received.count < probe.count {
            do {
                received += try await read(count: 1, timeout: .milliseconds(300))
            } catch KLineError.timeout {
                break
            }
        }
        if received == probe { return .echoOK }
        return received.isEmpty ? .noEcho : .badEcho(sent: probe, received: received)
    }
}
#endif
