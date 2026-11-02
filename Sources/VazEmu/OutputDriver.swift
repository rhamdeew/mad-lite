/// External low-side driver of the relays and lamps (Январь 5.1), fed one byte at a time over a
/// bit-banged serial line on port 9: P9.2 select (low during a transfer), P9.0 clock, P9.3 data
/// to the driver, P9.6 data back (diagnostic status). J5V05L19 shifts out the output image
/// `F999` MSB first at 0xA8B7 and stores the byte read back in `F9BA`
/// (docs/emulator.md, «Драйвер выходов»). The driver answers all ones (no fault reported).
public final class OutputDriver {
    /// Last byte latched by a complete 8-bit transfer; nil before the first one.
    public private(set) var latched: UInt8?
    /// Complete transfers so far.
    public private(set) var transfers = 0

    private var select = true, clock = false
    private var shift = 0, bits = 0

    public init() {}

    /// Feeds the levels the processor drives on port 9; call after every instruction.
    public func update(select newSelect: Bool, clock newClock: Bool, data: Bool) {
        defer { select = newSelect; clock = newClock }
        if select && !newSelect { shift = 0; bits = 0 }
        // The firmware raises the clock, then sets the data bit, then lowers the clock.
        if !newSelect && clock && !newClock { shift = (shift << 1 | (data ? 1 : 0)) & 0xFF; bits += 1 }
        if !select && newSelect, bits == 8 {
            latched = UInt8(shift)
            transfers += 1
        }
    }
}
