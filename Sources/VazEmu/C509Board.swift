/// Siemens C509-L on-chip peripherals around a `CPU8051` core.
/// Register layout and behaviour follow the C509-L user manual (1997-11).
///
/// Implemented: timers 0/1 with PRSC prescaler, interrupt controller (sources used by
/// the Январь firmware), MDU (mul/div; shift/normalize), serial port 0 with the
/// 10-bit baud rate generator, A/D converter with injectable inputs.
/// Timer 2 with the capture/compare registers CRC, CC1–CC3 (capture on pin edge, capture on
/// write, compare → IEX flag), and a 60-2 crank wheel generator on P1.3/CC3.
/// Compare timers CT/CT1, CM0–CM7 and COMSET/COMCLR outputs; port direction registers
/// (PMOD/PDIR) and the serial EEPROM on the bit-banged I²C bus.
/// Programmable watchdog: start, double-instruction refresh, reset with WDTS (manual 8.1).
/// Relay driver on port 9 (`OutputDriver`).
/// Not yet: CC10–17, CC4–CC7, serial port 1, oscillator watchdog.
public final class C509Board {
    public let cpu: CPU8051

    /// 10-bit A/D input per channel (0…1023), set by the engine model.
    public var adcInputs = [UInt16](repeating: 512, count: 16)
    /// Bytes the ECU has sent on serial port 0.
    public private(set) var serialOut: [UInt8] = []
    /// Bytes waiting to be received by serial port 0.
    public var serialIn: [UInt8] = []
    /// Single-wire K-line: the ECU hears its own bytes. When set, each transmitted byte
    /// lands in S0BUF with RI0 (overwriting — on the live spare ECU, 2026-10-31, the *last*
    /// byte of a reply was left over as a stale "command"). Set by the bootstrap model for
    /// agents; the normal firmware model keeps it off.
    public var echoesTransmit = false
    /// Port pin levels driven from outside, by port SFR address (default all high).
    public var portInputs: [UInt8: UInt8] = [:]
    /// Serial EEPROM 24Cxx: SCL = P3.3, SDA = P1.5 (blank, FFh).
    public let eeprom = I2CEEPROM()
    /// Relay / lamp driver on port 9 (select P9.2, clock P9.0, data P9.3).
    public let outputDriver = OutputDriver()

    // SFR addresses
    static let TCON: UInt8 = 0x88, TMOD: UInt8 = 0x89, TL0: UInt8 = 0x8A, TL1: UInt8 = 0x8B
    static let TH0: UInt8 = 0x8C, TH1: UInt8 = 0x8D, PCON: UInt8 = 0x87
    static let S0CON: UInt8 = 0x98, S0BUF: UInt8 = 0x99, S0RELL: UInt8 = 0xAA, S0RELH: UInt8 = 0xBA
    static let IEN0: UInt8 = 0xA8, IP0: UInt8 = 0xA9, IEN1: UInt8 = 0xB8, IP1: UInt8 = 0xB9
    static let PRSC: UInt8 = 0xB4, IRCON0: UInt8 = 0xC0
    static let ADCON0: UInt8 = 0xD8, ADDATH: UInt8 = 0xD9, ADDATL: UInt8 = 0xDA, ADCON1: UInt8 = 0xDC
    static let MD0: UInt8 = 0xE9, MD5: UInt8 = 0xEE, ARCON: UInt8 = 0xEF
    static let T2CON: UInt8 = 0xC8, CCEN: UInt8 = 0xC1, TL2: UInt8 = 0xCC, TH2: UInt8 = 0xCD, CTCON: UInt8 = 0xE1
    static let CT1CON: UInt8 = 0xBC, CTREL: UInt8 = 0xDE, CTRELH: UInt8 = 0xDF, SYSCON: UInt8 = 0xB1
    static let IEN2: UInt8 = 0x9A, IEN3: UInt8 = 0xBE, IRCON1: UInt8 = 0xD1
    static let CMEN: UInt8 = 0xF6, CMSEL: UInt8 = 0xF7, P4: UInt8 = 0xE8
    /// Low byte SFR of compare registers CM0…CM7; the high byte follows it.
    static let cmLow: [UInt8] = [0xD2, 0xD4, 0xD6, 0xE2, 0xE4, 0xE6, 0xF2, 0xF4]
    /// Low byte SFR of CRC (CC0), CC1, CC2, CC3; the high byte follows it.
    static let ccLow: [UInt8] = [0xCA, 0xC2, 0xC4, 0xC6]

    public init(rom: [UInt8]) {
        cpu = CPU8051(code: rom)
        cpu.sfr[Int(Self.PRSC)] = 0xD5
        cpu.sfr[Int(Self.S0RELL)] = 0xD9
        cpu.sfr[Int(Self.S0RELH)] = 0x03
        cpu.sfrRead = { [unowned self] in self.read($0) }
        cpu.sfrWrite = { [unowned self] in self.write($0, $1) }
        cpu.interruptEnabled = { [unowned self] in self.isEnabled($0) }
        cpu.onInterruptEntry = { [unowned self] in self.acknowledge($0) }
    }

    private func sfr(_ a: UInt8) -> UInt8 { cpu.sfr[Int(a)] }
    private func setSFR(_ a: UInt8, _ v: UInt8) { cpu.sfr[Int(a)] = v }
    private func bit(_ a: UInt8, _ n: Int) -> Bool { sfr(a) & (1 << n) != 0 }
    private func setBit(_ a: UInt8, _ n: Int, _ v: Bool) {
        setSFR(a, v ? sfr(a) | 1 << n : sfr(a) & ~(1 << n))
    }

    // MARK: - Run loop

    /// Executes one instruction and advances peripherals by its machine cycles.
    @discardableResult
    public func step() throws -> Int {
        stepIndex += 1
        updateInterruptRequests()
        let n = try cpu.step()
        tickTimers(n)
        tickTimer2(n)
        tickCompareTimers(n)
        tickSerial(n)
        tickCrank()
        tickPortDirection()
        eeprom.update(scl: driven(Self.P3) & 0x08 != 0, sda: driven(Self.P1) & 0x20 != 0)
        let p9 = driven(0xF9)
        outputDriver.update(select: p9 & 0x04 != 0, clock: p9 & 0x01 != 0, data: p9 & 0x08 != 0)
        tickWatchdog(n)
        if let trace = outputTrace {
            let p4 = port4Pins, p5 = port5Pins
            if p4 != trace.last4 || p5 != trace.last5 {
                outputTrace!.record(cycle: cpu.cycles, port4: p4, port5: p5, crankDegrees: crankDegrees)
            }
        }
        return n
    }

    public func run(machineCycles: Int) throws {
        let target = cpu.cycles + UInt64(machineCycles)
        while cpu.cycles < target { try step() }
    }

    // MARK: - SFR access

    private func read(_ a: UInt8) -> UInt8? {
        switch a {
        case _ where pdirActive && Self.ports.contains(a):
            return nil // direction register, swapped into the SFR slot
        case 0x80, 0x90, 0xA0, 0xB0, 0xF8, 0xF9, 0xFA, 0xE8:
            // Port pins: driven level (latch, compare outputs, direction) AND external level.
            var external = portInputs[a] ?? 0xFF
            if a == Self.P1, !eeprom.sdaOut { external &= ~0x20 } // EEPROM pulls SDA low
            return driven(a) & external
        case 0xDB, 0xDD:
            // Input-only ports 7/8 (digital view of the analog pins).
            return sfr(a) & (portInputs[a] ?? 0xFF)
        case Self.MD0...Self.MD5:
            return mdu.read(Int(a - Self.MD0))
        case Self.CTREL, Self.CTRELH:
            // Mapped pair CTREL (RMAP=0) / CT1REL (RMAP=1), manual 6.3.2.1.
            let reload = rmap ? ct1Reload : ctReload
            return a == Self.CTREL ? UInt8(reload & 0xFF) : UInt8(reload >> 8)
        case Self.ARCON:
            return mdu.arcon
        default:
            return nil
        }
    }

    private func write(_ a: UInt8, _ v: UInt8) {
        switch a {
        case Self.MD0...Self.MD5:
            mdu.write(Int(a - Self.MD0), v)
        case Self.ARCON:
            mdu.shift(arcon: v)
            setSFR(Self.ARCON, mdu.arcon)
        case Self.S0BUF:
            startTransmit(v)
        case Self.ccLow[0], Self.ccLow[1], Self.ccLow[2], Self.ccLow[3]:
            // Mode 11: writing the low byte latches timer 2 into the register.
            let channel = Self.ccLow.firstIndex(of: a)!
            if ccMode(channel) == 3 { latch(channel) }
        case Self.ADDATL:
            convertADC()
        case Self.CTREL, Self.CTRELH:
            // Writing the low byte starts/reloads the corresponding compare timer.
            if rmap {
                ct1Reload = a == Self.CTREL ? ct1Reload & 0xFF00 | Int(v) : ct1Reload & 0x00FF | Int(v) << 8
                if a == Self.CTREL { ct1Count = ct1Reload }
            } else {
                ctReload = a == Self.CTREL ? ctReload & 0xFF00 | Int(v) : ctReload & 0x00FF | Int(v) << 8
                if a == Self.CTREL { ctCount = ctReload }
            }
            // Keep the visible SFR slot consistent with the RMAP=0 view.
            setSFR(Self.CTREL, UInt8(ctReload & 0xFF))
            setSFR(Self.CTRELH, UInt8(ctReload >> 8))
        case Self.cmLow[0], Self.cmLow[1], Self.cmLow[2], Self.cmLow[3],
             Self.cmLow[4], Self.cmLow[5], Self.cmLow[6], Self.cmLow[7]:
            // Low-byte write loads the compare register: mode 1 directly, mode 0 at
            // the next compare-timer overflow (TOC).
            let x = Self.cmLow.firstIndex(of: a)!
            if cmMode0(x) { cmLoadPending[x] = true } else { cmLatch[x] = cmRegister(x) }
        case Self.IP1 where v & 0x80 != 0:
            armPortDirection()
        case Self.IEN0 where v & 0x40 != 0:
            wdtArmedStep = stepIndex // WDT: a refresh if the next instruction sets SWDT
        case Self.IEN1 where v & 0x40 != 0:
            if wdtCount == nil || wdtArmedStep == stepIndex - 1 { reloadWatchdog() }
        case _ where pdirActive:
            break // direction register write, kept in the SFR slot until the window closes
        case Self.P4:
            // Pins not in compare mode 1 follow the latch at once; mode-1 pins keep their
            // level until the next match (the write went to the shadow latch).
            let shadowed = cmMode1Mask
            p4Mode1Pins = p4Mode1Pins & shadowed | v & ~shadowed
        default:
            break
        }
    }

    // MARK: - Output trace

    /// Port 4 and 5 pin changes (injector and ignition drivers) with the crank position,
    /// recorded while non-nil: set `outputTrace = OutputTrace()` to start.
    public var outputTrace: OutputTrace?

    public struct OutputTrace: Sendable {
        public struct Edge: Sendable {
            public let cycle: UInt64
            public let port4: UInt8
            public let port5: UInt8
            /// Crank angle, degrees after the first tooth past the gap (see `crankDegrees`).
            public let crankDegrees: Double
        }
        public private(set) var edges: [Edge] = []
        var last4: UInt8?, last5: UInt8?
        public init() {}
        mutating func record(cycle: UInt64, port4: UInt8, port5: UInt8, crankDegrees: Double) {
            edges.append(Edge(cycle: cycle, port4: port4, port5: port5, crankDegrees: crankDegrees))
            last4 = port4
            last5 = port5
        }
    }

    /// Whether the firmware has started the watchdog.
    public var watchdogRunning: Bool { wdtCount != nil }

    // MARK: - Watchdog (manual 8.1)

    static let WDTREL: UInt8 = 0x86
    /// Watchdog resets so far; after one the program restarts at 0 with IP0.6 (WDTS) set.
    public private(set) var watchdogResets = 0
    private var stepIndex = 0
    private var wdtCount: Int?          // 15-bit counter; nil = not started
    private var wdtOsc = 0
    private var wdtArmedStep = -2

    /// Input clock divider: WDTP (PRSC.7) and WPSEL (WDTREL.7) — fOSC/12, 192, 24 or 384.
    private var wdtDivider: Int {
        switch (bit(Self.PRSC, 7), bit(Self.WDTREL, 7)) {
        case (false, false): 12
        case (false, true): 192
        case (true, false): 24
        case (true, true): 384
        }
    }

    private func reloadWatchdog() {
        wdtCount = Int(sfr(Self.WDTREL) & 0x7F) << 8
        wdtOsc = 0
    }

    private func tickWatchdog(_ cycles: Int) {
        // WDT clears itself in the second machine cycle after it was set.
        if wdtArmedStep == stepIndex - 1 { setBit(Self.IEN0, 6, false) }
        guard var count = wdtCount else { return }
        wdtOsc += cycles * 6
        let divider = wdtDivider
        while wdtOsc >= divider { wdtOsc -= divider; count += 1 }
        wdtCount = count
        if count >= 0x7FFC { watchdogReset() }
    }

    /// Internal reset: SFRs and peripherals as after power-on, RAM kept, WDTS set, WDTREL = 0,
    /// and the watchdog keeps running (8.1.5).
    private func watchdogReset() {
        watchdogResets += 1
        cpu.reset()
        cpu.sfr[Int(Self.PRSC)] = 0xD5
        cpu.sfr[Int(Self.S0RELL)] = 0xD9
        cpu.sfr[Int(Self.S0RELH)] = 0x03
        setBit(Self.IP0, 6, true)
        direction = [UInt8: UInt8](uniqueKeysWithValues: Self.ports.map { ($0, 0xFF) })
        savedLatch = [:]
        pdirSteps = 0
        timerPrescale = [0, 0]
        t2Prescale = 0
        ctOsc = 0; ct1Osc = 0; ctCount = nil; ct1Count = nil; ctReload = 0; ct1Reload = 0
        p4Compare = 0; p4Mode1Pins = 0xFF
        cmLatch = [Int](repeating: 0xFFFF, count: 8)
        cmLoadPending = [Bool](repeating: false, count: 8)
        txProgress = 0; txByte = nil; rxProgress = 0
        reloadWatchdog()
    }

    // MARK: - Interrupts

    /// Vector → (enable register, bit, priority group 0…5).
    private static let sources: [UInt16: (UInt8, Int, Int)] = [
        0x0003: (IEN0, 0, 0), 0x000B: (IEN0, 1, 1), 0x0013: (IEN0, 2, 2),
        0x001B: (IEN0, 3, 3), 0x0023: (IEN0, 4, 4), 0x002B: (IEN0, 5, 5),
        0x0043: (IEN1, 0, 0), 0x004B: (IEN1, 1, 1), 0x0053: (IEN1, 2, 2),
        0x005B: (IEN1, 3, 3), 0x0063: (IEN1, 4, 4), 0x006B: (IEN1, 5, 5),
        0x009B: (IEN2, 3, 3), // compare timer overflow (CTF)
        0x00DB: (IEN3, 3, 3), // compare timer 1 overflow (CT1F) — 0.5 ms time base
    ]

    private func isEnabled(_ vector: UInt16) -> Bool {
        guard let (reg, b, _) = Self.sources[vector] else { return false }
        return bit(reg, b)
    }

    private func updateInterruptRequests() {
        // The PDIR double-instruction sequence cannot be interrupted (manual 6.1.1.1).
        guard !pdirActive else { cpu.pendingInterrupts = []; return }
        var pending: Set<UInt16> = []
        if bit(Self.TCON, 1) { pending.insert(0x0003) }  // IE0
        if bit(Self.TCON, 5) { pending.insert(0x000B) }  // TF0
        if bit(Self.TCON, 3) { pending.insert(0x0013) }  // IE1
        if bit(Self.TCON, 7) { pending.insert(0x001B) }  // TF1
        if sfr(Self.S0CON) & 0x03 != 0 { pending.insert(0x0023) } // RI0/TI0
        let ircon = sfr(Self.IRCON0)
        if ircon & 0xC0 != 0 { pending.insert(0x002B) }  // TF2/EXF2
        if ircon & 0x01 != 0 { pending.insert(0x0043) }  // IADC
        for (i, vector) in [UInt16(0x004B), 0x0053, 0x005B, 0x0063, 0x006B].enumerated()
        where ircon & (0x02 << i) != 0 {
            pending.insert(vector)
        }
        if bit(Self.CTCON, 3) { pending.insert(0x009B) }   // CTF: compare timer overflow
        if bit(Self.CT1CON, 3) { pending.insert(0x00DB) }  // CT1F: compare timer 1 overflow
        cpu.pendingInterrupts = pending
        for (vector, (_, _, group)) in Self.sources {
            // Four levels from IP1.x (high bit) and IP0.x (low bit).
            cpu.interruptPriority[vector] = (bit(Self.IP1, group) ? 2 : 0) + (bit(Self.IP0, group) ? 1 : 0)
        }
    }

    /// Flags cleared by hardware when the CPU vectors to the routine.
    private func acknowledge(_ vector: UInt16) {
        switch vector {
        case 0x0003: if bit(Self.TCON, 0) { setBit(Self.TCON, 1, false) } // edge-triggered IE0
        case 0x000B: setBit(Self.TCON, 5, false)
        case 0x0013: if bit(Self.TCON, 2) { setBit(Self.TCON, 3, false) }
        case 0x001B: setBit(Self.TCON, 7, false)
        case 0x004B: setBit(Self.IRCON0, 1, false)
        case 0x0053: setBit(Self.IRCON0, 2, false)
        case 0x005B: setBit(Self.IRCON0, 3, false)
        case 0x0063: setBit(Self.IRCON0, 4, false)
        case 0x006B: setBit(Self.IRCON0, 5, false)
        case 0x009B: setBit(Self.CTCON, 3, false)
        case 0x00DB: setBit(Self.CT1CON, 3, false)
        default: break // RI/TI, IADC, TF2/EXF2 are cleared by software
        }
    }

    /// Requests external interrupt 0 (INT0) — e.g. a crank tooth edge.
    public func triggerExternal0() { setBit(Self.TCON, 1, true) }
    /// Requests external interrupt 2…6 (IEX2…IEX6).
    public func triggerExternal(_ n: Int) {
        precondition((2...6).contains(n))
        setBit(Self.IRCON0, n - 1, true)
    }

    // MARK: - Ports: direction registers (manual 6.1.1.1)

    static let P1: UInt8 = 0x90, P3: UInt8 = 0xB0
    /// Ports with a direction register DIRx mapped at the port address.
    static let ports: [UInt8] = [0x80, 0x90, 0xA0, 0xB0, 0xE8, 0xF8, 0xFA, 0xF9]
    /// DIRx: 1 = input (reset value FFh). Effective only in bidirectional mode (PMOD).
    private var direction = [UInt8: UInt8](uniqueKeysWithValues: ports.map { ($0, 0xFF) })
    private var savedLatch: [UInt8: UInt8] = [:]
    private var pdirSteps = 0
    private var pdirActive: Bool { pdirSteps > 0 }

    /// PMOD (SYSCON.6): bidirectional CMOS port structure.
    private var pmod: Bool { bit(Self.SYSCON, 6) }

    /// Setting PDIR (IP1.7) maps DIRx over the port SFRs for the next instruction.
    /// The direction values are swapped into the SFR slots so that plain and
    /// read-modify-write accesses of the CPU reach them unchanged.
    private func armPortDirection() {
        if !pdirActive {
            for p in Self.ports {
                savedLatch[p] = sfr(p)
                setSFR(p, direction[p]!)
            }
        }
        pdirSteps = 2 // this instruction and the next one
    }

    private func tickPortDirection() {
        guard pdirActive else { return }
        pdirSteps -= 1
        guard !pdirActive else { return }
        for p in Self.ports {
            direction[p] = sfr(p)
            setSFR(p, savedLatch[p]!)
        }
        setBit(Self.IP1, 7, false)
    }

    private func latch(of p: UInt8) -> UInt8 { pdirActive ? savedLatch[p]! : sfr(p) }

    /// Level the chip drives on a port: the latch plus compare outputs; in bidirectional
    /// mode an input pin (DIRx = 1) floats high (pull-up), as in the quasi-bidirectional mode.
    private func driven(_ p: UInt8) -> UInt8 {
        var v = latch(of: p)
        if p == Self.P4 { v = mergedPort4(v) }
        if pmod { v |= direction[p] ?? 0 }
        return v
    }

    // MARK: - Timers 0 and 1

    private var timerPrescale = [0, 0]

    private func tickTimers(_ cycles: Int) {
        let tmod = sfr(Self.TMOD), tcon = sfr(Self.TCON), prsc = sfr(Self.PRSC)
        for t in 0...1 {
            let run = tcon & (t == 0 ? 0x10 : 0x40) != 0
            guard run else { continue }
            let mode = Int(tmod >> (t * 4)) & 0x03
            let divider = 1 << Int((prsc >> (t * 2)) & 0x03)
            timerPrescale[t] += cycles
            let counts = timerPrescale[t] / divider
            timerPrescale[t] %= divider
            if counts > 0 { advance(timer: t, mode: mode, by: counts) }
        }
    }

    private func advance(timer t: Int, mode: Int, by counts: Int) {
        let tl = t == 0 ? Self.TL0 : Self.TL1, th = t == 0 ? Self.TH0 : Self.TH1
        let flagBit = t == 0 ? 5 : 7
        var overflowed = false
        switch mode {
        case 0: // 13-bit
            var v = Int(sfr(th)) << 5 | Int(sfr(tl) & 0x1F)
            v += counts
            if v > 0x1FFF { overflowed = true; v &= 0x1FFF }
            setSFR(th, UInt8(v >> 5)); setSFR(tl, (sfr(tl) & 0xE0) | UInt8(v & 0x1F))
        case 1: // 16-bit
            var v = Int(sfr(th)) << 8 | Int(sfr(tl))
            v += counts
            if v > 0xFFFF { overflowed = true; v &= 0xFFFF }
            setSFR(th, UInt8(v >> 8)); setSFR(tl, UInt8(v & 0xFF))
        case 2: // 8-bit auto-reload
            var v = Int(sfr(tl)) + counts
            while v > 0xFF { overflowed = true; v = v - 0x100 + Int(sfr(th)) }
            setSFR(tl, UInt8(v))
        default: // mode 3: TL0 8-bit timer; timer 1 stops
            guard t == 0 else { return }
            var v = Int(sfr(tl)) + counts
            if v > 0xFF { overflowed = true; v &= 0xFF }
            setSFR(tl, UInt8(v))
        }
        if overflowed { setBit(Self.TCON, flagBit, true) }
    }

    // MARK: - Timer 2 and capture/compare

    private var t2Prescale = 0

    /// 0 disabled, 1 capture on rising edge at P1.x, 2 compare, 3 capture on write.
    private func ccMode(_ channel: Int) -> Int { Int(sfr(Self.CCEN) >> (channel * 2)) & 0x03 }

    private var timer2: Int {
        get { Int(sfr(Self.TH2)) << 8 | Int(sfr(Self.TL2)) }
        set { setSFR(Self.TH2, UInt8(newValue >> 8 & 0xFF)); setSFR(Self.TL2, UInt8(newValue & 0xFF)) }
    }

    private func latch(_ channel: Int) {
        let low = Self.ccLow[channel]
        setSFR(low, UInt8(timer2 & 0xFF))
        setSFR(low + 1, UInt8(timer2 >> 8))
    }

    /// Request flag in IRCON0 for CRC/CC1/CC2/CC3: IEX3…IEX6.
    private func setCCFlag(_ channel: Int) { setBit(Self.IRCON0, 2 + channel, true) }

    /// Machine cycles per timer 2 count (manual table for T2P1/T2P0, T2PS1, T2PS).
    var timer2Divider: Int {
        let p = Int(sfr(Self.PRSC) >> 4) & 0x03
        let ps1 = bit(Self.CTCON, 7)
        let base = [1, 2, 4, 8][p] * (ps1 ? 4 : 1)
        return base * (bit(Self.T2CON, 7) ? 2 : 1)
    }

    private func tickTimer2(_ cycles: Int) {
        guard sfr(Self.T2CON) & 0x03 != 0 else { return } // T2I1/T2I0 = 00: stopped
        t2Prescale += cycles
        let divider = timer2Divider
        let counts = t2Prescale / divider
        t2Prescale %= divider
        guard counts > 0 else { return }
        let old = timer2
        var new = old + counts
        if new > 0xFFFF {
            setBit(Self.IRCON0, 6, true) // TF2
            new &= 0xFFFF
            if sfr(Self.T2CON) >> 3 & 0x03 == 2 { // reload mode 0 from CRC
                new = Int(sfr(0xCB)) << 8 | Int(sfr(0xCA))
            }
        }
        timer2 = new
        // Compare: flag when the count passes the register value.
        for channel in 0..<4 where ccMode(channel) == 2 {
            let low = Self.ccLow[channel]
            let target = Int(sfr(low + 1)) << 8 | Int(sfr(low))
            let passed = old < new ? (old < target && target <= new) : (target > old || target <= new)
            if passed { setCCFlag(channel) }
        }
        // CM0…CM7 assigned to timer 2 (compare mode 1): outputs and TOC latches.
        tickCompareOutputs(channels: (0...7).filter { !cmMode0($0) }, old: old, new: new, rolloverTo: nil)
        tickConcurrentCompare(old: old, new: new)
    }


    // MARK: - Compare timers (manual 6.3.2)

    /// Compare timers 0 and 1: free-running 16-bit counters on a prescaled fOSC clock
    /// (1/1…1/256). A write to the low reload byte (CTRELL/CT1RELL) starts the timer and
    /// reloads it; on rollover the count restarts from the reload value and the overflow
    /// flag CTF/CT1F is set. Compare timer 1 with CT1REL = FE0CH at fOSC/16 is the
    /// firmware's 0.5 ms time base (vector 0xDB increments IRAM 78h).
    private var ctOsc = 0, ct1Osc = 0            // fOSC-period accumulators
    private var ctCount: Int?, ct1Count: Int?     // nil = not started
    private var ctReload = 0, ct1Reload = 0       // CT1REL is a mapped SFR (RMAP = 1)

    /// RMAP (SYSCON.4) selects CT1REL over CTREL at DEH/DFH.
    private var rmap: Bool { bit(Self.SYSCON, 4) }

    /// Prescaler ratio in fOSC periods (manual 6.3.2.1 tables).
    private static func compareDivider(p: Bool, clk: Int) -> Int {
        let base = [1, 2, 4, 8, 16, 32, 64, 128][clk]
        return p ? base * 2 : base
    }

    private func tickCompareTimers(_ cycles: Int) {
        // The prescalers count only while a timer runs: a stopped timer must not bank
        // clocks and fire a spurious overflow right after it is started.
        if ctCount != nil { ctOsc += cycles * 6 }
        if ct1Count != nil { ct1Osc += cycles * 6 }
        if let count = ctCount {
            let divider = Self.compareDivider(p: sfr(Self.CTCON) & 0x40 != 0, clk: Int(sfr(Self.CTCON) & 0x07))
            let counts = ctOsc / divider
            if counts > 0 {
                ctOsc -= counts * divider
                var new = count + counts
                var reload: Int?
                if new > 0xFFFF {
                    setBit(Self.CTCON, 3, true) // CTF
                    new = Int(sfr(Self.CTRELH)) << 8 | Int(sfr(Self.CTREL))
                    reload = new
                }
                tickCompareOutputs(channels: (0...7).filter { cmMode0($0) }, old: count, new: new, rolloverTo: reload)
                ctCount = new
            }
        }
        if let count = ct1Count {
            let divider = Self.compareDivider(p: sfr(Self.CT1CON) & 0x40 != 0, clk: Int(sfr(Self.CT1CON) & 0x07))
            let counts = ct1Osc / divider
            if counts > 0 {
                ct1Osc -= counts * divider
                var new = count + counts
                if new > 0xFFFF {
                    setBit(Self.CT1CON, 3, true) // CT1F
                    new = ct1Reload
                }
                ct1Count = new
            }
        }
    }

    // MARK: - CM0…CM7 compare outputs (manual 6.3.4.4)

    /// Compare outputs drive port 4 pins (injector drivers P4.0–P4.3). Mode 1 (CMSEL.x=0,
    /// time base timer 2): a write to the port bit goes to a shadow latch and reaches the pin
    /// at the next match (manual 6.3.3.2, 6.3.4.4.2) — the firmware writes the next level,
    /// then the match time. Mode 0 (CMSEL.x=1, time base compare timer): pin high from match
    /// to timer overflow; the compare latch loads from the register at overflow (TOC); match
    /// sets ICMPx in IRCON1. (Before 27.10.2026 mode 1 set the pin on match and let a write
    /// of 0 show at once: injector pulses came out 5 µs long.)
    private var p4Compare: UInt8 = 0
    /// Pin levels of the compare-mode-1 channels (and the latch copy of the others).
    private var p4Mode1Pins: UInt8 = 0xFF
    /// Channels enabled in compare mode 1 (CMEN set, CMSEL clear).
    private var cmMode1Mask: UInt8 { sfr(Self.CMEN) & ~sfr(Self.CMSEL) }

    private func mergedPort4(_ latchLevel: UInt8) -> UInt8 {
        let m1 = cmMode1Mask
        return (latchLevel | p4Compare) & ~m1 | p4Mode1Pins & m1
    }
    private var cmLatch = [Int](repeating: 0xFFFF, count: 8)
    private var cmLoadPending = [Bool](repeating: false, count: 8)

    /// Current port 4 pin levels (latch OR compare-driven bits).
    public var port4Pins: UInt8 { mergedPort4(sfr(Self.P4)) }

    private func cmRegister(_ x: Int) -> Int {
        Int(sfr(Self.cmLow[x] + 1)) << 8 | Int(sfr(Self.cmLow[x]))
    }

    private func cmMode0(_ x: Int) -> Bool { sfr(Self.CMSEL) & 1 << x != 0 }

    /// Advances the compare outputs of the channels whose time base moved from
    /// `old` to `new`; `rolloverTo` is set when that time base wrapped to its reload.
    private func tickCompareOutputs(channels: [Int], old: Int, new: Int, rolloverTo reload: Int?) {
        for x in channels where sfr(Self.CMEN) & 1 << x != 0 {
            let match = cmLatch[x]
            let crossed = old <= new ? (match > old && match <= new) : (match > old || match <= new)
            if crossed {
                if cmMode0(x) {
                    p4Compare |= 1 << x
                    setBit(Self.IRCON1, x, true) // ICMPx
                } else {
                    // Shadow latch → pin.
                    p4Mode1Pins = p4Mode1Pins & ~(1 << x) | sfr(Self.P4) & (1 << x)
                }
            }
        }
        if reload != nil {
            // Compare timer rollover: mode 0 outputs go low, TOC latches load.
            for x in channels where cmMode0(x) {
                p4Compare &= ~(1 << x)
                if cmLoadPending[x] { cmLatch[x] = cmRegister(x); cmLoadPending[x] = false }
            }
        }
    }

    // MARK: - Concurrent compare on port 5 (COMSET/COMCLR, manual 6.3.4.5)

    /// COMSET/COMCLR compare against timer 2 and set/clear the masked port 5 latch bits at
    /// once (the match drives the latch's S/R inputs, manual 6.3.3.3). Match flags ICS/ICR live
    /// in CTCON.4/5 (vectors 0xA3/0xAB). The ignition outputs P5.1/P5.2 run on these below
    /// ≈2500 rpm in J5V05L19. (Before 27.10.2026 a set was kept beside the latch and a clear
    /// could not pull a pin low: no sparks at low speed.)
    public var port5Pins: UInt8 { sfr(0xF8) }

    private func tickConcurrentCompare(old: Int, new: Int) {
        func crossed(_ target: Int) -> Bool {
            old <= new ? (target > old && target <= new) : (target > old || target <= new)
        }
        let setMask = Int(sfr(0xA5)), clrMask = Int(sfr(0xA6))
        if crossed(Int(sfr(0xA2)) << 8 | Int(sfr(0xA1))) {
            setSFR(0xF8, sfr(0xF8) | UInt8(setMask))
            if setMask != 0 { setBit(Self.CTCON, 4, true) } // ICS
        }
        if crossed(Int(sfr(0xA4)) << 8 | Int(sfr(0xA3))) {
            setSFR(0xF8, sfr(0xF8) & ~UInt8(clrMask))
            if clrMask != 0 { setBit(Self.CTCON, 5, true) } // ICR
        }
    }
    /// Rising edge at P1.0…P1.3 (INT3…INT6): capture if enabled, and request the interrupt.
    public func externalEdge(channel: Int) {
        if ccMode(channel) == 1 { latch(channel) }
        setCCFlag(channel)
    }

    // MARK: - Crank wheel

    /// 60-2 crank wheel on P1.3/CC3. Set `crankRPM` to spin the engine; nil stops it.
    public var crankRPM: Double? {
        didSet {
            if crankRPM != nil, oldValue == nil { nextToothCycle = cpu.cycles }
        }
    }
    /// Machine cycles per second (16 MHz crystal, 6 clocks per cycle).
    public static let cyclesPerSecond = 16_000_000.0 / 6
    public private(set) var toothIndex = 0
    private var nextToothCycle: UInt64 = 0
    public static let teeth = 60, missingTeeth = 2

    /// Crank angle now, 0…360°: tooth k (0…57 real, 58/59 the gap) rises at k·6°, so 0° is the
    /// first tooth after the gap. Nil while the engine stands.
    public var crankDegrees: Double {
        guard let rpm = crankRPM, rpm > 0 else { return 0 }
        let toothCycles = 60 / rpm / Double(Self.teeth) * Self.cyclesPerSecond
        // `toothIndex` is the next tooth, due at `nextToothCycle`.
        let next = Double(toothIndex) - (Double(nextToothCycle) - Double(cpu.cycles)) / toothCycles
        return ((next * 6).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    private func tickCrank() {
        guard let rpm = crankRPM, rpm > 0 else { return }
        while cpu.cycles >= nextToothCycle {
            // Teeth 0…57 exist; 58 and 59 are the gap.
            if toothIndex < Self.teeth - Self.missingTeeth { externalEdge(channel: 3) }
            toothIndex = (toothIndex + 1) % Self.teeth
            let toothSeconds = 60 / rpm / Double(Self.teeth)
            nextToothCycle += UInt64(max(1, (toothSeconds * Self.cyclesPerSecond).rounded()))
        }
    }

    // MARK: - Serial port 0

    private var txProgress = 0
    private var txByte: UInt8?
    private var rxProgress = 0

    /// Machine cycles per transmitted/received byte (start + 8 data + stop).
    public var serialByteCycles: Int {
        let s0con = sfr(Self.S0CON)
        let mode = s0con >> 6
        let smod = sfr(Self.PCON) & 0x80 != 0
        let bitOsc: Double
        switch mode {
        case 0: bitOsc = 6
        case 2: bitOsc = smod ? 32 : 64
        default:
            if sfr(Self.ADCON0) & 0x80 != 0 { // BD: internal baud rate generator
                let reload = Int(sfr(Self.S0RELH) & 0x03) << 8 | Int(sfr(Self.S0RELL))
                let s0p = sfr(Self.PRSC) & 0x40 != 0 && reload != 0x3FF
                bitOsc = 32 * Double(1024 - reload) * (s0p ? 2 : 1) / (smod ? 2 : 1)
            } else { // timer 1 overflow, mode 2
                let divider = Double(1 << Int((sfr(Self.PRSC) >> 2) & 0x03))
                let perOverflow = Double(256 - Int(sfr(Self.TH1))) * divider * 6
                bitOsc = perOverflow * (smod ? 16 : 32)
            }
        }
        return max(1, Int((bitOsc * 10 / 6).rounded()))
    }

    private func startTransmit(_ v: UInt8) {
        txByte = v
        txProgress = 0
    }

    private func tickSerial(_ cycles: Int) {
        if let byte = txByte {
            // The byte time is re-derived from the live configuration on every tick:
            // the baud-rate divide chain runs continuously, so a momentary BD=0 window
            // around A/D conversions (the firmware clears ADCON0.7) must not stretch
            // an in-flight byte to the timer-1 rate.
            txProgress += cycles
            if txProgress >= serialByteCycles {
                serialOut.append(byte)
                txByte = nil
                setBit(Self.S0CON, 1, true) // TI0
                if echoesTransmit, bit(Self.S0CON, 4) {
                    setSFR(Self.S0BUF, byte)
                    setBit(Self.S0CON, 0, true) // RI0: own echo
                }
            }
        }
        // Receive: one byte per byte time while REN0 is set and RI0 is clear.
        guard bit(Self.S0CON, 4), !serialIn.isEmpty else { rxProgress = 0; return }
        rxProgress += cycles
        if rxProgress >= serialByteCycles, !bit(Self.S0CON, 0) {
            setSFR(Self.S0BUF, serialIn.removeFirst())
            setBit(Self.S0CON, 0, true) // RI0
            rxProgress = 0
        }
    }

    /// Puts a byte on TxD at once (the bootstrap loader model answers without the UART).
    func emitSerial(_ byte: UInt8) { serialOut.append(byte) }

    public func takeSerialOutput() -> [UInt8] {
        defer { serialOut.removeAll() }
        return serialOut
    }

    // MARK: - A/D converter

    private func convertADC() {
        let channel = Int(sfr(Self.ADCON1) & 0x0F)
        let value = min(adcInputs[channel], 1023)
        setSFR(Self.ADDATH, UInt8(value >> 2))
        setSFR(Self.ADDATL, UInt8(value & 0x03) << 6)
        setBit(Self.ADCON0, 4, false) // BSY
        setBit(Self.IRCON0, 0, true)  // IADC
    }

    // MARK: - MDU

    let mdu = MDU()
}

/// Multiplication/division unit (C509-L manual, table 6-10).
final class MDU {
    var md = [UInt8](repeating: 0, count: 6)
    var arcon: UInt8 = 0
    private var writes: [Int] = []

    func read(_ i: Int) -> UInt8 { md[i] }

    func write(_ i: Int, _ v: UInt8) {
        if i == 0 { writes = [] } // a write to MD0 starts a new operation
        md[i] = v
        writes.append(i)
        guard i == 5 else { return }
        if writes.contains(2) || writes.contains(3) {
            divide32()
        } else if let m1 = writes.firstIndex(of: 1), let m4 = writes.firstIndex(of: 4), m4 < m1 {
            multiply()
        } else {
            divide16()
        }
    }

    private func u16(_ lo: Int) -> UInt32 { UInt32(md[lo]) | UInt32(md[lo + 1]) << 8 }

    private func setOverflow(_ v: Bool) { arcon = v ? arcon | 0x40 : arcon & ~0x40 }

    private func multiply() {
        let p = UInt32(md[0]) | UInt32(md[1]) << 8
        let q = UInt32(md[4]) | UInt32(md[5]) << 8
        let r = p * q
        for k in 0..<4 { md[k] = UInt8((r >> (8 * k)) & 0xFF) }
        setOverflow(r > 0xFFFF)
    }

    private func divide16() {
        let n = u16(0), d = u16(4)
        guard d != 0 else { setOverflow(true); return }
        let q = n / d, rem = n % d
        md[0] = UInt8(q & 0xFF); md[1] = UInt8(q >> 8)
        md[4] = UInt8(rem & 0xFF); md[5] = UInt8(rem >> 8)
        setOverflow(false)
    }

    private func divide32() {
        let n = UInt32(md[0]) | UInt32(md[1]) << 8 | UInt32(md[2]) << 16 | UInt32(md[3]) << 24
        let d = u16(4)
        guard d != 0 else { setOverflow(true); return }
        let q = n / d, rem = n % d
        for k in 0..<4 { md[k] = UInt8((q >> (8 * k)) & 0xFF) }
        md[4] = UInt8(rem & 0xFF); md[5] = UInt8(rem >> 8)
        setOverflow(false)
    }

    /// ARCON write: SC = 0 normalizes MD0–MD3, otherwise shifts by SC (SLR = 1 → right).
    func shift(arcon v: UInt8) {
        var x = UInt32(md[0]) | UInt32(md[1]) << 8 | UInt32(md[2]) << 16 | UInt32(md[3]) << 24
        let count = Int(v & 0x1F)
        if count == 0 {
            var n = 0
            if x != 0 { while x & 0x8000_0000 == 0 { x <<= 1; n += 1 } }
            arcon = (v & 0xE0) | UInt8(n)
        } else {
            x = v & 0x20 != 0 ? x >> count : x << count
            arcon = v
        }
        for k in 0..<4 { md[k] = UInt8((x >> (8 * k)) & 0xFF) }
    }
}
