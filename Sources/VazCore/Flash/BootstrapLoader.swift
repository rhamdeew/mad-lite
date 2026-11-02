import Foundation

/// Host side of the Siemens C509-L Bootstrap Loader (boot ROM, user manual 1997-11,
/// chapter 10). The ECU enters it when the PRGEN pin is high at reset — on Январь 5.1
/// that is pin 47 at +12 V before the ignition (docs/flashing.md).
///
/// The loader talks 8N2 at the host's baud rate (it measures a 00h test byte) and only
/// answers single bytes: 55h acknowledge, FEh checksum error, FFh block error.
/// Mode 0 loads code into XRAM F400–FFFF, mode 1 runs it (SWAP: XRAM becomes code
/// memory and the external flash becomes MOVX data memory), mode 2 checks a flash
/// area against two checksum bytes stored after it, mode 3 jumps into the flash.
public enum BootstrapLoader {
    public static let acknowledge: UInt8 = 0x55
    public static let checksumError: UInt8 = 0xFE
    public static let blockError: UInt8 = 0xFF
    /// XRAM range mode 0 can fill; F400–F41F hold the TIMER0/SINT0 vectors when used.
    public static let xram: ClosedRange<UInt16> = 0xF400...0xFFFF
    /// Largest data area of a transfer block (manual: 00h…7Ch bytes).
    public static let maxDataArea = 0x7C

    public enum BlockType: UInt8 { case header = 0x00, data = 0x01, endOfTransmission = 0x02 }

    public enum Mode: UInt8 {
        case loadXRAM = 0, runXRAM = 1, checkFlash = 2, runFlash = 3
    }

    /// XOR of all bytes — the transfer block checksum.
    public static func xor(_ bytes: some Sequence<UInt8>) -> UInt8 { bytes.reduce(0, ^) }

    /// A transfer block: type, data area, XOR checksum.
    public static func block(_ type: BlockType, _ data: [UInt8]) -> [UInt8] {
        let body = [type.rawValue] + data
        return body + [xor(body)]
    }

    /// The 8-byte header: mode, start address (high first), three mode-specific bytes.
    public static func header(_ mode: Mode, address: UInt16, _ extra: (UInt8, UInt8, UInt8) = (0, 0, 0)) -> [UInt8] {
        block(.header, [mode.rawValue, UInt8(address >> 8), UInt8(address & 0xFF), extra.0, extra.1, extra.2])
    }

    /// Mode 0 transfer of `code` to XRAM at `address`: header, data blocks, EOT block.
    ///
    /// `blockLength` is the length of every following DATA/EOT block *including* the type
    /// and checksum bytes. Assumption from the manual's GetBlock routine (R7 = bytes to
    /// receive, the last one being the checksum; a header is received with R7 = 8) — not
    /// checked against a real boot ROM. The EOT block's first data byte is the number of
    /// valid bytes that follow; the rest is padding.
    public static func loadBlocks(_ code: [UInt8], at address: UInt16, blockLength: Int = maxDataArea + 2) -> [[UInt8]] {
        precondition((4...maxDataArea + 2).contains(blockLength))
        let area = blockLength - 2
        var blocks = [header(.loadXRAM, address: address, (0, 0, UInt8(blockLength)))]
        var rest = code[...]
        while rest.count > area - 1 {
            blocks.append(block(.data, Array(rest.prefix(area))))
            rest = rest.dropFirst(area)
        }
        let tail = [UInt8(rest.count)] + Array(rest) + [UInt8](repeating: 0, count: area - 1 - rest.count)
        blocks.append(block(.endOfTransmission, tail))
        return blocks
    }

    /// Checksum of a flash area as the loader computes it (manual figure 10-5): two
    /// registers, each byte added and the register rotated left (8 bits, no carry);
    /// bytes alternate, the first going to checksum #2 (R1), the second to #1 (R0).
    /// Returns (#1, #2) as stored at info block offsets 8 and 9.
    public static func flashChecksum(_ bytes: some Sequence<UInt8>) -> (UInt8, UInt8) {
        var r0: UInt8 = 0, r1: UInt8 = 0, f0 = false
        for b in bytes {
            if f0 { r0 = rol(r0 &+ b) } else { r1 = rol(r1 &+ b) }
            f0.toggle()
        }
        return (r0, r1)
    }

    static func rol(_ v: UInt8) -> UInt8 { v << 1 | v >> 7 }

    /// Info block ID bytes (RL A, RR A, RLC A, RRC A) that make phase I start custom code
    /// in the flash instead of talking to the host — a way to lock the loader.
    public static let infoBlockID: [UInt8] = [0x23, 0x03, 0x33, 0x13]
    /// Sector A and B info block addresses (C509-L stepping CA and later).
    public static let infoBlockAddresses: [UInt16] = [0xC000, 0x6000]

    /// Whether `image` carries a valid info block at C000h or 6000h, i.e. a real C509
    /// would start that code instead of entering the serial loader.
    public static func lockingInfoBlock(in image: [UInt8]) -> UInt16? {
        for base in infoBlockAddresses where Int(base) + 10 <= image.count {
            let b = Int(base)
            guard Array(image[b..<b + 4]) == infoBlockID else { continue }
            let start = Int(image[b + 4]) << 8 | Int(image[b + 5])
            let length = Int(image[b + 6]) << 8 | Int(image[b + 7])
            guard start + length <= image.count else { continue }
            let (c1, c2) = flashChecksum(image[start..<start + length])
            if c1 == image[b + 8], c2 == image[b + 9] { return base }
        }
        return nil
    }
}

public enum BootstrapError: Error, Equatable, LocalizedError {
    case noAcknowledge(received: UInt8, stage: String)
    /// `waitForLoader` ran out of time without a 55h.
    case loaderSilent
    /// No byte at all where the loader or agent should answer — names the step.
    case noReply(stage: String)

    public var errorDescription: String? {
        switch self {
        case .noReply(let stage):
            "Нет ответа от блока на шаге «\(stage)»"
        case .loaderSilent:
            "Блок не вошёл в режим программирования. Выключите питание блока, проверьте +12 В на выводе 47, нажмите «Начать чтение» и только потом включите питание."
        case .noAcknowledge(let r, let stage):
            "Загрузчик C509 не подтвердил «\(stage)»: ответ \(String(format: "%02X", r)) вместо 55"
        }
    }
}

/// Talks to the C509 Bootstrap Loader over a K-line transport (8N2, any baud the cable
/// can do; the loader adapts to it).
public struct BootstrapClient: Sendable {
    public let transport: any KLineTransport
    public var timeout: Duration

    public init(transport: any KLineTransport, timeout: Duration = .seconds(2)) {
        self.transport = transport
        self.timeout = timeout
    }

    /// Phase II: sends the 00h test byte and expects 55h.
    public func synchronize() async throws {
        try await transport.flush()
        try await expectAcknowledge(after: [0x00], stage: "синхронизация")
    }

    /// Phase II for a block that is powered up *after* the host starts: sends 00h every
    /// `interval` until the loader answers 55h or `timeout` runs out. Live spare ECU,
    /// 2026-10-31: the loader measures the baud rate on the first byte it gets after reset,
    /// so it must be powered (with pin 47 high) while we are already sending 00h — any
    /// earlier traffic (cable check at 10400, KWP init) leaves it at a wrong rate.
    /// `onAttempt(n, echo)` reports each try and whether the cable echoed the byte.
    public func waitForLoader(timeout: Duration = .seconds(60), interval: Duration = .milliseconds(200),
                              onAttempt: (@Sendable (Int, Bool) -> Void)? = nil) async throws {
        try await transport.flush()
        let deadline = ContinuousClock.now + timeout
        var attempt = 0
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            attempt += 1
            try await transport.write([0x00])
            var echoed = !transport.echoesWrites
            if transport.echoesWrites {
                echoed = (try? await transport.read(count: 1, timeout: interval)) != nil
            }
            onAttempt?(attempt, echoed)
            if let r = try? await transport.read(count: 1, timeout: interval) {
                if r[0] == BootstrapLoader.acknowledge { return }
                try await transport.flush() // power-up glitch or noise: keep trying
            }
        }
        throw BootstrapError.loaderSilent
    }

    /// Sends bytes and reads the single reply byte (skipping the adapter echo).
    public func exchange(_ bytes: [UInt8]) async throws -> UInt8 {
        try await transport.write(bytes)
        if transport.echoesWrites {
            _ = try await transport.read(count: bytes.count, timeout: timeout)
        }
        return try await transport.read(count: 1, timeout: timeout)[0]
    }

    func expectAcknowledge(after bytes: [UInt8], stage: String) async throws {
        let r: UInt8
        do { r = try await exchange(bytes) } catch KLineError.timeout { throw BootstrapError.noReply(stage: stage) }
        guard r == BootstrapLoader.acknowledge else { throw BootstrapError.noAcknowledge(received: r, stage: stage) }
    }

    /// Pause after each loader acknowledge before the next block. Live spare ECU,
    /// 2026-10-31 (byte trace): a block sent 0 ms after the 55h of the previous one was
    /// echoed in full but never acknowledged — the loader is not yet listening and loses
    /// its first byte(s). A script that waited ~1 s loaded every time. 100 ms is a guess
    /// with margin; it costs ~0,5 s per agent.
    public static let interBlockPause: Duration = .milliseconds(100)

    /// Mode 0: copies `code` into XRAM at `address`.
    public func load(_ code: [UInt8], at address: UInt16) async throws {
        for (i, block) in BootstrapLoader.loadBlocks(code, at: address).enumerated() {
            try await Task.sleep(for: Self.interBlockPause)
            try await expectAcknowledge(after: block, stage: i == 0 ? "заголовок режима 0" : "блок \(i)")
        }
    }

    /// Mode 1: starts the code in XRAM. The loader acknowledges the header and jumps.
    public func run(at address: UInt16) async throws {
        try await Task.sleep(for: Self.interBlockPause)
        try await expectAcknowledge(after: BootstrapLoader.header(.runXRAM, address: address), stage: "запуск из XRAM")
    }

    /// Mode 2: whether the two checksum bytes right after the area match it.
    public func checkFlash(from address: UInt16, length: UInt16) async throws -> Bool {
        let header = BootstrapLoader.header(.checkFlash, address: address, (UInt8(length >> 8), UInt8(length & 0xFF), 0))
        try await expectAcknowledge(after: header, stage: "проверка флеш")
        return try await transport.read(count: 1, timeout: timeout)[0] == BootstrapLoader.acknowledge
    }
}
