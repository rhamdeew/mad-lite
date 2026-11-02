import Foundation
import Testing
@testable import VazEmu

func cpu(_ program: [UInt8]) -> CPU8051 { CPU8051(code: program) }

func run(_ c: CPU8051, steps: Int) throws {
    for _ in 0..<steps { try c.step() }
}

@Suite struct CPU8051Tests {
    @Test func addSetsCarryAuxAndOverflow() throws {
        let c = cpu([0x74, 0x7F, 0x24, 0x01, 0x24, 0x80]) // MOV A,#7F; ADD A,#1; ADD A,#80
        try run(c, steps: 2)
        #expect(c.a == 0x80 && !c.carry)
        #expect(c.readDirect(0xD0) & 0x44 == 0x44) // AC and OV
        try run(c, steps: 1)
        #expect(c.a == 0x00 && c.carry)
    }

    @Test func subbWithBorrow() throws {
        let c = cpu([0xD3, 0x74, 0x10, 0x94, 0x0F]) // SETB C; MOV A,#10; SUBB A,#0F
        try run(c, steps: 3)
        #expect(c.a == 0x00 && !c.carry)
    }

    @Test func parityFlagFollowsAccumulator() throws {
        let c = cpu([0x74, 0x07])
        try run(c, steps: 1)
        #expect(c.readDirect(0xD0) & 1 == 1) // three bits set
    }

    @Test func registerBanksFollowPSW() throws {
        // MOV R0,#11; MOV PSW,#08; MOV R0,#22
        let c = cpu([0x78, 0x11, 0x75, 0xD0, 0x08, 0x78, 0x22])
        try run(c, steps: 3)
        #expect(c.iram[0] == 0x11 && c.iram[8] == 0x22)
    }

    @Test func eightDataPointers() throws {
        // MOV DPTR,#1234; MOV 92h,#7; MOV DPTR,#ABCD; MOV 92h,#0; MOVX @DPTR,A
        let c = cpu([0x90, 0x12, 0x34, 0x75, 0x92, 0x07, 0x90, 0xAB, 0xCD, 0x75, 0x92, 0x00, 0xF0])
        c.a = 0x5A
        try run(c, steps: 5)
        #expect(c.dptr == 0x1234)
        #expect(c.xram[0x1234] == 0x5A)
        c.writeDirect(0x92, 7)
        #expect(c.dptr == 0xABCD)
    }

    @Test func callAndReturn() throws {
        // LCALL 0006; SJMP $; NOP; MOV A,#42; RET
        let c = cpu([0x12, 0x00, 0x06, 0x80, 0xFE, 0x00, 0x74, 0x42, 0x22])
        try run(c, steps: 3)
        #expect(c.a == 0x42 && c.pc == 0x0003 && c.sp == 0x07)
    }

    @Test func djnzLoopsAndCountsCycles() throws {
        let c = cpu([0x7A, 0x05, 0xDA, 0xFE]) // MOV R2,#5; DJNZ R2,$
        try run(c, steps: 6)
        #expect(c.iram[2] == 0 && c.pc == 4)
        #expect(c.cycles == 1 + 5 * 2)
    }

    @Test func cjneSetsCarryWhenLess() throws {
        let c = cpu([0x74, 0x10, 0xB4, 0x20, 0x00]) // MOV A,#10; CJNE A,#20,+0
        try run(c, steps: 2)
        #expect(c.carry)
    }

    @Test func bitAddressing() throws {
        // SETB 20h.3 (bit 03); SETB ACC.7 (bit E7); JB 03,+1
        let c = cpu([0xD2, 0x03, 0xD2, 0xE7, 0x20, 0x03, 0x01, 0x00, 0x00])
        try run(c, steps: 3)
        #expect(c.iram[0x20] == 0x08 && c.a == 0x80 && c.pc == 0x0008)
    }

    /// ORL/ANL C,bit always consume their bit operand, whatever the carry: J5V05L19 at
    /// 0x276D runs `orl c, 22h.6` with C = 1, and the operand byte 16h executed as
    /// `dec @R0` used to corrupt the EX0 ring-buffer pointer (IRAM BEh).
    @Test func carryLogicAlwaysFetchesBitOperand() throws {
        // SETB C; ORL C,16h; CLR C; ANL C,16h; SETB C; ORL C,/16h; CLR C; ANL C,/16h
        let c = cpu([0xD3, 0x72, 0x16, 0xC3, 0x82, 0x16, 0xD3, 0xA0, 0x16, 0xC3, 0xB0, 0x16])
        try run(c, steps: 8)
        #expect(c.pc == 12)
        #expect(c.cycles == 4 * 1 + 4 * 2)
    }

    @Test func mulAndDiv() throws {
        let c = cpu([0x74, 0x10, 0x75, 0xF0, 0x20, 0xA4, 0x74, 0x64, 0x75, 0xF0, 0x07, 0x84])
        try run(c, steps: 3)
        #expect(c.a == 0x00 && c.readDirect(0xF0) == 0x02) // 0x10·0x20 = 0x200
        try run(c, steps: 3)
        #expect(c.a == 14 && c.readDirect(0xF0) == 2) // 100 / 7
    }

    @Test func interruptEntryAndReti() throws {
        var prog = [UInt8](repeating: 0, count: 0x30)
        prog[0x00] = 0x80; prog[0x01] = 0xFE // SJMP $
        prog[0x23] = 0x32                     // RETI at serial vector
        let c = cpu(prog)
        c.writeDirect(0xA8, 0x90) // EA + ES
        c.pendingInterrupts.insert(0x23)
        try c.step()
        #expect(c.pc == 0x23)
        try c.step()
        #expect(c.pc == 0x00)
    }

    @Test func illegalOpcodeThrows() {
        let c = cpu([0xA5])
        #expect(throws: CPU8051.Fault.illegalOpcode(0xA5, at: 0)) { try c.step() }
    }
}
