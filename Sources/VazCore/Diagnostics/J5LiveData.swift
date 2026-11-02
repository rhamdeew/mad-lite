import Foundation

/// Decoded `61 01` (afterSalesService) frame of Январь 5.1 / M1.5.4N.
/// Byte layout and formulas: docs/kwp2000-j5.md.
///
/// Two layouts exist, told apart by length: Euro 2 firmware (-41, -61, 2104-01) sends 34 data
/// bytes; Р83 firmware without an oxygen sensor (2111-71 J5V13, 2112-71 J5V07) sends 32 —
/// byte 12 is the CO trim instead of AFR and the two oxygen-sensor bytes are absent.
/// Январь 7.2 I205DO54 builds the Euro 2 frame from the same IRAM cells
/// (list at 0xBE75). The lambda-voltage byte is still at the same offset,
/// but the firmware copies it from F964 instead of F815. One extra XRAM
/// word (F93B, not decoded) follows the checksum, so the payload is 36
/// bytes rather than 34. A longer Euro 2 payload still parses.
public struct J5LiveData: Equatable, Sendable {
    public enum Standard: Sendable {
        case euro2, r83
    }

    public struct Flags: Equatable, Sendable {
        public let raw: UInt8
        public let names: [String?]

        public subscript(bit: Int) -> Bool { raw & (1 << bit) != 0 }
        /// Names of the set bits.
        public var active: [String] { (0..<8).compactMap { self[$0] ? names[$0] : nil } }
    }

    public let configuration1, configuration2: Flags
    public private(set) var mode1, mode2: Flags
    public private(set) var faults: [Flags]
    public let standard: Standard
    public let coolantTemp: Double
    /// Euro 2 only.
    public let afr: Double?
    /// CO trim from the potentiometer (Р83 only), −0.5…+0.5.
    public let coCorrection: Double?
    public let throttle: Double
    public let rpm: Double
    public let idleRpm: Double
    public let iacDesired: Int
    public let iacActual: Int
    public let injectionCorrection: Double
    public let ignitionAdvance: Double
    public let speed: Double
    public let voltage: Double
    public let idleRpmTarget: Double
    /// Euro 2 only.
    public let lambdaVoltage: Double?
    public private(set) var lambdaFlags: Flags?
    public let injectionTime: Double
    public let airFlow: Double
    public let cycleAir: Double
    public let fuelPerHour: Double
    public let fuelPer100km: Double
    public let romChecksum: UInt16

    public static let dataLength = 34
    public static let r83DataLength = 32

    public init(response d: [UInt8]) throws {
        guard d.count >= 2 + Self.r83DataLength, d[0] == 0x61, d[1] == 0x01 else {
            throw KWPError.unexpectedResponse(d)
        }
        let b = Array(d[2...]) // b[0] = byte #3 of the spec table
        let euro2 = b.count >= Self.dataLength
        standard = euro2 ? .euro2 : .r83
        // Fields after the oxygen-sensor bytes move 2 bytes up in the Р83 layout.
        let tail = euro2 ? 0 : -2
        func word(_ i: Int) -> Double { Double(Int(b[i + tail]) | Int(b[i + tail + 1]) << 8) }
        func flags(_ i: Int, _ names: [String?]) -> Flags { Flags(raw: b[i], names: names) }

        configuration1 = flags(0, Names.configuration1)
        configuration2 = flags(1, Names.configuration2)
        mode1 = flags(2, Names.mode1)
        mode2 = flags(3, euro2 ? Names.mode2 : Names.mode2R83)
        faults = euro2
            ? [flags(4, Names.faults1), flags(5, Names.faults2), flags(6, Names.faults3), flags(7, Names.faults4)]
            : [flags(4, Names.faults1R83), flags(5, Names.faults2R83), flags(6, Names.faults3R83),
               flags(7, Names.faults4R83)]
        coolantTemp = Double(b[8]) - 40
        afr = euro2 ? 14.7 * (Double(b[9]) + 128) / 256 : nil
        coCorrection = euro2 ? nil : Double(Int8(bitPattern: b[9])) / 256
        throttle = Double(b[10])
        rpm = Double(b[11]) * 40
        idleRpm = Double(b[12]) * 10
        iacDesired = Int(b[13])
        iacActual = Int(b[14])
        injectionCorrection = (Double(b[15]) + 128) / 256
        ignitionAdvance = Double(Int8(bitPattern: b[16])) / 2
        speed = Double(b[17])
        voltage = 5.2 + Double(b[18]) * 0.05
        idleRpmTarget = Double(b[19]) * 10
        lambdaVoltage = euro2 ? 1.25 * Double(b[20]) / 256 : nil
        lambdaFlags = euro2 ? flags(21, Names.lambda) : nil
        injectionTime = word(22) / 125
        airFlow = word(24) / 10
        cycleAir = word(26) / 6
        fuelPerHour = word(28) / 50
        fuelPer100km = word(30) / 128
        romChecksum = UInt16(word(32))
    }

    /// This frame with the mode, fault and oxygen-sensor flags of a J5LS record, which carries
    /// them at bytes 0–1, 3–6 and 33 (SMS OLT v1 layout, OpenOLT). On the car they match `21 01`
    /// byte for byte (27.10.2026); the record is read every cycle, `21 01` less often (PollPlan).
    public func withStatus(from e: J5LSLiveData) -> J5LiveData {
        guard e.has(33) else { return self }
        var copy = self
        func flags(_ i: Int, like f: Flags) -> Flags { Flags(raw: e.raw[i], names: f.names) }
        copy.mode1 = flags(0, like: mode1)
        copy.mode2 = flags(1, like: mode2)
        copy.faults = faults.enumerated().map { flags(3 + $0.offset, like: $0.element) }
        copy.lambdaFlags = lambdaFlags.map { flags(33, like: $0) }
        return copy
    }

    /// All set fault flags as text.
    public var activeFaults: [String] { faults.flatMap(\.active) }

    /// Limp-home substitutions the ECU is using now, derived from the current fault flags
    /// (faults 2/3: bit 3 coolant, bit 5 TPS, bit 6 MAF — the same bits in Euro 2 and Р83).
    /// Established in J5V05L19 code (docs/j5-reverse-notes.md, «Аварийные режимы датчиков»);
    /// J5LS has the same tables in its «Аварийные режимы» map group. Whether J5LS reports a
    /// MAP-sensor fault through the MAF bits is not verified.
    public var emergencyModes: [String] {
        let maf = faults[1][6] || faults[2][6], tps = faults[1][5] || faults[2][5]
        let coolant = faults[1][3] || faults[2][3]
        var modes: [String] = []
        if maf && tps {
            modes.append("ДМРВ/ДАД и ДПДЗ неисправны: фиксированный расход воздуха, аварийный УОЗ и состав смеси")
        } else if maf {
            modes.append("ДМРВ/ДАД неисправен: наполнение по дросселю (таблица 726D), аварийный УОЗ (7877) и состав смеси")
        } else if tps {
            modes.append("ДПДЗ неисправен: аварийный УОЗ (7877) и состав смеси")
        }
        if coolant { modes.append("ДТОЖ неисправен: температура по модели прогрева (7DF7)") }
        return modes
    }

    enum Names {
        static let configuration1: [String?] = ["ДК", "адсорбер", "клапан рециркуляции", "датчик детонации",
                                                "датчик температуры воздуха", "датчик фазы", "запрет отсечки топлива",
                                                "адаптация уставки ХХ"]
        static let configuration2: [String?] = ["потенциометр CO", "адаптация нуля ДЗ", "асинхронная подача при пуске",
                                                "постоянное хранение ошибок", "датчик скорости", "одновременный впрыск",
                                                "асинхронный впрыск при ускорении", nil]
        static let mode1: [String?] = ["двигатель выключен", "холостой ход", "обогащение по мощности",
                                       "блокировка подачи топлива", "регулирование по ДК", "зона детонации",
                                       "продувка адсорбера", "сохранение обучения по ДК"]
        static let mode2: [String?] = [nil, "ХХ в прошлом цикле", "блокировка выхода из ХХ", "детонация в прошлом цикле",
                                       "продувка в прошлом цикле", "обнаружена детонация", "прошлое состояние ДК",
                                       "текущее состояние ДК"]
        static let faults1: [String?] = ["датчик синхронизации КВ", nil, "EEPROM", "нагреватель ДК", "датчик фазы",
                                         "сброс процессора", "ОЗУ", "ПЗУ"]
        static let faults2: [String?] = ["низкое напряжение", nil, nil, "ДТОЖ: низкий сигнал", "ДК: низкий сигнал",
                                         "ДПДЗ: низкий сигнал", "ДМРВ: низкий сигнал", "низкий шум двигателя"]
        static let faults3: [String?] = ["высокое напряжение", nil, nil, "ДТОЖ: высокий сигнал", "ДК: высокий сигнал",
                                         "ДПДЗ: высокий сигнал", "ДМРВ: высокий сигнал", "высокий шум двигателя"]
        static let faults4: [String?] = ["обрыв датчика детонации", "нет связи с иммобилайзером", nil,
                                         "нет активности ДК", "ДК не реагирует на обеднение",
                                         "ДК не реагирует на обогащение", "датчик скорости", "регулятор ХХ"]
        // Р83 (no oxygen sensor): bits from docs/vendor/kwp2000_r83.txt, 6.3.3.3.4–8.
        static let mode2R83: [String?] = ["повторный замер параметров ХХ"] + mode2.dropFirst()
        static let faults1R83: [String?] = ["датчик синхронизации КВ", nil, "EEPROM", nil, "датчик фазы",
                                            "сброс процессора", "ОЗУ", "ПЗУ"]
        static let faults2R83: [String?] = ["низкое напряжение", "потенциометр CO: низкий сигнал", nil,
                                            "ДТОЖ: низкий сигнал", nil, "ДПДЗ: низкий сигнал", "ДМРВ: низкий сигнал",
                                            "низкий шум двигателя"]
        static let faults3R83: [String?] = ["высокое напряжение", "потенциометр CO: высокий сигнал", nil,
                                            "ДТОЖ: высокий сигнал", nil, "ДПДЗ: высокий сигнал",
                                            "ДМРВ: высокий сигнал", "высокий шум двигателя"]
        static let faults4R83: [String?] = ["обрыв датчика детонации", "нет связи с иммобилайзером", nil, nil, nil, nil,
                                            "датчик скорости", "регулятор ХХ"]
        static let lambda: [String?] = ["ДК готов", "нагрев ДК разрешён", nil, nil, nil, nil, nil, nil]
    }
}
