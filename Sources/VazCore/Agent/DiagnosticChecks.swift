import Foundation

/// Log channels and one row of values as `{id: {name, value, unit}}`; NaN (not in the frame) is left out.
public func channelValues(_ channels: [LogChannel], _ values: [Double]) -> JSONValue {
    var out: [String: JSONValue] = [:]
    for (c, v) in zip(channels, values) where v.isFinite {
        out[c.id] = ["name": .string(c.name), "value": .measured(v, digits: c.digits), "unit": .string(c.unit)]
    }
    return .object(out)
}

/// Min / max / mean / last of every channel over a stretch of polling, plus what the ECU
/// reported along the way. The agent gets this instead of a stream of frames.
public struct SampleStats: Sendable {
    public let channels: [LogChannel]
    public private(set) var rows = 0
    private var minimum: [Double]
    private var maximum: [Double]
    private var sum: [Double]
    private var count: [Int]
    private var last: [Double]
    /// Active fault flags and limp-home modes seen at least once.
    public private(set) var faultsSeen: Set<String> = []
    public private(set) var emergencySeen: Set<String> = []

    public init(channels: [LogChannel]) {
        self.channels = channels
        minimum = Array(repeating: .infinity, count: channels.count)
        maximum = Array(repeating: -.infinity, count: channels.count)
        sum = Array(repeating: 0, count: channels.count)
        count = Array(repeating: 0, count: channels.count)
        last = Array(repeating: .nan, count: channels.count)
    }

    public mutating func add(_ values: [Double], activeFaults: [String] = [], emergencyModes: [String] = []) {
        rows += 1
        for (i, v) in values.prefix(channels.count).enumerated() where v.isFinite {
            minimum[i] = Swift.min(minimum[i], v)
            maximum[i] = Swift.max(maximum[i], v)
            sum[i] += v
            count[i] += 1
            last[i] = v
        }
        faultsSeen.formUnion(activeFaults)
        emergencySeen.formUnion(emergencyModes)
    }

    public func mean(_ id: String) -> Double? {
        guard let i = channels.firstIndex(where: { $0.id == id }), count[i] > 0 else { return nil }
        return sum[i] / Double(count[i])
    }

    public func range(_ id: String) -> ClosedRange<Double>? {
        guard let i = channels.firstIndex(where: { $0.id == id }), count[i] > 0 else { return nil }
        return minimum[i]...maximum[i]
    }

    /// `only`: channel ids to include (empty — all with data).
    public func json(only: [String] = []) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for (i, c) in channels.enumerated() where count[i] > 0 && (only.isEmpty || only.contains(c.id)) {
            let d = c.digits
            out[c.id] = [
                "name": .string(c.name), "unit": .string(c.unit),
                "min": .measured(minimum[i], digits: d), "max": .measured(maximum[i], digits: d),
                "mean": .measured(sum[i] / Double(count[i]), digits: d + 1), "last": .measured(last[i], digits: d),
            ]
        }
        return [
            "frames": .int(rows),
            "channels": .object(out),
            "faults_seen": .array(faultsSeen.sorted().map { .string($0) }),
            "emergency_seen": .array(emergencySeen.sorted().map { .string($0) }),
        ]
    }
}

/// MAP sensor transfer function in the J5LS V43 form: `P (kPa) = (U + offset) · slope`
/// (docs/vendor/rotorman/v43bc.txt; the same two numbers the firmware stores at 60D2/60D4).
public struct MAPCharacteristic: Equatable, Sendable {
    public var slope: Double
    public var offset: Double

    public init(slope: Double, offset: Double) {
        self.slope = slope
        self.offset = offset
    }

    public func pressure(volts: Double) -> Double { (volts + offset) * slope }

    /// 20–300 kPa sensors, Bosch 0 281 002 996 and equivalents: 20 kPa → 0.4 V, 300 kPa → 4.65 V.
    public static let range20to300kPa = MAPCharacteristic(slope: 65.88, offset: -0.0964)
    /// GAZ 45.3829 (auto-bk J5LS thread; docs/j5ls.md).
    public static let gaz453829 = MAPCharacteristic(slope: 20.9, offset: 0.332)
}

public struct CheckFinding: Equatable, Sendable {
    public enum Verdict: String, Sendable { case ok = "норма", deviation = "отклонение", noData = "нет данных", info = "сведения" }
    public var check: String
    public var value: String
    public var expected: String
    public var verdict: Verdict
    public var hint: String

    public var json: JSONValue {
        ["check": .string(check), "value": .string(value), "expected": .string(expected),
         "verdict": .string(verdict.rawValue), "hint": .string(hint)]
    }
}

/// Ignition on, engine stopped, pedal released: what every sensor must show at rest.
/// Thresholds are deliberately wide — a finding means "look here", not a verdict on the part.
public enum ParkedCheck {
    public static func run(_ s: SampleStats, map: MAPCharacteristic? = nil) -> [CheckFinding] {
        func f(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }
        if let rpm = s.mean("rpm"), rpm > 50 {
            return [CheckFinding(check: "Двигатель", value: f(rpm, 0) + " об/мин", expected: "заглушен", verdict: .deviation,
                                 hint: "Проверка на стоянке — только при включённом зажигании и заглушенном двигателе.")]
        }
        var out: [CheckFinding] = []

        if let v = s.mean("voltage") {
            let ok = (11.8...13.2).contains(v)
            out.append(CheckFinding(check: "Бортсеть", value: f(v, 2) + " В", expected: "11,8–13,2 В", verdict: ok ? .ok : .deviation,
                                    hint: ok ? "" : v < 11.8 ? "Аккумулятор разряжен или просадка в питании ЭБУ (масса, реле, предохранитель) — пуск может не пойти."
                                                  : "Для заглушенного мотора много: подключено зарядное устройство или ошибка измерения."))
        } else { out.append(missing("Бортсеть")) }

        func temperature(_ id: String, _ title: String) -> Double? {
            guard let t = s.mean(id) else { out.append(missing(title)); return nil }
            let open = t <= -39, short = t >= 125
            out.append(CheckFinding(check: title, value: f(t, 0) + " °C", expected: "правдоподобная (не −40 и не 125+)",
                                    verdict: open || short ? .deviation : .ok,
                                    hint: open ? "ЭБУ видит −40 °C: обрыв цепи датчика или датчик не включён в комплектации прошивки."
                                        : short ? "Замыкание цепи датчика на массу." : ""))
            return t
        }
        let coolant = temperature("coolant", "ДТОЖ")
        if s.channels.contains(where: { $0.id == "air_temp" }), let air = temperature("air_temp", "ДТВ"),
           let coolant, coolant < 35, abs(air - coolant) > 12 {
            out.append(CheckFinding(check: "ДТВ и ДТОЖ на холодном моторе", value: "\(f(air, 0)) / \(f(coolant, 0)) °C",
                                    expected: "разница до 12 °C", verdict: .info,
                                    hint: "На остывшем моторе оба датчика обычно показывают почти одно и то же. Большая разница — повод проверить один из них."))
        }

        if let tpsV = s.mean("tps_v") {
            let ok = (0.3...0.8).contains(tpsV)
            out.append(CheckFinding(check: "ДПДЗ, педаль отпущена", value: f(tpsV, 3) + " В", expected: "0,3–0,8 В", verdict: ok ? .ok : .deviation,
                                    hint: ok ? "" : tpsV < 0.3 ? "Мало: обрыв питания или сигнала ДПДЗ, замыкание на массу или сигнал прижат посторонней цепью."
                                                    : "Много: дроссель не закрыт до упора, педаль нажата или датчик смещён."))
        } else if let thr = s.mean("throttle") {
            out.append(CheckFinding(check: "Дроссель, педаль отпущена", value: f(thr, 0) + " %", expected: "0–2 %", verdict: thr <= 2 ? .ok : .deviation,
                                    hint: thr <= 2 ? "" : "Дроссель не закрыт, педаль нажата или ДПДЗ смещён."))
        }
        if let range = s.range("throttle"), range.upperBound - range.lowerBound > 3 {
            out.append(CheckFinding(check: "Дроссель во время проверки", value: "\(f(range.lowerBound, 0))–\(f(range.upperBound, 0)) %",
                                    expected: "не меняется", verdict: .info, hint: "Педаль трогали — ДПДЗ проверяется только с отпущенной педалью."))
        }

        if let kpa = s.mean("map_kpa") {
            let ok = (85...106).contains(kpa)
            out.append(CheckFinding(check: "ДАД — давление (атмосфера)", value: f(kpa, 1) + " кПа", expected: "85–106 кПа", verdict: ok ? .ok : .deviation,
                                    hint: ok ? "" : "На заглушенном моторе во впуске атмосфера. Другое значение: в прошивке характеристика другого датчика, неисправен датчик, шланг или проводка."))
            if let volts = s.mean("map_v") {
                if !(0.2...4.8).contains(volts) {
                    out.append(CheckFinding(check: "ДАД — напряжение", value: f(volts, 3) + " В", expected: "0,2–4,8 В", verdict: .deviation,
                                            hint: "Сигнал у края шкалы: обрыв или замыкание цепи ДАД (питание 5 В, масса, сигнал)."))
                } else if let map {
                    let sensor = map.pressure(volts: volts)
                    let ok = abs(sensor - kpa) <= 8
                    out.append(CheckFinding(check: "ДАД — характеристика в прошивке", value: "ЭБУ \(f(kpa, 0)) кПа, по датчику \(f(sensor, 0)) кПа при \(f(volts, 2)) В",
                                            expected: "расхождение до 8 кПа", verdict: ok ? .ok : .deviation,
                                            hint: ok ? "" : "ЭБУ пересчитывает напряжение не по характеристике этого датчика: наклон и смещение ДАД в прошивке от другого датчика. Нагрузка, топливо и УОЗ считаются неверно во всех режимах — к калибровщику."))
                } else {
                    out.append(CheckFinding(check: "ДАД — напряжение", value: f(volts, 3) + " В", expected: "по характеристике датчика", verdict: .info,
                                            hint: "Передайте наклон и смещение датчика (map_slope_kpa_per_v, map_offset_v), чтобы сверить с прошивкой."))
                }
            }
        }

        let faults = s.faultsSeen.sorted(), emergency = s.emergencySeen.sorted()
        out.append(CheckFinding(check: "Текущие неисправности", value: faults.isEmpty ? "нет" : faults.joined(separator: "; "),
                                expected: "нет", verdict: faults.isEmpty ? .ok : .deviation,
                                hint: faults.isEmpty ? "" : "Флаги неисправностей из кадра 21 01 прямо сейчас (не путать с сохранёнными кодами)."))
        if !emergency.isEmpty {
            out.append(CheckFinding(check: "Аварийный режим", value: emergency.joined(separator: "; "), expected: "нет", verdict: .deviation,
                                    hint: "ЭБУ подменяет показания датчика аварийным значением — ехать можно, но работа двигателя будет хуже."))
        }
        return out
    }

    static func missing(_ check: String) -> CheckFinding {
        CheckFinding(check: check, value: "—", expected: "", verdict: .noData, hint: "Нет в кадре этого блока.")
    }
}
