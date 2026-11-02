/// Intel 8051 core with the Siemens C517 extensions the Январь firmware uses:
/// 256 bytes of IRAM, 8 data pointers selected by DPSEL (0x92), and SFR hooks
/// for peripherals (MDU, timers, serial port…) implemented outside the core.
///
/// Memory spaces: `code` (64 KB ROM image), `iram` (256 B), `sfr` (0x80–0xFF),
/// `xram` (64 KB, MOVX).
public final class CPU8051 {
    public var code: [UInt8]
    public var iram = [UInt8](repeating: 0, count: 256)
    public var sfr = [UInt8](repeating: 0, count: 256) // indexed by address, 0x80…0xFF used
    public var xram = [UInt8](repeating: 0, count: 0x10000)
    public var pc: UInt16 = 0
    /// Machine cycles executed (12 oscillator periods each on the C517).
    public private(set) var cycles: UInt64 = 0

    /// C517 has 8 DPTRs; DPL/DPH (0x82/0x83) show the one selected by DPSEL.
    var dptrs = [UInt16](repeating: 0, count: 8)

    /// Peripheral hooks: return non-nil to override a read; writes are stored and forwarded.
    public var sfrRead: ((UInt8) -> UInt8?)?
    public var sfrWrite: ((UInt8, UInt8) -> Void)?
    /// Called for every MOVX access when set (XRAM-mapped hardware).
    public var xramRead: ((UInt16) -> UInt8?)?
    public var xramWrite: ((UInt16, UInt8) -> Void)?

    /// Interrupt sources currently requesting service, by vector address.
    public var pendingInterrupts: Set<UInt16> = []
    /// Interrupt priority of each vector (0 low, 1 high); default low.
    public var interruptPriority: [UInt16: Int] = [:]
    /// Returns whether the interrupt at `vector` is enabled (IE bits); set by the board.
    public var interruptEnabled: ((UInt16) -> Bool)?
    /// Called when the CPU vectors to an interrupt, so the board can clear request flags.
    public var onInterruptEntry: ((UInt16) -> Void)?
    /// Priority levels in service (stack of levels).
    private var inService: [Int] = []
    /// Number of interrupts currently in service (0 = main line). Exposed for debugging.
    public var inServiceDepth: Int { inService.count }

    public enum Fault: Error, Equatable {
        case illegalOpcode(UInt8, at: UInt16)
    }

    public static let ACC: UInt8 = 0xE0, B: UInt8 = 0xF0, PSW: UInt8 = 0xD0, SP: UInt8 = 0x81
    public static let DPL: UInt8 = 0x82, DPH: UInt8 = 0x83, DPSEL: UInt8 = 0x92, XPAGE: UInt8 = 0x91
    public static let IEN0: UInt8 = 0xA8

    public init(code: [UInt8]) {
        precondition(code.count <= 0x10000)
        self.code = code + [UInt8](repeating: 0xFF, count: 0x10000 - code.count)
        reset()
    }

    public func reset() {
        pc = 0
        sfr = [UInt8](repeating: 0, count: 256)
        sfr[Int(Self.SP)] = 0x07
        for p: UInt8 in [0x80, 0x90, 0xA0, 0xB0, 0xE8, 0xF8] { sfr[Int(p)] = 0xFF } // ports P0–P5
        dptrs = [UInt16](repeating: 0, count: 8)
        pendingInterrupts = []
        inService = []
    }

    // MARK: - Registers

    public var a: UInt8 {
        get { sfr[Int(Self.ACC)] }
        set { sfr[Int(Self.ACC)] = newValue }
    }
    var b: UInt8 {
        get { sfr[Int(Self.B)] }
        set { sfr[Int(Self.B)] = newValue }
    }
    var psw: UInt8 {
        get { sfr[Int(Self.PSW)] }
        set { sfr[Int(Self.PSW)] = newValue }
    }
    public var sp: UInt8 {
        get { sfr[Int(Self.SP)] }
        set { sfr[Int(Self.SP)] = newValue }
    }
    public var carry: Bool {
        get { psw & 0x80 != 0 }
        set { psw = newValue ? psw | 0x80 : psw & 0x7F }
    }
    var dpselIndex: Int { Int(sfr[Int(Self.DPSEL)] & 0x07) }
    public var dptr: UInt16 {
        get { dptrs[dpselIndex] }
        set { dptrs[dpselIndex] = newValue }
    }
    var bank: Int { Int(psw >> 3) & 0x03 }

    func r(_ n: Int) -> UInt8 { iram[bank * 8 + n] }
    func setR(_ n: Int, _ v: UInt8) { iram[bank * 8 + n] = v }

    // MARK: - Memory access

    /// Direct address: IRAM below 0x80, SFR above.
    public func readDirect(_ addr: UInt8) -> UInt8 {
        addr < 0x80 ? iram[Int(addr)] : readSFR(addr)
    }

    public func writeDirect(_ addr: UInt8, _ v: UInt8) {
        if addr < 0x80 { iram[Int(addr)] = v } else { writeSFR(addr, v) }
    }

    func readSFR(_ addr: UInt8) -> UInt8 {
        switch addr {
        case Self.DPL: return UInt8(dptr & 0xFF)
        case Self.DPH: return UInt8(dptr >> 8)
        case Self.PSW: return (psw & 0xFE) | (a.nonzeroBitCount & 1 == 1 ? 1 : 0)
        default: return sfrRead?(addr) ?? sfr[Int(addr)]
        }
    }

    func writeSFR(_ addr: UInt8, _ v: UInt8) {
        switch addr {
        case Self.DPL: dptr = (dptr & 0xFF00) | UInt16(v)
        case Self.DPH: dptr = (dptr & 0x00FF) | UInt16(v) << 8
        default:
            sfr[Int(addr)] = v
            sfrWrite?(addr, v)
        }
    }

    /// Bit address: 0x00–0x7F → IRAM 0x20–0x2F, 0x80–0xFF → bit-addressable SFRs.
    func bitLocation(_ bit: UInt8) -> (byte: UInt8, mask: UInt8) {
        bit < 0x80 ? (0x20 + bit >> 3, 1 << (bit & 7)) : (bit & 0xF8, 1 << (bit & 7))
    }

    public func readBit(_ bit: UInt8) -> Bool {
        let (byte, mask) = bitLocation(bit)
        return readDirect(byte) & mask != 0
    }

    public func writeBit(_ bit: UInt8, _ v: Bool) {
        let (byte, mask) = bitLocation(bit)
        // Read-modify-write uses the latch, not hooked port pins.
        let current = byte < 0x80 ? iram[Int(byte)] : (byte == Self.PSW ? psw : sfr[Int(byte)])
        writeDirect(byte, v ? current | mask : current & ~mask)
    }

    func readX(_ addr: UInt16) -> UInt8 { xramRead?(addr) ?? xram[Int(addr)] }

    func writeX(_ addr: UInt16, _ v: UInt8) {
        xram[Int(addr)] = v
        xramWrite?(addr, v)
    }

    func push(_ v: UInt8) {
        sp &+= 1
        iram[Int(sp)] = v
    }

    func pop() -> UInt8 {
        defer { sp &-= 1 }
        return iram[Int(sp)]
    }

    func fetch() -> UInt8 {
        defer { pc &+= 1 }
        return code[Int(pc)]
    }

    func fetch16() -> UInt16 {
        let hi = UInt16(fetch())
        return hi << 8 | UInt16(fetch())
    }

    func relJump(_ rel: UInt8) {
        pc = UInt16(bitPattern: Int16(bitPattern: pc) &+ Int16(Int8(bitPattern: rel)))
    }

    // MARK: - Arithmetic

    func add(_ v: UInt8, carryIn: Bool) {
        let c: UInt16 = carryIn ? 1 : 0
        let sum = UInt16(a) + UInt16(v) + c
        let half = (a & 0x0F) + (v & 0x0F) + UInt8(c)
        let signed = Int(Int8(bitPattern: a)) + Int(Int8(bitPattern: v)) + Int(c)
        var f = psw & 0x3B
        if sum > 0xFF { f |= 0x80 }
        if half > 0x0F { f |= 0x40 }
        if signed < -128 || signed > 127 { f |= 0x04 }
        psw = f
        a = UInt8(sum & 0xFF)
    }

    func subb(_ v: UInt8) {
        let c: Int = carry ? 1 : 0
        let diff = Int(a) - Int(v) - c
        let half = Int(a & 0x0F) - Int(v & 0x0F) - c
        let signed = Int(Int8(bitPattern: a)) - Int(Int8(bitPattern: v)) - c
        var f = psw & 0x3B
        if diff < 0 { f |= 0x80 }
        if half < 0 { f |= 0x40 }
        if signed < -128 || signed > 127 { f |= 0x04 }
        psw = f
        a = UInt8(truncatingIfNeeded: diff)
    }

    // MARK: - Execution

    /// Runs one instruction (or an interrupt entry); returns machine cycles used.
    @discardableResult
    public func step() throws -> Int {
        if let vector = nextInterrupt() {
            let level = interruptPriority[vector] ?? 0
            inService.append(level)
            pendingInterrupts.remove(vector)
            push(UInt8(pc & 0xFF))
            push(UInt8(pc >> 8))
            pc = vector
            onInterruptEntry?(vector)
            cycles += 2
            return 2
        }
        let start = pc
        let op = fetch()
        let n = try execute(op, at: start)
        cycles += UInt64(n)
        return n
    }

    /// Runs until at least `machineCycles` have elapsed.
    public func run(machineCycles: Int) throws {
        let target = cycles + UInt64(machineCycles)
        while cycles < target { try step() }
    }

    private func nextInterrupt() -> UInt16? {
        guard !pendingInterrupts.isEmpty, sfr[Int(Self.IEN0)] & 0x80 != 0 else { return nil }
        let current = inService.last ?? -1
        let candidates = pendingInterrupts.filter { interruptEnabled?($0) ?? true }
            .filter { (interruptPriority[$0] ?? 0) > current }
        // Higher priority first, then lower vector address (fixed polling order).
        return candidates.min { (interruptPriority[$0] ?? 0, -Int($0)) > (interruptPriority[$1] ?? 0, -Int($1)) }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func execute(_ op: UInt8, at start: UInt16) throws -> Int {
        let lowRn = Int(op & 0x07)       // Rn for x8–xF
        let ri = Int(op & 0x01)          // Ri for x6/x7
        func atRi() -> UInt8 { iram[Int(r(ri))] }
        func setAtRi(_ v: UInt8) { iram[Int(r(ri))] = v }

        // Operand for the common column layout: x4 #imm, x5 dir, x6/x7 @Ri, x8–xF Rn.
        func operand() -> UInt8 {
            switch op & 0x0F {
            case 0x4: return fetch()
            case 0x5: return readDirect(fetch())
            case 0x6, 0x7: return atRi()
            default: return r(lowRn)
            }
        }

        switch op {
        case 0x00: return 1 // NOP

        case 0x01, 0x21, 0x41, 0x61, 0x81, 0xA1, 0xC1, 0xE1: // AJMP
            let lo = fetch()
            pc = (pc & 0xF800) | UInt16(op >> 5) << 8 | UInt16(lo)
            return 2
        case 0x11, 0x31, 0x51, 0x71, 0x91, 0xB1, 0xD1, 0xF1: // ACALL
            let lo = fetch()
            push(UInt8(pc & 0xFF)); push(UInt8(pc >> 8))
            pc = (pc & 0xF800) | UInt16(op >> 5) << 8 | UInt16(lo)
            return 2
        case 0x02: pc = fetch16(); return 2 // LJMP
        case 0x12: // LCALL
            let target = fetch16()
            push(UInt8(pc & 0xFF)); push(UInt8(pc >> 8))
            pc = target
            return 2
        case 0x22, 0x32: // RET, RETI
            let hi = UInt16(pop()), lo = UInt16(pop())
            pc = hi << 8 | lo
            if op == 0x32, !inService.isEmpty { inService.removeLast() }
            return 2
        case 0x73: pc = dptr &+ UInt16(a); return 2 // JMP @A+DPTR
        case 0x80: let rel = fetch(); relJump(rel); return 2 // SJMP

        case 0x03: a = a >> 1 | a << 7; return 1 // RR
        case 0x13: // RRC
            let c = carry
            carry = a & 1 != 0
            a = a >> 1 | (c ? 0x80 : 0)
            return 1
        case 0x23: a = a << 1 | a >> 7; return 1 // RL
        case 0x33: // RLC
            let c = carry
            carry = a & 0x80 != 0
            a = a << 1 | (c ? 1 : 0)
            return 1

        case 0x04: a &+= 1; return 1
        case 0x05: let d = fetch(); writeDirect(d, readDirectLatch(d) &+ 1); return 1
        case 0x06, 0x07: setAtRi(atRi() &+ 1); return 1
        case 0x08...0x0F: setR(lowRn, r(lowRn) &+ 1); return 1
        case 0x14: a &-= 1; return 1
        case 0x15: let d = fetch(); writeDirect(d, readDirectLatch(d) &- 1); return 1
        case 0x16, 0x17: setAtRi(atRi() &- 1); return 1
        case 0x18...0x1F: setR(lowRn, r(lowRn) &- 1); return 1
        case 0xA3: dptr &+= 1; return 2

        case 0x10, 0x20, 0x30: // JBC, JB, JNB
            let bit = fetch(), rel = fetch()
            let set = readBit(bit)
            if op == 0x30 ? !set : set {
                if op == 0x10 { writeBit(bit, false) }
                relJump(rel)
            }
            return 2
        case 0x40, 0x50, 0x60, 0x70: // JC, JNC, JZ, JNZ
            let rel = fetch()
            let take = switch op {
            case 0x40: carry
            case 0x50: !carry
            case 0x60: a == 0
            default: a != 0
            }
            if take { relJump(rel) }
            return 2

        case 0x24...0x2F: add(operand(), carryIn: false); return 1
        case 0x34...0x3F: add(operand(), carryIn: carry); return 1
        case 0x94...0x9F: subb(operand()); return 1

        case 0x42, 0x52, 0x62: // ORL/ANL/XRL dir,A
            let d = fetch()
            writeDirect(d, logic(op, readDirectLatch(d), a))
            return 1
        case 0x43, 0x53, 0x63: // ORL/ANL/XRL dir,#
            let d = fetch(), imm = fetch()
            writeDirect(d, logic(op, readDirectLatch(d), imm))
            return 2
        case 0x44...0x4F, 0x54...0x5F, 0x64...0x6F:
            a = logic(op, a, operand())
            return 1

        // The bit operand is fetched unconditionally: `carry || readBit(fetch())` would
        // short-circuit and leave PC on the operand byte, executing it as an opcode.
        case 0x72: let b = readBit(fetch()); carry = carry || b; return 2
        case 0x82: let b = readBit(fetch()); carry = carry && b; return 2
        case 0xA0: let b = readBit(fetch()); carry = carry || !b; return 2
        case 0xB0: let b = readBit(fetch()); carry = carry && !b; return 2
        case 0x92: writeBit(fetch(), carry); return 2
        case 0xA2: carry = readBit(fetch()); return 1
        case 0xB2: let bit = fetch(); writeBit(bit, !readBit(bit)); return 1
        case 0xB3: carry.toggle(); return 1
        case 0xC2: writeBit(fetch(), false); return 1
        case 0xC3: carry = false; return 1
        case 0xD2: writeBit(fetch(), true); return 1
        case 0xD3: carry = true; return 1

        case 0x74: a = fetch(); return 1
        case 0x75: let d = fetch(); writeDirect(d, fetch()); return 2
        case 0x76, 0x77: setAtRi(fetch()); return 1
        case 0x78...0x7F: setR(lowRn, fetch()); return 1
        case 0x85: let src = fetch(); let dst = fetch(); writeDirect(dst, readDirect(src)); return 2
        case 0x86, 0x87: writeDirect(fetch(), atRi()); return 2
        case 0x88...0x8F: writeDirect(fetch(), r(lowRn)); return 2
        case 0x90: dptr = fetch16(); return 2
        case 0xA6, 0xA7: setAtRi(readDirect(fetch())); return 2
        case 0xA8...0xAF: setR(lowRn, readDirect(fetch())); return 2
        case 0xE5: a = readDirect(fetch()); return 1
        case 0xE6, 0xE7: a = atRi(); return 1
        case 0xE8...0xEF: a = r(lowRn); return 1
        case 0xF5: writeDirect(fetch(), a); return 1
        case 0xF6, 0xF7: setAtRi(a); return 1
        case 0xF8...0xFF: setR(lowRn, a); return 1

        case 0x83: a = code[Int(pc &+ UInt16(a))]; return 2 // MOVC A,@A+PC
        case 0x93: a = code[Int(dptr &+ UInt16(a))]; return 2 // MOVC A,@A+DPTR
        case 0xE0: a = readX(dptr); return 2
        case 0xE2, 0xE3: a = readX(UInt16(sfr[Int(Self.XPAGE)]) << 8 | UInt16(r(ri))); return 2
        case 0xF0: writeX(dptr, a); return 2
        case 0xF2, 0xF3: writeX(UInt16(sfr[Int(Self.XPAGE)]) << 8 | UInt16(r(ri)), a); return 2

        case 0x84: // DIV AB
            if b == 0 {
                psw |= 0x04
            } else {
                let q = a / b, rem = a % b
                a = q; b = rem
                psw &= ~0x04
            }
            carry = false
            return 4
        case 0xA4: // MUL AB
            let p = UInt16(a) * UInt16(b)
            a = UInt8(p & 0xFF); b = UInt8(p >> 8)
            psw = p > 0xFF ? psw | 0x04 : psw & ~0x04
            carry = false
            return 4

        case 0xB4...0xBF: // CJNE
            let (lhs, rhs): (UInt8, UInt8) = switch op {
            case 0xB4: (a, fetch())
            case 0xB5: (a, readDirect(fetch()))
            case 0xB6, 0xB7: (atRi(), fetch())
            default: (r(lowRn), fetch())
            }
            let rel = fetch()
            carry = lhs < rhs
            if lhs != rhs { relJump(rel) }
            return 2
        case 0xD5: // DJNZ dir
            let d = fetch(), rel = fetch()
            let v = readDirectLatch(d) &- 1
            writeDirect(d, v)
            if v != 0 { relJump(rel) }
            return 2
        case 0xD8...0xDF: // DJNZ Rn
            let rel = fetch()
            setR(lowRn, r(lowRn) &- 1)
            if r(lowRn) != 0 { relJump(rel) }
            return 2

        case 0xC0: push(readDirect(fetch())); return 2
        case 0xD0: let d = fetch(); writeDirect(d, pop()); return 2
        case 0xC4: a = a << 4 | a >> 4; return 1
        case 0xC5: let d = fetch(); let t = readDirect(d); writeDirect(d, a); a = t; return 1
        case 0xC6, 0xC7: let t = atRi(); setAtRi(a); a = t; return 1
        case 0xC8...0xCF: let t = r(lowRn); setR(lowRn, a); a = t; return 1
        case 0xD6, 0xD7: // XCHD
            let t = atRi()
            setAtRi((t & 0xF0) | (a & 0x0F))
            a = (a & 0xF0) | (t & 0x0F)
            return 1
        case 0xD4: // DA A
            var v = Int(a)
            if v & 0x0F > 9 || psw & 0x40 != 0 { v += 6 }
            if v > 0x9F || carry { v += 0x60 }
            if v > 0xFF { carry = true }
            a = UInt8(v & 0xFF)
            return 1
        case 0xE4: a = 0; return 1
        case 0xF4: a = ~a; return 1

        default: // 0xA5
            throw Fault.illegalOpcode(op, at: start)
        }
    }

    /// Read-modify-write instructions read port latches, not pins.
    private func readDirectLatch(_ d: UInt8) -> UInt8 {
        d < 0x80 || d == Self.DPL || d == Self.DPH || d == Self.PSW ? readDirect(d) : sfr[Int(d)]
    }

    private func logic(_ op: UInt8, _ x: UInt8, _ y: UInt8) -> UInt8 {
        switch op & 0xF0 {
        case 0x40: x | y
        case 0x50: x & y
        default: x ^ y
        }
    }
}
