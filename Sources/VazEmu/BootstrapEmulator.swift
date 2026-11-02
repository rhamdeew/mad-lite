import VazCore

/// A Январь 5.1 powered up with PRGEN high (pin 47 at +12 V): the C509-L runs its boot
/// ROM Bootstrap Loader instead of the firmware (user manual 1997-11, chapter 10).
///
/// The boot ROM itself is Infineon code we do not have, so phases I–III are modelled in
/// Swift while the CPU idles in the boot ROM area; serial bytes are answered at once.
/// Mode 1 switches to the programming mode the way the loader does (SWAP with PRGEN1):
/// code memory = boot ROM 0000–01FF, external SRAM 0200–F3FF (none on the board, FFh),
/// XRAM F400–FFFF; data memory (MOVX) = the external flash, writable through its
/// command interface. Serial port 0 is left in mode 3 (8N2) at `agentReload`.
public final class BootstrapBoard {
    public let board: C509Board
    public let flash: Flash29F010

    public enum Phase: Equatable {
        case sync, header, load(next: UInt16, blockLength: Int), running
    }
    public private(set) var phase: Phase
    /// Info block sector phase I started from instead of the serial loader, if any.
    public private(set) var startedFromInfoBlock: UInt16?
    /// S0REL the model leaves after synchronization (≈57600 baud at 16 MHz).
    public static let agentReload = 0x3F7
    private var pending: [UInt8] = []

    public init(image: [UInt8]) {
        flash = Flash29F010(image: image)
        board = C509Board(rom: Self.bootstrapCode(flash: Array(flash.memory[0..<0x10000])))
        if let sector = BootstrapLoader.lockingInfoBlock(in: Array(flash.memory[0..<0x10000])) {
            // Phase I found custom software: jump to its start address.
            let b = Int(sector)
            board.cpu.pc = UInt16(flash.memory[b + 4]) << 8 | UInt16(flash.memory[b + 5])
            startedFromInfoBlock = sector
            phase = .running
        } else {
            phase = .sync
        }
    }

    /// Code memory in bootstrap mode: boot ROM (here an idle `sjmp $`) over 0000–01FF,
    /// the flash above it.
    static func bootstrapCode(flash: [UInt8]) -> [UInt8] {
        var code = flash
        for i in 0..<0x200 { code[i] = 0 }
        code[0] = 0x80; code[1] = 0xFE
        return code
    }

    public func run(machineCycles: Int) throws {
        let target = board.cpu.cycles + UInt64(machineCycles)
        while board.cpu.cycles < target {
            instruction += 1
            try board.step()
            if phase != .running { serviceLoader() }
            if chipMode == .programming { finishUnlock() }
        }
    }

    // MARK: - Chip mode (manual 3.4.6, 3.4.7.1)

    public enum ChipMode: Equatable, Sendable { case bootstrap, programming, normal }
    public private(set) var chipMode = ChipMode.bootstrap
    static let SYSCON1 = 0xB2
    private var instruction = 0
    private var eswcAt: Int?, switchAt: Int?, restoreAt: Int?

    /// ESWC must come with the mode bits, SWC in the very next instruction; both read as 0.
    /// Mode bits changed without the sequence return to their old value two instructions later.
    private func writeSYSCON1(_ v: UInt8) {
        let cpu = board.cpu
        if v & 0x80 != 0 {
            eswcAt = instruction
        } else if v & 0x40 != 0, eswcAt == instruction - 1 {
            switchAt = instruction + 1 // the next instruction (LJMP) still runs from the old memory
        }
        if v & 0x05 != 0x05, restoreAt == nil { restoreAt = instruction + 2 }
        cpu.sfr[Self.SYSCON1] = v & 0x3F
    }

    private func finishUnlock() {
        let cpu = board.cpu
        if let at = switchAt {
            guard instruction >= at else { return }
            switchAt = nil
            restoreAt = nil
            if cpu.sfr[Self.SYSCON1] & 0x05 == 0 { enterNormalMode() }
        } else if let at = restoreAt, instruction >= at {
            restoreAt = nil
            cpu.sfr[Self.SYSCON1] |= 0x05
        }
    }

    private func enterNormalMode() {
        let cpu = board.cpu
        cpu.code = Array(flash.memory[0..<0x10000])
        cpu.xramRead = nil
        cpu.xramWrite = nil
        board.echoesTransmit = false
        chipMode = .normal
    }

    /// External RESET with pin 47 high: back to the loader, whatever was running.
    public func externalReset() {
        let cpu = board.cpu
        cpu.code = Self.bootstrapCode(flash: Array(flash.memory[0..<0x10000]))
        cpu.xramRead = nil
        cpu.xramWrite = nil
        for sfr in [0xA8, 0xB8, 0x9A] { cpu.sfr[sfr] = 0 } // interrupts off, as after reset
        cpu.pc = 0
        board.serialIn.removeAll()
        board.echoesTransmit = false
        pending.removeAll()
        chipMode = .bootstrap
        phase = .sync
    }

    // MARK: - Loader model

    private func serviceLoader() {
        while phase != .running, !board.serialIn.isEmpty {
            let byte = board.serialIn.removeFirst()
            switch phase {
            case .sync:
                if byte == 0x00 { board.emitSerial(BootstrapLoader.acknowledge); phase = .header }
            case .header:
                pending.append(byte)
                if pending.count == 8 { handleHeader(take()) }
            case .load(let next, let length):
                pending.append(byte)
                if pending.count == length { handleData(take(), next: next, length: length) }
            case .running:
                break
            }
        }
    }

    private func take() -> [UInt8] { defer { pending.removeAll() }; return pending }

    private func valid(_ block: [UInt8]) -> Bool {
        guard BootstrapLoader.xor(block.dropLast()) == block.last else {
            board.emitSerial(BootstrapLoader.checksumError)
            return false
        }
        return true
    }

    private func handleHeader(_ b: [UInt8]) {
        guard valid(b) else { return }
        guard b[0] == BootstrapLoader.BlockType.header.rawValue, let mode = BootstrapLoader.Mode(rawValue: b[1]) else {
            board.emitSerial(BootstrapLoader.blockError)
            return
        }
        let address = UInt16(b[2]) << 8 | UInt16(b[3])
        board.emitSerial(BootstrapLoader.acknowledge)
        switch mode {
        case .loadXRAM:
            phase = .load(next: address, blockLength: Int(b[6]))
        case .runXRAM:
            enterProgrammingMode(start: address)
        case .checkFlash:
            let length = Int(b[4]) << 8 | Int(b[5])
            let start = Int(address)
            let (c1, c2) = BootstrapLoader.flashChecksum((start..<start + length).map { flash.read(UInt16(truncatingIfNeeded: $0)) })
            // Manual 10.4.2.3: the reference bytes sit at start + length + 1 and + 2.
            let ok = flash.read(UInt16(truncatingIfNeeded: start + length + 1)) == c1
                && flash.read(UInt16(truncatingIfNeeded: start + length + 2)) == c2
            board.emitSerial(ok ? BootstrapLoader.acknowledge : BootstrapLoader.checksumError)
        case .runFlash:
            board.cpu.pc = address
            phase = .running
        }
    }

    private func handleData(_ b: [UInt8], next: UInt16, length: Int) {
        guard valid(b) else { return }
        switch BootstrapLoader.BlockType(rawValue: b[0]) {
        case .data:
            let data = b[1..<length - 1]
            writeXRAM(data, at: next)
            board.emitSerial(BootstrapLoader.acknowledge)
            phase = .load(next: next &+ UInt16(data.count), blockLength: length)
        case .endOfTransmission:
            let n = min(Int(b[1]), length - 3)
            writeXRAM(b[2..<2 + n], at: next)
            board.emitSerial(BootstrapLoader.acknowledge)
            phase = .header
        default:
            board.emitSerial(BootstrapLoader.blockError)
        }
    }

    private func writeXRAM(_ data: ArraySlice<UInt8>, at address: UInt16) {
        for (i, v) in data.enumerated() { board.cpu.xram[Int(address &+ UInt16(i))] = v }
    }

    private func enterProgrammingMode(start: UInt16) {
        let cpu = board.cpu
        var code = [UInt8](repeating: 0xFF, count: 0x10000)
        code[0] = 0x80; code[1] = 0xFE
        for a in 0xF400...0xFFFF { code[a] = cpu.xram[a] }
        cpu.code = code
        // A16 = P6.0 (schematic). The model keeps the image the ECU starts from — the half
        // selected after reset, P6.0 = 1 — at memory 0…FFFF, the other half at 10000…1FFFF.
        // Which physical half that is on the real chip is not known.
        cpu.xramRead = { [flash, unowned cpu] a in flash.bank = cpu.sfr[0xFA] & 1 == 1 ? 0 : 1; return flash.read(a) }
        cpu.xramWrite = { [flash, unowned cpu] a, v in flash.bank = cpu.sfr[0xFA] & 1 == 1 ? 0 : 1; flash.write(a, v) }
        // Serial port 0 as the loader leaves it: mode 3, receiver on, baud rate generator,
        // and TI0 still set after the last acknowledge. Assumption from the live spare ECU
        // (2026-10-31): an agent whose putc waited for TI *after* writing S0BUF lost the
        // first byte of its second reply (flash ID came back as one byte).
        cpu.sfr[0x98] = 0xD2
        cpu.sfr[0xFA] = 0xFF // P6 reset value (manual); P6.0 = A16 → the half the ECU starts from
        board.echoesTransmit = true
        cpu.sfr[0xD8] |= 0x80
        cpu.sfr[0xAA] = UInt8(Self.agentReload & 0xFF)
        cpu.sfr[0xBA] = UInt8(Self.agentReload >> 8)
        cpu.sfr[Self.SYSCON1] = 0x07 // PRGEN1, PRGEN0 (pin 47 high), SWAP
        chipMode = .programming
        if !hooksSYSCON1 {
            hooksSYSCON1 = true
            let boardWrite = cpu.sfrWrite
            cpu.sfrWrite = { [unowned self] a, v in
                if Int(a) == Self.SYSCON1, self.chipMode == .programming { self.writeSYSCON1(v) } else { boardWrite?(a, v) }
            }
        }
        cpu.pc = start
        phase = .running
    }
    private var hooksSYSCON1 = false
}

/// K-line transport to a `BootstrapBoard`, so `BootstrapClient` runs against the model.
public actor BootstrapEmulatorTransport: KLineTransport {
    public let machine: BootstrapBoard
    private var received: [UInt8] = []
    public nonisolated let echoesWrites = false

    public init(image: [UInt8]) {
        machine = BootstrapBoard(image: image)
    }

    public func run(ms: Int) throws {
        for _ in 0..<ms {
            try machine.run(machineCycles: EmulatorTransport.cyclesPerMs)
            received += machine.board.takeSerialOutput()
        }
    }

    /// Bytes programmed and sectors erased in the flash model so far.
    public var flashWrites: (programmed: Int, erased: [Int]) { (machine.flash.programmedBytes, machine.flash.erasedSectors) }

    /// Direct access to the flash model (tests: the other bank, fault injection).
    public func withFlash<T>(_ body: (Flash29F010) -> T) -> T { body(machine.flash) }

    /// The flash's current 64 KB window (for tests).
    public var flashWindow: [UInt8] { Array(machine.flash.memory[0..<0x10000]) }

    /// Sets/reads the modeled serial EEPROM (for tests).
    public func setEEPROM(_ bytes: [UInt8]) { machine.board.eeprom.memory = bytes }
    public func getEEPROM() -> [UInt8] { machine.board.eeprom.memory }

    public var chipMode: BootstrapBoard.ChipMode { machine.chipMode }

    /// External RESET with pin 47 high (for tests: a supply dip).
    public func externalReset() { machine.externalReset() }

    /// Sets a 10-bit A/D input, for the firmware started from the loader.
    public func setADC(channel: Int, value: UInt16) { machine.board.adcInputs[channel] = value }

    /// Same pulse as `EmulatorTransport`; the loader itself ignores it.
    public func fastInit() async throws {
        machine.board.portInputs[EmulatorTransport.port3] = 0xFE
        try run(ms: 25)
        machine.board.portInputs[EmulatorTransport.port3] = 0xFF
        try run(ms: 25)
    }

    public func write(_ bytes: [UInt8]) async throws {
        machine.board.serialIn += bytes
    }

    public func read(count: Int, timeout: Duration) async throws -> [UInt8] {
        let limit = Int(timeout.components.seconds) * 1000 + Int(timeout.components.attoseconds / 1_000_000_000_000_000)
        var elapsed = 0
        while received.count < count {
            guard elapsed < max(limit, 1) else { throw KLineError.timeout(expected: count, received: received.count) }
            try run(ms: 1)
            elapsed += 1
        }
        defer { received.removeFirst(count) }
        return Array(received.prefix(count))
    }

    public func flush() async throws { received.removeAll() }
}
