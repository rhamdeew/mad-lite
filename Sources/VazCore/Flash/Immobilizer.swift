import Foundation

/// Immobilizer state in the Январь 5.1 serial EEPROM (24C04), as reverse-engineered from
/// J5V05L19 (`docs/j5-reverse-notes.md`, "Иммобилайзер" / "EEPROM").
///
/// Bytes `0x02…0x07` hold the pair `[F47C, F47D]` three times; the firmware votes 2-of-3
/// (`0xBA08`). `F47D.7 == 0` means **trained** (`2Dh.2 = 1`): a trained block that gets no
/// answer from an immobilizer stops the engine (`0xABCA`, rpm → 0) and stores P1600. A blank
/// EEPROM (all FF) reads as **not trained**, so the engine runs — the behaviour of a new block.
///
/// Verified in the emulator (J5V05L19): trained EEPROM → rpm 0; `0x02…0x07 = FF` → rpm follows
/// the crank. Not verified on real hardware.
public enum Immobilizer {
    /// Byte range holding the three `[F47C, F47D]` copies.
    public static let stateRange = 0x02..<0x08
    /// Offsets of the three F47D copies within the EEPROM (bit 7 = "trained" when clear).
    public static let f47dOffsets = [0x03, 0x05, 0x07]

    /// Whether the EEPROM marks the immobilizer as trained (majority of the F47D copies have
    /// bit 7 clear). A trained block won't start without the matching АПС.
    public static func isTrained(eeprom: [UInt8]) -> Bool {
        guard eeprom.count > f47dOffsets.max()! else { return false }
        let cleared = f47dOffsets.filter { eeprom[$0] & 0x80 == 0 }.count
        return cleared >= 2
    }

    /// Returns a copy of `eeprom` with the immobilizer disabled: the state bytes `0x02…0x07`
    /// are set to FF, so every F47D copy has bit 7 set → not trained → the engine starts.
    /// Other EEPROM contents (mileage, adaptations, keys elsewhere) are left unchanged.
    public static func defeat(eeprom: [UInt8]) -> [UInt8] {
        var out = eeprom
        guard out.count >= stateRange.upperBound else { return out }
        for i in stateRange { out[i] = 0xFF }
        return out
    }

    /// Whether `defeat` would change anything (i.e. the block is currently trained-marked).
    public static func needsDefeat(eeprom: [UInt8]) -> Bool {
        guard eeprom.count >= stateRange.upperBound else { return false }
        return stateRange.contains { eeprom[$0] != 0xFF }
    }
}
