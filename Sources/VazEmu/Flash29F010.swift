/// AMD Am29F010 (128 KB, 5 V-only, eight 16 KB sectors) as seen through the C509
/// programming mode: MOVX reads/writes in the 64 KB window of the selected bank.
/// JEDEC command set: reset F0h; autoselect AA→5555, 55→2AAA, 90→5555 (reads 01h/20h);
/// byte program AA, 55, A0, then address/data (bits can only go 1 → 0); sector erase
/// AA, 55, 80, AA, 55, then 30h to an address in the sector; chip erase …, 10h → 5555.
/// Operations complete instantly (status polling then simply reads the data back).
public final class Flash29F010 {
    public static let manufacturer: UInt8 = 0x01, device: UInt8 = 0x20
    public static let sectorSize = 0x4000

    public var memory: [UInt8]
    /// Address line A16 (bank), driven by the board; 0 for a single 64 KB image.
    public var bank = 0
    public private(set) var programmedBytes = 0
    public private(set) var erasedSectors: [Int] = []

    private enum State { case read, unlock1, unlock2, program, erase1, erase2, erase3, erase4, autoselect }
    private var state = State.read

    /// Fault injection (tests): sectors (0…7, physical) whose cells refuse to program or
    /// erase. The chip then answers data polling with DQ7 = complement and DQ5 = 1
    /// ("exceeded timing limits") until a reset (F0h), as the Am29F010 data sheet describes.
    public var faultySectors: Set<Int> = []
    /// Status byte the chip shows while it is stuck in a failed operation, or nil.
    private var failedStatus: UInt8?

    public init(image: [UInt8]) {
        memory = image + [UInt8](repeating: 0xFF, count: max(0, 0x20000 - image.count))
    }

    private func physical(_ addr: UInt16) -> Int { bank << 16 | Int(addr) }

    public func read(_ addr: UInt16) -> UInt8 {
        if let status = failedStatus { return status }
        if state == .autoselect {
            switch addr & 0xFF {
            case 0: return Self.manufacturer
            case 1: return Self.device
            default: return 0
            }
        }
        return memory[physical(addr)]
    }

    public func write(_ addr: UInt16, _ v: UInt8) {
        let cmd = addr & 0x7FFF
        switch (state, cmd, v) {
        // The program data cycle takes any address/value (incl. 0xF0) as the byte to write,
        // so it must be checked before the generic 0xF0 reset command.
        case (.program, _, _):
            state = .read
            if faultySectors.contains(physical(addr) / Self.sectorSize) {
                failedStatus = (~v & 0x80) | 0x20
                return
            }
            memory[physical(addr)] &= v
            programmedBytes += 1
        case (_, _, 0xF0) where failedStatus != nil:
            failedStatus = nil
            state = .read
        case (_, _, 0xF0): state = .read
        case (.read, 0x5555, 0xAA), (.autoselect, 0x5555, 0xAA): state = .unlock1
        case (.unlock1, 0x2AAA, 0x55): state = .unlock2
        case (.unlock2, 0x5555, 0x90): state = .autoselect
        case (.unlock2, 0x5555, 0xA0): state = .program
        case (.unlock2, 0x5555, 0x80): state = .erase1
        case (.erase1, 0x5555, 0xAA): state = .erase2
        case (.erase2, 0x2AAA, 0x55): state = .erase3
        case (.erase3, 0x5555, 0x10):
            for i in memory.indices { memory[i] = 0xFF }
            erasedSectors = Array(0..<8)
            state = .read
        case (.erase3, _, 0x30):
            let sector = physical(addr) / Self.sectorSize
            if faultySectors.contains(sector) { failedStatus = 0x20; state = .read; return }
            for i in sector * Self.sectorSize..<(sector + 1) * Self.sectorSize { memory[i] = 0xFF }
            erasedSectors.append(sector)
            state = .read
        case (.autoselect, _, _):
            break
        default:
            state = .read
        }
    }
}
