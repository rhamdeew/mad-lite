import Foundation

/// Read/write flash agent: the read-only agent plus chip erase and byte programming for
/// the AMD Am29F010 (JEDEC command set), loaded into XRAM by the bootstrap loader and run
/// in the C509 programming mode (flash mapped as MOVX data memory). **It erases and writes
/// the flash**, so it is only ever loaded when the user has chosen to reprogram a (spare)
/// ECU — `startReadAgent` stays the path for plain reading.
///
/// Protocol (host → agent), each verb a single ASCII byte:
/// - `'R' addrH addrL countH countL` → `count` bytes then their XOR (as in the read agent);
/// - `'I'` → flash manufacturer/device id (autoselect);
/// - `'E'` → chip erase (AA,55,80,AA,55,10 → 5555), poll 0000 until FFh, then `A5` (or `E5`
///   on a DQ5 timeout). **Erases all 128 KB — the app no longer uses it** (see `'S'`);
/// - `'S' addrH` → erase the 16 KB sector holding `addrH:00` in the current bank
///   (AA,55,80,AA,55, then 30h to the sector), poll until FFh, then `A5` / `E5`;
/// - `'W' addrH addrL countH countL data…` → program `count` bytes from `addr`
///   (each: AA,55,A0 unlock then the byte; poll the cell until it reads back), then their XOR.
///   A byte the chip fails to program (DQ5 timeout) makes the agent reset the chip (F0h),
///   keep consuming the data without programming, and answer the XOR inverted — the host
///   then reports a write error instead of the agent hanging or taking data for commands.
///
/// Polling follows the Am29F010 data-polling algorithm: read until the cell equals the
/// expected value; if DQ5 (exceeded timing limits) shows, read once more — still not equal
/// means the operation failed.
/// On start the agent sends `ready` (A5h).
public enum FlashWriteAgent {
    public static let origin = FlashAgent.origin
    static let S0BUF: UInt8 = 0x99, RI: UInt8 = 0x98, TI: UInt8 = 0x99
    /// Erase reply when the chip reports a timeout (DQ5).
    public static let eraseFailed: UInt8 = 0xE5

    public static let readWriteCode: [UInt8] = {
        var a = Asm8051(origin: origin)
        a.setb(bit: TI) // transmitter free: putc waits before writing
        a.movA(FlashAgent.ready); a.lcall("putc")
        // Dispatch: each cjne jumps only a few bytes to an ljmp, so the handlers may be any length.
        a.label("main")
        a.lcall("dropEcho") // own K-line echo must not become a command
        a.lcall("getc")
        a.cjneA(UInt8(ascii: "R"), "d1"); a.ljmp("doRead")
        a.label("d1"); a.cjneA(UInt8(ascii: "W"), "d2"); a.ljmp("doWrite")
        a.label("d2"); a.cjneA(UInt8(ascii: "E"), "d3"); a.ljmp("doErase")
        a.label("d3"); a.cjneA(UInt8(ascii: "I"), "d4"); a.ljmp("doID")
        a.label("d4"); a.cjneA(UInt8(ascii: "S"), "d5"); a.ljmp("doSector")
        a.label("d5"); a.ljmp("main")

        a.label("doRead")
        // 'R' read: DPTR = addr, R7:R6 = count, R5 = running XOR.
        a.lcall("getc"); a.movDirectA(0x83)
        a.lcall("getc"); a.movDirectA(0x82)
        a.lcall("getc"); a.movRA(7)
        a.lcall("getc"); a.movRA(6)
        a.movR(5, 0)
        a.label("rLoop")
        a.movxAatDPTR(); a.lcall("putc")
        a.xrlAR(5); a.movRA(5)
        a.incDPTR()
        a.movAR(6); a.jnz("rLow"); a.decR(7)
        a.label("rLow"); a.decR(6)
        a.movAR(6); a.orlAR(7); a.jnz("rLoop")
        a.movAR(5); a.lcall("putc")
        a.ljmp("main")

        a.label("doWrite")
        // 'W' write: R3:R2 = addr, R7:R6 = count, R5 = XOR, R4 = data byte.
        a.lcall("getc"); a.movRA(3)
        a.lcall("getc"); a.movRA(2)
        a.lcall("getc"); a.movRA(7)
        a.lcall("getc"); a.movRA(6)
        a.movR(5, 0)
        a.movR(1, 0)                             // R1 ≠ 0: a byte failed, stop programming
        a.label("wLoop")
        a.lcall("getc"); a.movRA(4)
        a.movAR(1); a.jnz("wSkip")               // after a failure only consume the data
        a.movAR(4); a.cjneA(0xFF, "wProg"); a.sjmp("wSkip") // FF = erased already: nothing to program
        a.label("wProg")
        a.lcall("unlock2")
        a.movDPTR(0x5555); a.movA(0xA0); a.movxAtDPTRa()
        a.movDirectR(0x83, 3); a.movDirectR(0x82, 2)
        a.movAR(4); a.movxAtDPTRa()
        a.label("wPoll")                         // data polling: until the cell reads back
        a.movxAatDPTR(); a.xrlAR(4); a.jz("wSkip")
        a.movxAatDPTR(); a.jnb(bit: 0xE5, "wPoll") // ACC.5 = DQ5: still within time → poll on
        a.movxAatDPTR(); a.xrlAR(4); a.jz("wSkip") // DQ5 seen: one more read decides
        a.movR(1, 1)                             // failed: remember, reset the chip
        a.movA(0xF0); a.movxAtDPTRa()
        a.label("wSkip")
        a.movAR(5); a.xrlAR(4); a.movRA(5)       // XOR in the received byte
        a.incR(2); a.movAR(2); a.jnz("wNoC"); a.incR(3)
        a.label("wNoC")
        a.movAR(6); a.jnz("wLow"); a.decR(7)
        a.label("wLow"); a.decR(6)
        a.movAR(6); a.orlAR(7); a.jnz("wLoop")
        a.movAR(1); a.jz("wOk")
        a.movAR(5); a.cplA(); a.sjmp("wSend")   // failure: answer the XOR inverted
        a.label("wOk"); a.movAR(5)
        a.label("wSend"); a.lcall("putc")
        a.ljmp("main")

        a.label("doErase")
        // 'E' chip erase (all 128 KB; kept for completeness, the app erases sectors).
        a.lcall("unlock2"); a.movDPTR(0x5555); a.movA(0x80); a.movxAtDPTRa()
        a.lcall("unlock2"); a.movDPTR(0x5555); a.movA(0x10); a.movxAtDPTRa()
        a.movDPTR(0x0000)
        a.ljmp("erasePoll")

        a.label("doSector")
        // 'S' addrH: erase the 16 KB sector holding addrH:00 (current bank, A16 = P6.0).
        a.lcall("getc"); a.movRA(3)
        a.lcall("unlock2"); a.movDPTR(0x5555); a.movA(0x80); a.movxAtDPTRa()
        a.lcall("unlock2")
        a.movDirectR(0x83, 3); a.movDirect(0x82, 0x00)
        a.movA(0x30); a.movxAtDPTRa()
        // DPTR stays in the sector for polling.

        // Data polling for erase: done when the cell reads FFh; DQ5 → one more read decides.
        a.label("erasePoll")
        a.movxAatDPTR(); a.cjneA(0xFF, "eBusy"); a.sjmp("eDone")
        a.label("eBusy")
        a.jnb(bit: 0xE5, "erasePoll")            // ACC.5 = DQ5
        a.movxAatDPTR(); a.cjneA(0xFF, "eFail"); a.sjmp("eDone")
        a.label("eFail")
        a.movA(0xF0); a.movxAtDPTRa()            // reset the chip to read mode
        a.movA(eraseFailed); a.lcall("putc")
        a.ljmp("main")
        a.label("eDone")
        a.movA(FlashAgent.ready); a.lcall("putc")
        a.ljmp("main")

        a.label("doID")
        for (addr, v): (UInt16, UInt8) in [(0x5555, 0xAA), (0x2AAA, 0x55), (0x5555, 0x90)] {
            a.movDPTR(addr); a.movA(v); a.movxAtDPTRa()
        }
        a.movDPTR(0x0000); a.movxAatDPTR(); a.lcall("putc")
        a.incDPTR(); a.movxAatDPTR(); a.lcall("putc")
        a.movA(0xF0); a.movxAtDPTRa()
        a.ljmp("main")

        // AA→5555, 55→2AAA (the common unlock prefix).
        a.label("unlock2")
        a.movDPTR(0x5555); a.movA(0xAA); a.movxAtDPTRa()
        a.movDPTR(0x2AAA); a.movA(0x55); a.movxAtDPTRa()
        a.ret()

        a.label("getc"); a.jnb(bit: RI, "getc"); a.movAdirect(S0BUF); a.clr(bit: RI); a.ret()
        a.label("putc"); a.jnb(bit: TI, "putc"); a.clr(bit: TI); a.movDirectA(S0BUF); a.ret()
        FlashAgent.emitDropEcho(&a)
        return a.assemble()
    }()
}

public enum FlashWriteError: Error, Equatable, LocalizedError {
    case notReady(UInt8)
    case eraseFailed(UInt8)
    case verifyChecksum(address: UInt16)
    case programFailed(address: UInt16)
    case verifyMismatch(address: Int)
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .notReady(let b): "Агент записи не ответил готовностью (байт \(String(format: "%02X", b)))"
        case .eraseFailed(let b): b == FlashWriteAgent.eraseFailed
            ? "Микросхема не смогла стереть сектор (DQ5 — превышено время)"
            : "Стирание не подтверждено (ответ \(String(format: "%02X", b)) вместо A5)"
        case .verifyChecksum(let a): "Ошибка контрольной суммы при записи блока с адреса \(String(format: "%04X", a)) (искажение по линии)"
        case .programFailed(let a): "Микросхема не записала байт в блоке с адреса \(String(format: "%04X", a)) (DQ5)"
        case .verifyMismatch(let a): "Проверка: записанное не совпало по адресу \(String(format: "%04X", a))"
        case .refused(let why): why
        }
    }
}

/// What `programImage` did, for the log and the UI.
public struct FlashProgramReport: Sendable, Equatable {
    /// 16 KB sectors (0…3 of the 64 KB window) that were erased and written.
    public var sectors: [Int] = []
    /// Bytes that differed between the block and the image before writing.
    public var differingBytes = 0
    public var bytesSent = 0
}

extension FlashWriteAgent {
    public static let sectorSize = 0x4000

    /// Why `image` must not be written, or nil. Size must be 64 KB; an image carrying a
    /// bootstrap info block (`23 03 33 13` + valid checksum at C000/6000) would make the boot
    /// ROM start that code instead of the serial loader — the loader is our only way to
    /// recover a block, so such an image is never written.
    public static func refusalReason(_ image: [UInt8]) -> String? {
        guard image.count == 0x10000 else { return "Образ не 64 КБ (\(image.count) Б) — запись запрещена." }
        if let at = BootstrapLoader.lockingInfoBlock(in: image) {
            return String(format: "В образе загрузочный инфо-блок по %04X: после записи встроенный загрузчик перестанет отвечать и блок нельзя будет перепрошить по K-line. Запись запрещена.", at)
        }
        return nil
    }
}

extension BootstrapClient {
    /// Loads and starts the read/write agent. **Use only to reprogram a spare ECU.**
    public func startWriteAgent() async throws {
        try await load(FlashWriteAgent.readWriteCode, at: FlashWriteAgent.origin)
        try await run(at: FlashWriteAgent.origin)
        let r: UInt8
        do { r = try await transport.read(count: 1, timeout: timeout)[0] } catch KLineError.timeout {
            throw BootstrapError.noReply(stage: "готовность агента записи (A5)")
        }
        guard r == FlashAgent.ready else { throw FlashWriteError.notReady(r) }
    }

    /// Erases the whole chip (all 128 KB → FFh). **Not used by the app** — see `eraseSector`.
    public func eraseChip(timeout eraseTimeout: Duration = .seconds(60)) async throws {
        try await transport.write([UInt8(ascii: "E")])
        if transport.echoesWrites { _ = try await transport.read(count: 1, timeout: timeout) }
        let r = try await transport.read(count: 1, timeout: eraseTimeout)[0]
        guard r == FlashAgent.ready else { throw FlashWriteError.eraseFailed(r) }
    }

    /// Erases one 16 KB sector (0…3) of the current 64 KB bank; the other bank is untouched.
    /// Am29F010: sector erase typically 1 s, the agent reports a chip timeout (DQ5) as E5h.
    public func eraseSector(_ sector: Int, timeout eraseTimeout: Duration = .seconds(30)) async throws {
        let request: [UInt8] = [UInt8(ascii: "S"), UInt8(sector * FlashWriteAgent.sectorSize >> 8)]
        try await transport.write(request)
        if transport.echoesWrites { _ = try await transport.read(count: request.count, timeout: timeout) }
        let r = try await transport.read(count: 1, timeout: eraseTimeout)[0]
        guard r == FlashAgent.ready else { throw FlashWriteError.eraseFailed(r) }
    }

    /// Programs `image` to the flash window in chunks, checking each chunk's returned XOR.
    /// The target area must be erased first. Chunks that are all FFh are skipped (an
    /// erased cell already reads FFh). Does not verify by read-back — `programImage` does.
    @discardableResult
    public func writeFlash(_ image: [UInt8], from address: UInt16 = 0, chunk: Int = 0x400,
                           progress: (@Sendable (Int) -> Void)? = nil) async throws -> Int {
        var done = 0, sent = 0
        while done < image.count {
            let at = UInt16(truncatingIfNeeded: Int(address) + done)
            let n = min(chunk, image.count - done)
            let data = Array(image[done..<done + n])
            if data.contains(where: { $0 != 0xFF }) {
                let request: [UInt8] = [UInt8(ascii: "W"), UInt8(at >> 8), UInt8(at & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + data
                try await transport.write(request)
                if transport.echoesWrites { _ = try await transport.read(count: request.count, timeout: timeout + .milliseconds(2 * n)) }
                let xor = try await transport.read(count: 1, timeout: timeout + .milliseconds(n))[0]
                let expected = BootstrapLoader.xor(data)
                if xor == ~expected { throw FlashWriteError.programFailed(address: at) }
                guard xor == expected else { throw FlashWriteError.verifyChecksum(address: at) }
                sent += n
            }
            done += n
            progress?(done)
        }
        return sent
    }

    /// The safe full program, in this order:
    /// 1. `current` — the block's 64 KB read just before (the caller saves it as a backup
    ///    first); nil reads it here;
    /// 2. erase only the 16 KB sectors that differ from `image` (all four with `force`) —
    ///    sector erase, never chip erase, so the other 64 KB bank is not touched;
    /// 3. program those sectors (all-FF chunks skipped);
    /// 4. read the whole 64 KB back and compare byte for byte.
    /// Refuses images `FlashWriteAgent.refusalReason` rejects.
    @discardableResult
    public func programImage(_ image: [UInt8], current known: [UInt8]? = nil, force: Bool = false,
                             onBackup: (@Sendable (Int) -> Void)? = nil,
                             onErase: (@Sendable (Int) -> Void)? = nil,
                             onWrite: (@Sendable (Int) -> Void)? = nil,
                             onVerify: (@Sendable (Int) -> Void)? = nil) async throws -> FlashProgramReport {
        if let why = FlashWriteAgent.refusalReason(image) { throw FlashWriteError.refused(why) }
        var report = FlashProgramReport()
        var current: [UInt8]
        if let known { current = known } else { current = try await readFlash(count: image.count, progress: onBackup) }
        guard current.count == image.count else { throw FlashWriteError.refused("Резервная копия не 64 КБ — запись не начата.") }
        report.differingBytes = zip(current, image).filter { $0 != $1 }.count
        let size = FlashWriteAgent.sectorSize
        report.sectors = (0..<4).filter { s in force || current[s * size..<(s + 1) * size] != image[s * size..<(s + 1) * size] }
        for s in report.sectors {
            onErase?(s)
            try await eraseSector(s)
        }
        for (i, s) in report.sectors.enumerated() {
            let base = s * size, before = i * size
            report.bytesSent += try await writeFlash(Array(image[base..<base + size]), from: UInt16(base)) { n in onWrite?(before + n) }
        }
        let back = try await readFlash(count: image.count, progress: onVerify)
        if let i = (0..<image.count).first(where: { back[$0] != image[$0] }) { throw FlashWriteError.verifyMismatch(address: i) }
        return report
    }
}
