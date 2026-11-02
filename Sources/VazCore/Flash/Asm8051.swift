/// A tiny 8051 assembler for the flash agents loaded through the C509 bootstrap loader:
/// only the instructions the agents use, labels with relative/absolute fix-ups.
public struct Asm8051 {
    public let origin: UInt16
    public private(set) var bytes: [UInt8] = []
    private var labels: [String: UInt16] = [:]
    private var fixups: [(at: Int, label: String, relative: Bool)] = []

    public init(origin: UInt16) { self.origin = origin }

    public var here: UInt16 { origin &+ UInt16(bytes.count) }

    public mutating func label(_ name: String) {
        precondition(labels[name] == nil, "label \(name) defined twice")
        labels[name] = here
    }

    /// Resolves the fix-ups and returns the code.
    public func assemble() -> [UInt8] {
        var out = bytes
        for f in fixups {
            guard let target = labels[f.label] else { preconditionFailure("undefined label \(f.label)") }
            if f.relative {
                let next = Int(origin) + f.at + 1
                let offset = Int(target) - next
                precondition((-128...127).contains(offset), "branch to \(f.label) out of range")
                out[f.at] = UInt8(bitPattern: Int8(offset))
            } else {
                out[f.at] = UInt8(target >> 8)
                out[f.at + 1] = UInt8(target & 0xFF)
            }
        }
        return out
    }

    private mutating func emit(_ b: UInt8...) { bytes += b }
    private mutating func rel(_ label: String) { fixups.append((bytes.count, label, true)); bytes.append(0) }
    private mutating func abs(_ label: String) { fixups.append((bytes.count, label, false)); bytes += [0, 0] }

    // Data transfer
    public mutating func movA(_ imm: UInt8) { emit(0x74, imm) }
    public mutating func movAdirect(_ dir: UInt8) { emit(0xE5, dir) }
    public mutating func movDirectA(_ dir: UInt8) { emit(0xF5, dir) }
    public mutating func movDirect(_ dir: UInt8, _ imm: UInt8) { emit(0x75, dir, imm) }
    public mutating func movAR(_ n: UInt8) { emit(0xE8 + n) }
    public mutating func movRA(_ n: UInt8) { emit(0xF8 + n) }
    public mutating func movR(_ n: UInt8, _ imm: UInt8) { emit(0x78 + n, imm) }
    public mutating func movDirectR(_ dir: UInt8, _ n: UInt8) { emit(0x88 + n, dir) }
    public mutating func movDPTR(_ v: UInt16) { emit(0x90, UInt8(v >> 8), UInt8(v & 0xFF)) }
    public mutating func movxAatDPTR() { emit(0xE0) }
    public mutating func movxAtDPTRa() { emit(0xF0) }
    public mutating func incDPTR() { emit(0xA3) }

    // Arithmetic / logic
    public mutating func xrlAR(_ n: UInt8) { emit(0x68 + n) }
    public mutating func orlAR(_ n: UInt8) { emit(0x48 + n) }
    public mutating func incR(_ n: UInt8) { emit(0x08 + n) }
    public mutating func decR(_ n: UInt8) { emit(0x18 + n) }
    public mutating func decA() { emit(0x14) }
    public mutating func cplA() { emit(0xF4) }
    public mutating func anlDirect(_ dir: UInt8, _ imm: UInt8) { emit(0x53, dir, imm) }
    public mutating func orlDirect(_ dir: UInt8, _ imm: UInt8) { emit(0x43, dir, imm) }
    public mutating func anlA(_ imm: UInt8) { emit(0x54, imm) }
    public mutating func orlA(_ imm: UInt8) { emit(0x44, imm) }
    public mutating func xrlAdirect(_ dir: UInt8) { emit(0x65, dir) }
    public mutating func clrA() { emit(0xE4) }
    public mutating func push(_ dir: UInt8) { emit(0xC0, dir) }
    public mutating func pop(_ dir: UInt8) { emit(0xD0, dir) }

    // Bits
    public mutating func clr(bit: UInt8) { emit(0xC2, bit) }
    public mutating func setb(bit: UInt8) { emit(0xD2, bit) }
    public mutating func movCbit(_ bit: UInt8) { emit(0xA2, bit) }   // MOV C, bit
    public mutating func movBitC(_ bit: UInt8) { emit(0x92, bit) }   // MOV bit, C
    public mutating func clrC() { emit(0xC3) }
    public mutating func setbC() { emit(0xD3) }
    public mutating func rlcA() { emit(0x33) }                       // rotate A left through carry
    public mutating func nop() { emit(0x00) }
    public mutating func jnb(bit: UInt8, _ label: String) { emit(0x30, bit); rel(label) }
    public mutating func jb(bit: UInt8, _ label: String) { emit(0x20, bit); rel(label) }
    public mutating func jc(_ label: String) { emit(0x40); rel(label) }
    public mutating func jnc(_ label: String) { emit(0x50); rel(label) }

    // Branches
    public mutating func sjmp(_ label: String) { emit(0x80); rel(label) }
    public mutating func ljmp(_ label: String) { emit(0x02); abs(label) }
    public mutating func ljmp(address: UInt16) { emit(0x02, UInt8(address >> 8), UInt8(address & 0xFF)) }
    public mutating func lcall(_ label: String) { emit(0x12); abs(label) }
    public mutating func ret() { emit(0x22) }
    public mutating func jz(_ label: String) { emit(0x60); rel(label) }
    public mutating func jnz(_ label: String) { emit(0x70); rel(label) }
    public mutating func cjneA(_ imm: UInt8, _ label: String) { emit(0xB4, imm); rel(label) }
    public mutating func djnzR(_ n: UInt8, _ label: String) { emit(0xD8 + n); rel(label) }
    // Note: 8051 has no "CJNE A,Rn"; compare A with Rn via `xrlAR(n)` then `jnz`.
}
