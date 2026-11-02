import Testing
@testable import VazEmu

/// C509 peripherals: compare timers 0/1, CM0…CM7 / COMSET/COMCLR outputs, port
/// direction registers and the serial EEPROM.
@Suite struct C509BoardTests {
    /// Compare timer 1 as the firmware sets it up: CT1CON = 43 (fOSC/16), CT1REL = FE0C
    /// (mapped via RMAP) → overflow every 500 counts = 500 µs, interrupt at vector 0xDB.
    @Test func compareTimer1TicksAt2kHz() throws {
        var rom = [UInt8](repeating: 0x00, count: 0x10000)
        rom[0xDB] = 0x32 // RETI at the CT1F vector
        let board = C509Board(rom: rom)
        var ticks = 0
        let base = board.cpu.onInterruptEntry
        board.cpu.onInterruptEntry = { if $0 == 0x00DB { ticks += 1 }; base?($0) }
        board.cpu.writeDirect(0xB1, 0x10) // SYSCON: RMAP = 1 → CT1REL at DEH/DFH
        board.cpu.writeDirect(0xDF, 0xFE) // high byte first
        board.cpu.writeDirect(0xDE, 0x0C) // low byte starts the timer
        board.cpu.writeDirect(0xB1, 0x00) // RMAP = 0
        board.cpu.writeDirect(0xBC, 0x43) // CT1CON: CT1P = 1, CLK = 011 → fOSC/16
        board.cpu.writeDirect(0x9A, 0x00) // IEN2 off: no unrelated interrupts
        board.cpu.writeDirect(0xBE, 0x08) // IEN3: ECT1
        board.cpu.writeDirect(0xA8, 0x80) // IEN0: EA
        try board.run(machineCycles: 3 * 2667) // 3 ms
        #expect(ticks == 6)   // one per 500 µs
        #expect(board.cpu.sfr[0xBC] & 0x08 == 0) // CT1F cleared on entry
    }

    /// CM0 in compare mode 1 (timer 2): a port write goes to the shadow latch and reaches the
    /// pin only at the next match (manual 6.3.3.2) — that is how the injector pulse is timed.
    @Test func cm0DrivesPort4Pin() throws {
        let board = C509Board(rom: [UInt8](repeating: 0x00, count: 0x10000))
        board.cpu.writeDirect(0xF6, 0x01) // CMEN: CM0 compare on
        board.cpu.writeDirect(0xF7, 0x00) // CMSEL: CM0 → timer 2, mode 1
        board.cpu.writeDirect(0xE8, 0xFE) // shadow latch: next level 0
        #expect(board.port4Pins & 0x01 == 0x01) // not yet on the pin
        board.cpu.writeDirect(0xD3, 0x20) // CM0 high
        board.cpu.writeDirect(0xD2, 0x00) // CM0 low: latch loads 0x2000
        board.cpu.writeDirect(0xC8, 0x01) // T2CON: timer 2 running
        try board.run(machineCycles: 40_000)
        #expect(board.port4Pins & 0x01 == 0x00) // the match moved 0 to the pin
        board.cpu.writeDirect(0xE8, 0xFF) // next level 1, again only at a match
        #expect(board.port4Pins & 0x01 == 0x00)
        try board.run(machineCycles: 300_000) // timer 2 wraps and matches 0x2000 again
        #expect(board.port4Pins & 0x01 == 0x01)
    }

    /// Bidirectional ports (PMOD): PDIR maps DIRx over the port SFR for one instruction.
    /// With DIR1.5 = 1 the pin floats high (pull-up) although the latch holds 0.
    @Test func portDirectionRegisterViaPDIR() throws {
        // ORL IP1,#80; ORL P1,#20 (→ DIR1); MOV C,P1.5; ANL P1,#DF (latch)
        var rom = [UInt8](repeating: 0x00, count: 0x10000)
        rom.replaceSubrange(0..<9, with: [0x43, 0xB9, 0x80, 0x43, 0x90, 0x20, 0xA2, 0x95, 0x00])
        let board = C509Board(rom: rom)
        board.cpu.writeDirect(0xB1, 0x40) // SYSCON: PMOD = 1
        board.cpu.writeDirect(0x90, 0x00) // P1 latch all low
        for _ in 0..<2 { try board.step() }
        #expect(board.cpu.sfr[0x90] == 0x00) // the latch is untouched
        #expect(board.cpu.sfr[0xB9] & 0x80 == 0) // PDIR cleared by hardware
        try board.step()
        #expect(board.cpu.carry) // P1.5 is an input now and reads high
    }

    /// 24Cxx EEPROM on the bit-banged bus: page write, then random read (dummy write
    /// of the address, repeated START, read with ACK, last byte with NACK).
    @Test func eepromWriteAndRandomRead() {
        let e = I2CEEPROM()
        var scl = true, sda = true
        func set(_ c: Bool, _ d: Bool) { scl = c; sda = d; e.update(scl: c, sda: d) }
        func start() { set(true, true); set(true, false); set(false, false) }
        func stop() { set(false, false); set(true, false); set(true, true) }
        func send(_ b: UInt8) -> Bool {
            for i in 0..<8 { set(false, b & 0x80 >> i != 0); set(true, sda); set(false, sda) }
            set(false, true); set(true, true)
            let ack = !e.sdaOut
            set(false, true)
            return ack
        }
        func receive(ack: Bool) -> UInt8 {
            var b: UInt8 = 0
            for _ in 0..<8 { set(false, true); set(true, true); b = b << 1 | (e.sdaOut ? 1 : 0); set(false, true) }
            set(false, !ack); set(true, !ack); set(false, true)
            return b
        }
        start()
        #expect(send(0xA2) && send(0x10) && send(0x12) && send(0x34)) // block 1, address 10h
        stop()
        #expect(e.memory[0x110] == 0x12 && e.memory[0x111] == 0x34)
        start(); _ = send(0xA2); _ = send(0x10)
        start()
        #expect(send(0xA3))
        #expect(receive(ack: true) == 0x12)
        #expect(receive(ack: false) == 0x34)
        stop()
        #expect(e.memory[0x112] == 0xFF) // blank part
        #expect(!send(0xA0)) // after STOP the part ignores the bus until the next START
    }
}
