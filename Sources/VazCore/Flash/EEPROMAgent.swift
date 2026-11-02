import Foundation

/// Read/write agent for the Январь 5.1 serial EEPROM (24C04, 512 B) on the bit-banged I²C bus
/// (SCL = P3.3, SDA = P1.5, open-collector / wired-AND). Loaded into XRAM by the C509 bootstrap
/// loader and run like the flash agent; it talks the bus itself (firmware-independent), so it
/// works whatever is in the flash. Used to back up the EEPROM and to write a copy with the
/// immobilizer disabled (`Immobilizer.defeat`).
///
/// Protocol (host → agent), each verb one ASCII byte:
/// - `'r' dev addr count` → `count` bytes read from device `dev` starting at word `addr`, then XOR;
/// - `'w' dev addr count data…` → program `count` bytes, then XOR;
/// - `dev` is the I²C device address with the block bit (A0h, A2h, … for 24C04 upper block).
/// On start the agent sends `ready` (A5h). (Emulator: writes are instant; real hardware needs a
/// write-cycle delay / ACK-poll after each byte — see note at `writeEEPROM`.)
public enum EEPROMAgent {
    public static let origin = FlashAgent.origin
    static let SDA: UInt8 = 0x95   // P1.5
    static let SCL: UInt8 = 0xB3   // P3.3
    static let S0BUF: UInt8 = 0x99, RI: UInt8 = 0x98, TI: UInt8 = 0x99

    public static let code: [UInt8] = {
        var a = Asm8051(origin: origin)
        a.setb(bit: TI) // transmitter free: putc waits before writing
        a.setb(bit: SCL); a.setb(bit: SDA)      // idle bus high
        a.movA(FlashAgent.ready); a.lcall("putc")

        a.label("main")
        a.lcall("dropEcho") // own K-line echo must not become a command
        a.lcall("getc")
        a.cjneA(UInt8(ascii: "r"), "notR"); a.ljmp("doRead")
        a.label("notR"); a.cjneA(UInt8(ascii: "w"), "main2"); a.ljmp("doWrite")
        a.label("main2"); a.ljmp("main")

        // --- 'r': START, dev&FE, addr, reSTART, dev|1, count×(rx, putc, ack/nack), STOP, XOR
        a.label("doRead")
        a.lcall("getc"); a.movRA(3)             // R3 = dev
        a.lcall("getc"); a.movRA(2)             // R2 = word addr
        a.lcall("getc"); a.movRA(6)             // R6 = count (1..255; 0 treated as 256 not supported)
        a.movR(5, 0)                            // R5 = XOR
        a.lcall("i2cStart")
        a.movAR(3); a.anlA(0xFE); a.movRA(4); a.lcall("i2cTx")   // dev write
        a.movAR(2); a.movRA(4); a.lcall("i2cTx")                // word addr
        a.lcall("i2cStart")                                     // repeated START
        a.movAR(3); a.orlA(0x01); a.movRA(4); a.lcall("i2cTx")  // dev read
        a.label("rLoop")
        a.lcall("i2cRx")                        // R4 = byte
        a.movAR(4); a.lcall("putc")
        a.movAR(5); a.xrlAR(4); a.movRA(5)
        a.decR(6); a.movAR(6); a.jz("rLast")
        a.lcall("i2cAck"); a.sjmp("rLoop")
        a.label("rLast")
        a.lcall("i2cNack")
        a.lcall("i2cStop")
        a.movAR(5); a.lcall("putc")
        a.ljmp("main")

        // --- 'w': byte by byte: START, dev&FE, addr, data, STOP; XOR at the end
        a.label("doWrite")
        a.lcall("getc"); a.movRA(3)             // R3 = dev
        a.lcall("getc"); a.movRA(2)             // R2 = word addr
        a.lcall("getc"); a.movRA(6)             // R6 = count
        a.movR(5, 0)                            // R5 = XOR
        a.label("wLoop")
        a.lcall("getc"); a.movRA(7)             // R7 = data byte
        a.lcall("i2cStart")
        a.movAR(3); a.anlA(0xFE); a.movRA(4); a.lcall("i2cTx")   // dev write
        a.movAR(2); a.movRA(4); a.lcall("i2cTx")                // word addr
        a.movAR(7); a.movRA(4); a.lcall("i2cTx")                // data
        a.lcall("i2cStop")                                      // STOP starts the write cycle
        // ACK-poll: the 24Cxx NACKs its device address until the internal write finishes
        // (~5 ms on real hardware; instant in the emulator). Bounded by R0 so a missing chip
        // does not hang the agent.
        a.movR(0, 0)                            // 256 tries
        a.label("wPoll")
        a.lcall("i2cStart")
        a.movAR(3); a.anlA(0xFE); a.movRA(4); a.lcall("i2cTx")  // dev write; C = ACK bit
        a.lcall("i2cStop")
        a.jnc("wDone")                          // C=0 → ACK → write finished
        a.djnzR(0, "wPoll")                     // else retry until R0 exhausted
        a.label("wDone")
        a.movAR(5); a.xrlAR(7); a.movRA(5)
        a.incR(2)                               // next word addr (within 256-byte block)
        a.decR(6); a.movAR(6); a.jnz("wLoop")
        a.movAR(5); a.lcall("putc")
        a.ljmp("main")

        // --- I²C primitives (open-collector: drive low = clr pin, release = setb pin) ---
        // Every line change is followed by `i2cDelay` (≈5 µs): the 24C04 at 100 kHz needs
        // SCL high ≥ 4 µs, low ≥ 4,7 µs, and drives SDA up to 3,5 µs after SCL falls (tAA).
        // Without it the agent clocked the bus at ≈1 MHz — fine in the emulator, too fast
        // for the real chip (found before the first live EEPROM read, 2026-10-31).
        func pin(_ set: Bool, _ bit: UInt8) {
            if set { a.setb(bit: bit) } else { a.clr(bit: bit) }
            a.lcall("i2cDelay")
        }
        a.label("i2cStart")
        pin(true, SDA); pin(true, SCL); pin(false, SDA); pin(false, SCL); a.ret()

        a.label("i2cStop")
        pin(false, SDA); pin(true, SCL); pin(true, SDA); a.ret()

        // i2cTx: send R4 MSB first; returns C = slave ACK bit (0 = ACK).
        a.label("i2cTx")
        a.movR(1, 8)
        a.label("txBit")
        a.movAR(4); a.rlcA(); a.movRA(4)        // MSB → C
        pin(false, SCL); a.movBitC(SDA); a.lcall("i2cDelay"); pin(true, SCL); pin(false, SCL)
        a.djnzR(1, "txBit")
        pin(false, SCL); pin(true, SDA); pin(true, SCL); a.movCbit(SDA); pin(false, SCL)
        a.ret()

        // i2cRx: receive a byte into R4 (no ACK sent).
        a.label("i2cRx")
        a.movR(1, 8); a.movR(4, 0)
        a.label("rxBit")
        pin(false, SCL); pin(true, SDA); pin(true, SCL)
        a.movCbit(SDA)
        a.movAR(4); a.rlcA(); a.movRA(4)
        pin(false, SCL)
        a.djnzR(1, "rxBit")
        a.ret()

        a.label("i2cAck")
        pin(false, SCL); pin(false, SDA); pin(true, SCL); pin(false, SCL); pin(true, SDA); a.ret()
        a.label("i2cNack")
        pin(false, SCL); pin(true, SDA); pin(true, SCL); pin(false, SCL); a.ret()

        // ≈5 µs at 16 MHz (375 ns per machine cycle): lcall 2 + 10 × nop + ret 2 = 14 cycles.
        // Touches no registers or flags.
        a.label("i2cDelay")
        for _ in 0..<10 { a.nop() }
        a.ret()

        a.label("getc"); a.jnb(bit: RI, "getc"); a.movAdirect(S0BUF); a.clr(bit: RI); a.ret()
        a.label("putc"); a.jnb(bit: TI, "putc"); a.clr(bit: TI); a.movDirectA(S0BUF); a.ret()
        FlashAgent.emitDropEcho(&a)
        return a.assemble()
    }()
}

public enum EEPROMError: Error, Equatable, LocalizedError {
    case notReady(UInt8)
    case checksum(block: Int, address: Int)

    public var errorDescription: String? {
        switch self {
        case .notReady(let b): "Агент EEPROM не ответил готовностью (байт \(String(format: "%02X", b)))"
        case .checksum(let blk, let a): "Ошибка контрольной суммы EEPROM (блок \(blk), адрес \(String(format: "%02X", a)))"
        }
    }
}

extension BootstrapClient {
    /// Loads and starts the EEPROM agent. Use after `synchronize()`.
    public func startEEPROMAgent() async throws {
        try await load(EEPROMAgent.code, at: EEPROMAgent.origin)
        try await run(at: EEPROMAgent.origin)
        let r: UInt8
        do { r = try await transport.read(count: 1, timeout: timeout)[0] } catch KLineError.timeout {
            throw BootstrapError.noReply(stage: "готовность агента (A5)")
        }
        guard r == FlashAgent.ready else { throw EEPROMError.notReady(r) }
    }

    /// Device address A0h with the 256-byte block in bit 1 (24C04: block 0 or 1).
    static func eepromDevice(block: Int) -> UInt8 { 0xA0 | UInt8((block & 0x07) << 1) }

    /// Reads `size` bytes of the 24C04 in 128-byte chunks (a chunk never crosses a 256-byte
    /// block), verifying each chunk's XOR.
    static let eepromChunk = 128

    public func readEEPROM(size: Int = 512, progress: (@Sendable (Int) -> Void)? = nil) async throws -> [UInt8] {
        var out: [UInt8] = []
        while out.count < size {
            let at = out.count
            let n = min(Self.eepromChunk, size - at)
            let request: [UInt8] = [UInt8(ascii: "r"), Self.eepromDevice(block: at / 256), UInt8(at % 256), UInt8(n)]
            try await transport.write(request)
            if transport.echoesWrites { _ = try await transport.read(count: request.count, timeout: timeout) }
            let data = try await transport.read(count: n + 1, timeout: timeout + .milliseconds(n))
            guard BootstrapLoader.xor(data.prefix(n)) == data[n] else { throw EEPROMError.checksum(block: at / 256, address: at % 256) }
            out += data.prefix(n)
            progress?(out.count)
        }
        return out
    }

    /// Writes `image` to the 24C04, 256 per block, checking each block's returned XOR.
    /// Note: the agent writes byte by byte with a STOP after each (which starts the chip's
    /// internal write). The emulator completes instantly; **real hardware needs a ~5 ms
    /// write-cycle delay or ACK-poll per byte** — add it before using on a real ECU.
    public func writeEEPROM(_ image: [UInt8], progress: (@Sendable (Int) -> Void)? = nil) async throws {
        var done = 0
        while done < image.count {
            let n = min(Self.eepromChunk, image.count - done)
            let data = Array(image[done..<done + n])
            let request: [UInt8] = [UInt8(ascii: "w"), Self.eepromDevice(block: done / 256), UInt8(done % 256), UInt8(n)] + data
            try await transport.write(request)
            if transport.echoesWrites { _ = try await transport.read(count: request.count, timeout: timeout + .milliseconds(n)) }
            let xor = try await transport.read(count: 1, timeout: timeout + .milliseconds(n))[0]
            guard xor == BootstrapLoader.xor(data) else { throw EEPROMError.checksum(block: done / 256, address: done % 256) }
            done += n
            progress?(done)
        }
    }

    /// Writes `image` then reads it back and compares — the safe EEPROM program.
    public func programEEPROM(_ image: [UInt8],
                              onWrite: (@Sendable (Int) -> Void)? = nil,
                              onVerify: (@Sendable (Int) -> Void)? = nil) async throws {
        try await writeEEPROM(image, progress: onWrite)
        let back = try await readEEPROM(size: image.count, progress: onVerify)
        if let i = (0..<image.count).first(where: { back[$0] != image[$0] }) {
            throw EEPROMError.checksum(block: i / 256, address: i % 256)
        }
    }
}
