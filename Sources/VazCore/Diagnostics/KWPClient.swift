import Foundation

public enum KWPError: Error, Equatable, LocalizedError {
    /// `7F <service> <code>`.
    case negativeResponse(service: UInt8, code: UInt8)
    case unexpectedResponse([UInt8])

    public var errorDescription: String? {
        switch self {
        case .negativeResponse(let s, let c):
            String(format: "ЭБУ отклонил запрос 0x%02X: %@", s, Self.describe(code: c))
        case .unexpectedResponse(let d):
            "Неожиданный ответ: " + d.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    public static func describe(code: UInt8) -> String {
        switch code {
        case 0x10: "запрос отклонён (10)"
        case 0x11: "сервис не поддерживается (11)"
        case 0x12: "неверный формат или параметр (12)"
        case 0x21: "ЭБУ занят, повторите (21)"
        case 0x31: "значение вне диапазона (31)"
        case 0x72: "передача прервана (72)"
        case 0x77: "ошибка контрольной суммы данных (77)"
        case 0x78: "запрос принят, ответ задерживается (78)"
        default: String(format: "код 0x%02X", code)
        }
    }
}

/// KWP2000 session with a Январь ECU over a K-line transport.
public actor KWPClient {
    public static let ecuAddress: UInt8 = 0x10
    public static let testerAddress: UInt8 = 0xF1

    public enum Service: UInt8, Sendable {
        case startCommunication = 0x81
        case stopCommunication = 0x82
        case startDiagnosticSession = 0x10
        case ecuReset = 0x11
        case clearDiagnosticInformation = 0x14
        case readDTCByStatus = 0x18
        case readEcuIdentification = 0x1A
        case readDataByLocalIdentifier = 0x21
        case readMemoryByAddress = 0x23
        case testerPresent = 0x3E
    }

    private let transport: KLineTransport
    /// P2max is 50 ms by the spec; allow slack for USB latency.
    public var responseTimeout: Duration = .milliseconds(500)
    /// P3min: the ECU needs 100 ms between the end of a response and the next request.
    public var interRequestDelay: Duration = .milliseconds(100)
    private var lastResponse: ContinuousClock.Instant?
    public private(set) var keyBytes: [UInt8]?

    public init(transport: KLineTransport, interRequestDelay: Duration = .milliseconds(100)) {
        self.transport = transport
        self.interRequestDelay = interRequestDelay
    }

    /// Fast init + startCommunication. Returns the ECU's KeyBytes (`6B 8F` per spec).
    @discardableResult
    public func connect() async throws -> [UInt8] {
        try await transport.flush()
        try await transport.fastInit()
        let response = try await request([Service.startCommunication.rawValue])
        keyBytes = Array(response.dropFirst())
        return keyBytes ?? []
    }

    public func disconnect() async throws {
        _ = try? await request([Service.stopCommunication.rawValue])
        keyBytes = nil
    }

    /// Sends a request and returns the positive response data (starting with SId+0x40).
    /// Retries while the ECU answers "busy" (21) or "response pending" (78).
    public func request(_ data: [UInt8]) async throws -> [UInt8] {
        let frame = try KWPFrame.encode(KWPMessage(target: Self.ecuAddress, source: Self.testerAddress, data: data))
        if let lastResponse {
            let wait = lastResponse + interRequestDelay - ContinuousClock.now
            if wait > .zero { try await Task.sleep(for: wait) }
        }
        defer { lastResponse = ContinuousClock.now }
        for attempt in 0..<5 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(100)) }
            // Leftovers of a broken answer would be read as the next frame: J5LS N35 declares
            // 12 data bytes for `21 A3` and sends 11, so after the timeout its checksum byte is
            // still in the line (emulator, 27.10.2026).
            try await transport.flush()
            try await transport.write(frame)
            if transport.echoesWrites {
                let echo = try await transport.read(count: frame.count, timeout: responseTimeout)
                guard echo == frame else { throw KLineError.echoMismatch }
            }
            responses: while true {
                let d = try await readFrame().data
                if d.first == 0x7F, d.count >= 3, d[1] == data[0] {
                    switch d[2] {
                    case 0x78: continue responses // answer follows in another frame
                    case 0x21: break responses // busy: send the request again
                    default: throw KWPError.negativeResponse(service: d[1], code: d[2])
                    }
                }
                guard d.first == data[0] | 0x40 else { throw KWPError.unexpectedResponse(d) }
                return d
            }
        }
        throw KWPError.negativeResponse(service: data[0], code: 0x21)
    }

    private func readFrame() async throws -> KWPMessage {
        var bytes = try await transport.read(count: 1, timeout: responseTimeout)
        while true {
            if let total = try KWPFrame.totalLength(prefix: bytes) {
                if bytes.count < total {
                    bytes += try await transport.read(count: total - bytes.count, timeout: responseTimeout)
                }
                return try KWPFrame.decode(bytes)
            }
            bytes += try await transport.read(count: 1, timeout: responseTimeout)
        }
    }

    // MARK: - Services

    public func readLiveData() async throws -> J5LiveData {
        let d = try await request([Service.readDataByLocalIdentifier.rawValue, 0x01])
        return try J5LiveData(response: d)
    }

    public enum Baudrate: UInt8, Sendable {
        case normal = 0x0A   // 10400
        case high = 0x26     // 38400
        case enhanced = 0x39 // 57600
    }

    /// `10 81 <baud>`; J5LS user ECUs accept only `.normal`.
    public func startDiagnosticSession(baudrate: Baudrate = .normal) async throws {
        _ = try await request([Service.startDiagnosticSession.rawValue, 0x81, baudrate.rawValue])
    }

    /// Finds the J5LS extended record: tries `21 8C`, `21 0D`, `21 0F` and returns the
    /// first id that answers; nil when all are rejected (stock firmware answers `7F 21 12`).
    public func detectExtendedRecord() async throws -> UInt8? {
        for id in J5LSLiveData.recordIDs {
            do {
                _ = try await request([Service.readDataByLocalIdentifier.rawValue, id])
                return id
            } catch KWPError.negativeResponse(service: 0x21, code: _) {
                continue
            }
        }
        return nil
    }

    public func readExtended(record id: UInt8) async throws -> J5LSLiveData {
        try J5LSLiveData(response: try await request([Service.readDataByLocalIdentifier.rawValue, id]))
    }

    public func readDTCs() async throws -> [DTC] {
        let d = try await request([Service.readDTCByStatus.rawValue, 0x00, 0x00, 0x00])
        return try DTC.parse(response: d)
    }

    public func clearDTCs() async throws {
        _ = try await request([Service.clearDiagnosticInformation.rawValue, 0x00, 0x00])
    }

    /// `3E 01` (responseRequired): J5V05L19 ignores a bare `3E` — no answer at all (emulator, 26.10.2026).
    public func testerPresent() async throws {
        _ = try await request([Service.testerPresent.rawValue, 0x01])
    }

    /// External RAM read; the spec allows 0xFD00–0xFEFF, up to 0x78 bytes.
    public func readMemory(address: UInt16, count: UInt8) async throws -> [UInt8] {
        let d = try await request([Service.readMemoryByAddress.rawValue, 0x00,
                                   UInt8(address >> 8), UInt8(address & 0xFF), count])
        return Array(d.dropFirst())
    }

    public func readIdentification(option: UInt8 = 0x80) async throws -> [UInt8] {
        Array(try await request([Service.readEcuIdentification.rawValue, option]).dropFirst())
    }
}
