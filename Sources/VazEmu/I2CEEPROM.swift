/// Serial I²C EEPROM of the 24Cxx family on a bit-banged bus (Январь 5.1: SCL = P3.3,
/// SDA = P1.5, device address A0h). Up to eight 256-byte blocks selected by bits 3…1 of
/// the device address (24C16 layout); writes complete instantly, page = 16 bytes.
/// A blank part reads FFh.
public final class I2CEEPROM {
    public var memory: [UInt8]
    /// Level the EEPROM drives on SDA (false = pulls low). The line is wired-AND.
    public private(set) var sdaOut = true

    private enum Phase { case idle, receive, receiveAck, transmit, transmitAck }
    private var phase = Phase.idle
    private var bits = 0, shift = 0
    private var byteIndex = 0          // bytes since START: 0 = device address
    private var reading = false
    private var block = 0, pointer = 0
    private var masterAck = false
    private var scl = true, sda = true

    public init(size: Int = 2048) {
        memory = [UInt8](repeating: 0xFF, count: size)
    }

    /// Feeds the levels the master drives; call after every change.
    public func update(scl newSCL: Bool, sda newSDA: Bool) {
        defer { scl = newSCL; sda = newSDA }
        if scl && newSCL && sda != newSDA {
            // SDA change while SCL is high: START (falling) or STOP (rising).
            if !newSDA { phase = .receive; bits = 0; shift = 0; byteIndex = 0 } else { phase = .idle }
            sdaOut = true
            return
        }
        let line = newSDA && sdaOut
        if !scl && newSCL { clockRise(line) } else if scl && !newSCL { clockFall() }
    }

    private func clockRise(_ line: Bool) {
        switch phase {
        case .receive: shift = shift << 1 | (line ? 1 : 0); bits += 1
        case .transmit: bits += 1
        case .transmitAck: masterAck = !line
        case .idle, .receiveAck: break
        }
    }

    private func clockFall() {
        switch phase {
        case .receive where bits == 8:
            if received(UInt8(shift)) { sdaOut = false; phase = .receiveAck } else { phase = .idle }
        case .receiveAck:
            sdaOut = true
            if reading { startByte() } else { phase = .receive; bits = 0; shift = 0 }
        case .transmit:
            if bits == 8 { sdaOut = true; phase = .transmitAck } else { sdaOut = memory[pointer] & (0x80 >> bits) != 0 }
        case .transmitAck:
            pointer = (pointer + 1) % memory.count
            if masterAck { startByte() } else { phase = .idle }
        case .idle, .receive: break
        }
    }

    /// Handles a complete received byte; returns whether to acknowledge it.
    private func received(_ b: UInt8) -> Bool {
        defer { byteIndex += 1 }
        switch byteIndex {
        case 0:
            guard b & 0xF0 == 0xA0 else { return false }
            reading = b & 1 != 0
            block = Int(b >> 1 & 0x07) % max(1, memory.count / 256)
            if reading { pointer %= memory.count }
            return true
        case 1:
            pointer = block * 256 + Int(b)
            return true
        default:
            memory[pointer] = b
            pointer = pointer & ~0x0F | (pointer + 1) & 0x0F // wrap within the 16-byte page
            return true
        }
    }

    private func startByte() {
        phase = .transmit
        bits = 0
        sdaOut = memory[pointer] & 0x80 != 0
    }
}
