import Foundation

/// Extended live-data record of J5LS firmware (`21 8C` / `21 0D` / `21 0F`),
/// per the author's protocol supplement of 16.10.2020 (docs/j5ls.md).
///
/// Offsets count from the first data byte after `61 YY`. Parameters past the end
/// of the record are not supported by that firmware and read as zero.
public struct J5LSLiveData: Equatable, Sendable {
    public let recordID: UInt8
    public let raw: [UInt8]

    /// Record ids to try in this order; the first one that answers is used from then on.
    public static let recordIDs: [UInt8] = [0x8C, 0x0D, 0x0F]

    public init(response d: [UInt8]) throws {
        guard d.count >= 2, d[0] == 0x61, Self.recordIDs.contains(d[1]) else {
            throw KWPError.unexpectedResponse(d)
        }
        recordID = d[1]
        raw = Array(d[2...])
    }

    /// Whether byte `i` is in the record. Older builds send less: J5LS N35 answers `21 0D` with
    /// 61 bytes (no idle error 71, knock A/D 72–75, gear 76; pressure 52–54 is sent but stays
    /// zero) and `21 0F` with 51. The layout of what is there matches the 2020 document
    /// (emulator, 27.10.2026).
    public func has(_ i: Int) -> Bool { i < raw.count }

    func byte(_ i: Int) -> Int { i < raw.count ? Int(raw[i]) : 0 }
    func signed(_ i: Int) -> Int { i < raw.count ? Int(Int8(bitPattern: raw[i])) : 0 }
    func word(_ i: Int) -> Int { byte(i) | byte(i + 1) << 8 }
    func volts(_ i: Int) -> Double { Double(byte(i)) * 5 / 256 }

    public var storedErrorCount: Int { byte(2) }
    public var coolantTemp: Double { Double(byte(8) - 40) }
    /// Target AFR; sent only by engineering ECUs, zero otherwise.
    public var targetAFR: Double { byte(9) == 0 ? 0 : Double(byte(9) + 128) * 14.7 / 256 }
    public var throttle: Double { Double(byte(11)) }
    public var rpm: Double { Double(byte(12) * 40) }
    /// From the crank period: more precise than `rpm`.
    public var preciseRPM: Double { word(14) == 0 ? 0 : 5_000_000 / Double(word(14)) }
    public var iacDesired: Int { byte(16) }
    public var iacActual: Int { byte(17) }
    public var injectionCorrection: Double { Double(byte(18) + 128) * 1000 / 256 }
    public var injectionPhase: Double { Double(((byte(19) - 196) % 256 + 256) % 256 * 6) }
    /// Sent only by engineering ECUs.
    public var ignitionAdvance: Double { Double(signed(20)) / 2 }
    /// Knock retard per cylinder 1…4 (record order is 2, 1, 3, 4).
    public var knockRetard: [Double] { [22, 21, 23, 24].map { Double(signed($0)) / 2 } }
    public var mafOrMapVolts: Double { volts(26) }
    public var ignitionVoltage: Double { Double(byte(27)) * (2490 + 681) / 681 * 5 / 256 }
    public var throttleVolts: Double { volts(29) }
    public var coolantVolts: Double { volts(30) }
    public var airTempVolts: Double { volts(31) }
    /// Oxygen sensor on the `21 01` scale (1.25 V full range): byte 32 is the same byte as
    /// `21 01` byte 20 on the car (0x5E = 0.459 V, 27.10.2026). The 2020 document's E·5/256 gives
    /// 1.84 V, which no narrowband sensor puts out.
    public var lambdaVolts: Double { Double(byte(32)) * 1.25 / 256 }
    public var octaneCorrection: Double { Double(signed(34)) / 2 }
    public var speed: Double { Double(byte(35)) }
    public var idleRpmTarget: Double { Double(byte(36) * 10) }
    public var airTemp: Double { Double(byte(37) - 40) }
    /// Acceleration pump fuel from throttle, mg/stroke.
    public var accelFuelThrottle: Double { Double(word(39)) * 10 / 882 }
    /// Wideband (actual) AFR; zero if no wideband controller.
    public var widebandAFR: Double { byte(41) == 0 ? 0 : Double(byte(41) + 128) * 14.7 / 256 }
    public var injectionTime: Double { Double(word(43)) * 8 / 1000 }
    public var airFlow: Double { Double(word(45)) / 10 }
    public var cycleAir: Double { Double(word(47)) / 6 }
    /// Byte 52, «АЦП ДАД» in the 2020 document. Not the pin voltage in later V43 builds: it stayed at
    /// `3C` (1.172 V) on the car with the MAP sensor unplugged and plugged while byte 26 went
    /// 0 → 1.15 V (logs 27.10.2026). The MAP signal on pin 40 is `mafOrMapVolts`.
    public var mapVolts: Double { volts(52) }
    /// Absolute manifold pressure, kPa.
    public var manifoldPressure: Double { Double(word(53)) / 100 }
    /// Acceleration pump fuel from pressure, mg/stroke.
    public var accelFuelPressure: Double { Double(word(55)) * 10 / 882 }
    public var boostDuty: Double { Double(byte(58)) * 100 / 256 }
    /// ECU uptime, ms.
    public var uptime: Int { word(67) | word(69) << 16 }
    public var idleRpmError: Double { Double(signed(71) * 10) }
    /// Knock sensor ADC per cylinder 1…4, volts (record order 2, 1, 3, 4).
    public var knockVolts: [Double] { [73, 72, 74, 75].map(volts) }
    public var gear: Int { byte(76) }
    public var fuelPressure: Double { Double(byte(84)) * 10 / 256 }
    public var oilPressure: Double { Double(byte(85)) * 10 / 256 }
}
