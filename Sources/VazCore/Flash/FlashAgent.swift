import Foundation

/// Read-only flash agent: 8051 code loaded into XRAM by the bootstrap loader (mode 0)
/// and started with mode 1. With SWAP set the external flash is MOVX data memory, so the
/// agent reads it with `movx a,@dptr` and streams it over serial port 0 at the baud rate
/// the loader synchronized to. It never programs or erases the flash.
///
/// Protocol (host → agent):
/// - `'R' addrH addrL countH countL` → `count` bytes (0 = 65536), then their XOR;
/// - `'B' n` → flash half: P6.0 (= A16 of the 128 KB chip, schematic) ← `n & 1`, answers `n`.
///   After reset P6 = FFh, so P6.0 = 1 is the half read so far ("default"); 0 selects the
///   other 64 KB. Only a processor pin changes — nothing is written to the chip.
/// - `'I'` → manufacturer and device ID via the JEDEC autoselect command (AA→5555,
///   55→2AAA, 90→5555; read 0000/0001), then reset (F0h, and FFh for Intel parts).
///   Autoselect does not change the flash contents.
/// On start the agent sends `ready` (A5h).
public enum FlashAgent {
    public static let origin: UInt16 = 0xF420
    /// Port 6 SFR (C509 manual: P6 at FAh, reset FFh; not bit-addressable).
    static let P6: UInt8 = 0xFA
    public static let ready: UInt8 = 0xA5
    static let S0CON: UInt8 = 0x98, S0BUF: UInt8 = 0x99
    static let RI: UInt8 = 0x98, TI: UInt8 = 0x99 // S0CON.0 / S0CON.1 bit addresses

    /// Emits `dropEcho`: waits until the last byte has left (TI), gives the K-line echo of
    /// it ≈0,8 ms to arrive, then clears RI. The ECU hears its own bytes on the single-wire
    /// K-line; live spare ECU 2026-10-31: the echo of the chunk XOR (52h = 'R' after C000)
    /// stayed in S0BUF and was taken as the next command, the read broke at D000.
    /// Uses only A (R7 is saved on the stack). Call it before reading each command.
    static func emitDropEcho(_ a: inout Asm8051) {
        a.label("dropEcho")
        a.jnb(bit: TI, "dropEcho")
        a.push(0x07)                       // R7 of bank 0
        a.movA(4)
        a.label("dropEchoOuter")
        a.movR(7, 0)
        a.label("dropEchoInner")
        a.djnzR(7, "dropEchoInner")        // 256 × 2 cycles ≈ 0,19 ms at 16 MHz
        a.decA(); a.jnz("dropEchoOuter")
        a.pop(0x07)
        a.clr(bit: RI)
        a.ret()
    }

    public static let readOnlyCode: [UInt8] = {
        var a = Asm8051(origin: origin)
        a.setb(bit: TI) // transmitter free: putc waits for TI *before* writing (see putc)
        a.movA(ready)
        a.lcall("putc")
        a.label("main")
        a.lcall("dropEcho") // own K-line echo must not become a command
        a.lcall("getc")
        a.cjneA(UInt8(ascii: "R"), "notRead")
        // 'R': DPTR = address, R7:R6 = count, R5 = running XOR
        a.lcall("getc"); a.movDirectA(0x83)
        a.lcall("getc"); a.movDirectA(0x82)
        a.lcall("getc"); a.movRA(7)
        a.lcall("getc"); a.movRA(6)
        a.movR(5, 0)
        a.label("readLoop")
        a.movxAatDPTR()
        a.lcall("putc")
        a.xrlAR(5); a.movRA(5)
        a.incDPTR()
        a.movAR(6); a.jnz("lowOnly"); a.decR(7)
        a.label("lowOnly")
        a.decR(6)
        a.movAR(6); a.orlAR(7); a.jnz("readLoop")
        a.movAR(5); a.lcall("putc")
        a.sjmp("main")
        a.label("notRead")
        a.cjneA(UInt8(ascii: "B"), "notBank")
        a.lcall("getc"); a.movRA(7)
        a.anlDirect(P6, 0xFE)                 // P6.0 = 0 …
        a.anlA(0x01); a.jz("bankSet")
        a.orlDirect(P6, 0x01)                 // … or 1
        a.label("bankSet")
        a.movAR(7); a.lcall("putc")
        a.sjmp("main")
        a.label("notBank")
        a.cjneA(UInt8(ascii: "I"), "main")
        for (addr, v): (UInt16, UInt8) in [(0x5555, 0xAA), (0x2AAA, 0x55), (0x5555, 0x90)] {
            a.movDPTR(addr); a.movA(v); a.movxAtDPTRa()
        }
        a.movDPTR(0x0000); a.movxAatDPTR(); a.lcall("putc")
        a.incDPTR(); a.movxAatDPTR(); a.lcall("putc")
        a.movA(0xF0); a.movxAtDPTRa()
        a.movA(0xFF); a.movxAtDPTRa()
        a.ljmp("main")
        a.label("getc")
        a.jnb(bit: RI, "getc")
        a.movAdirect(S0BUF)
        a.clr(bit: RI)
        a.ret()
        // Wait for the previous byte, then send. Works whether or not the loader left TI
        // set (it does on the live ECU, 2026-10-31: send-then-wait lost a byte).
        a.label("putc")
        a.jnb(bit: TI, "putc")
        a.clr(bit: TI)
        a.movDirectA(S0BUF)
        a.ret()
        FlashAgent.emitDropEcho(&a)
        return a.assemble()
    }()
}

public enum FlashAgentError: Error, Equatable, LocalizedError {
    case notReady(UInt8)
    case checksum(address: UInt16)

    public var errorDescription: String? {
        switch self {
        case .notReady(let b): "Агент чтения не ответил готовностью (байт \(String(format: "%02X", b)))"
        case .checksum(let a): "Ошибка контрольной суммы при чтении флеш с адреса \(String(format: "%04X", a))"
        }
    }
}

extension BootstrapClient {
    /// Loads and starts the read-only agent; afterwards use `readFlash` / `flashID`.
    public func startReadAgent() async throws {
        try await load(FlashAgent.readOnlyCode, at: FlashAgent.origin)
        try await run(at: FlashAgent.origin)
        let r: UInt8
        do { r = try await transport.read(count: 1, timeout: timeout)[0] } catch KLineError.timeout {
            throw BootstrapError.noReply(stage: "готовность агента (A5)")
        }
        guard r == FlashAgent.ready else { throw FlashAgentError.notReady(r) }
    }

    /// Reads `count` bytes of the 64 KB flash window in chunks, verifying each chunk's XOR.
    public func readFlash(from address: UInt16 = 0, count: Int = 0x10000, chunk: Int = 0x1000,
                          progress: (@Sendable (Int) -> Void)? = nil) async throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        while out.count < count {
            let at = UInt16(truncatingIfNeeded: Int(address) + out.count)
            let n = min(chunk, count - out.count)
            let request: [UInt8] = [UInt8(ascii: "R"), UInt8(at >> 8), UInt8(at & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            try await transport.write(request)
            if transport.echoesWrites { _ = try await transport.read(count: request.count, timeout: timeout) }
            let data = try await transport.read(count: n + 1, timeout: timeout + .milliseconds(n))
            guard BootstrapLoader.xor(data.prefix(n)) == data[n] else { throw FlashAgentError.checksum(address: at) }
            out += data.prefix(n)
            progress?(out.count)
        }
        return out
    }

    /// Selects the 64 KB half of the 128 KB flash: `defaultHalf` = P6.0 high, as after reset
    /// (the half every read so far came from); false = P6.0 low, the other half.
    public func selectFlashHalf(defaultHalf: Bool) async throws {
        let v: UInt8 = defaultHalf ? 1 : 0
        try await transport.write([UInt8(ascii: "B"), v])
        if transport.echoesWrites { _ = try await transport.read(count: 2, timeout: timeout) }
        let r = try await transport.read(count: 1, timeout: timeout)[0]
        guard r == v else { throw FlashAgentError.notReady(r) }
    }

    /// Manufacturer and device ID (AMD Am29F010: 01h/20h).
    public func flashID() async throws -> (manufacturer: UInt8, device: UInt8) {
        try await transport.write([UInt8(ascii: "I")])
        if transport.echoesWrites { _ = try await transport.read(count: 1, timeout: timeout) }
        let id = try await transport.read(count: 2, timeout: timeout)
        return (id[0], id[1])
    }
}
