import Foundation

/// Converts physical sensor values into the 10-bit A/D counts the Январь 5.1 board
/// would see. Channel numbers and pull-ups: docs/j5-hardware.md.
public enum Sensors {
    public static let coolantChannel = 4
    public static let airTempChannel = 2
    public static let throttleChannel = 3
    public static let voltageChannel = 1
    public static let mafChannel = 0
    /// J5LS: MAP sensor on pin 40 (flag 5F07.3); without the flag it sits on pin 7 instead of the MAF.
    public static let mapChannel = 9
    /// Pin 51 (4.7 kΩ pull-up): the intake air sensor input unless J5LS moves it to pin 44 (5F07.2).
    public static let airTempAltChannel = 14
    /// Pin 28: narrow-band oxygen sensor, 0.1–0.9 V when working.
    public static let lambdaChannel = 10
    /// Oxygen sensor heater current sense. 0.4 V lies between the J5 diagnostic thresholds
    /// (5F9A = 2 and 5FAD = 45 of 255 in J5LS_N35): with it J5V05L19 drops P0135 (emulator, 27.10.2026).
    public static let heaterCurrentChannel = 12
    public static let heaterCurrentOK = voltage(0.4)

    static func counts(volts: Double) -> UInt16 {
        UInt16(max(0, min(1023, (volts / 5 * 1023).rounded())))
    }

    /// VAZ 19.3801 NTC: 3520 Ω at 20 °C, 177 Ω at 100 °C (β ≈ 4090 K).
    public static func ntcResistance(celsius: Double) -> Double {
        let beta = log(3520.0 / 177.0) / (1 / 293.15 - 1 / 373.15)
        return 3520 * exp(beta * (1 / (celsius + 273.15) - 1 / 293.15))
    }

    /// Coolant sensor with the board's 2.151 kΩ pull-up to +5 V.
    public static func coolant(celsius: Double) -> UInt16 {
        let r = ntcResistance(celsius: celsius)
        return counts(volts: 5 * r / (r + 2151))
    }

    /// Air temperature input (pin 44): 1 kΩ pull-up to +5 V; same NTC curve
    /// (the user's car uses a VAZ coolant sensor in the intake).
    public static func airTemp(celsius: Double, pullUp: Double = 1000) -> UInt16 {
        let r = ntcResistance(celsius: celsius)
        return counts(volts: 5 * r / (r + pullUp))
    }

    /// How the image expects its air sensors (J5LS configuration flags, docs/j5-hardware.md).
    public struct Wiring: Equatable, Sendable {
        /// Load from a manifold pressure sensor instead of the MAF (J5LS, 5F05 bit 2).
        public var usesMAP: Bool
        /// ADC channel of the MAP sensor: pin 40 (9) with 5F07 bit 3, else pin 7 (0).
        public var mapChannel: Int
        /// Intake air temperature is configured (configuration word 1 bit 4, 0x6051).
        public var hasAirTemp: Bool
        public var isJ5LS: Bool

        public static func detect(rom: [UInt8], softwareID: String?) -> Wiring {
            let j5ls = softwareID?.hasPrefix("J5LS") ?? false
            func flag(_ address: Int, _ bit: Int) -> Bool { address < rom.count && rom[address] & (1 << bit) != 0 }
            let map = j5ls && flag(0x5F05, 2)
            return Wiring(usesMAP: map, mapChannel: map && flag(0x5F07, 3) ? Sensors.mapChannel : Sensors.mafChannel,
                          hasAirTemp: flag(0x6051, 4), isJ5LS: j5ls)
        }
    }

    /// Supply voltage through the 2490/681 divider (J5LS protocol formula).
    public static func supply(volts: Double) -> UInt16 {
        counts(volts: volts * 681 / (2490 + 681))
    }

    /// Plain voltage inputs (TPS, MAF, MAP): counts for `volts` at the pin.
    public static func voltage(_ volts: Double) -> UInt16 {
        counts(volts: volts)
    }
}
