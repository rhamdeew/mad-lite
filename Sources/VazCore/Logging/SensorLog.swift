import Foundation

/// One logged column: machine-friendly id for the CSV header, Russian name and unit for people.
public struct LogChannel: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let unit: String
    public let digits: Int
}

/// Session description stored next to the CSV (`<name>.json`).
public struct LogSession: Codable, Equatable, Sendable {
    public var started: Date
    public var softwareID: String?
    public var romChecksum: String?
    public var source: String
    public var extendedRecord: String?
    public var appVersion: String
    public var notes: String
    public var channels: [LogChannel]
    public var markers: [LogMarker] = []
    public var rows = 0
    /// File with the raw KWP exchanges (`<name>.kwp.txt`), when they were recorded.
    public var rawFrames: String?
    /// Stored trouble codes (`18`) read during the session, with the time of each read.
    public var troubleCodes: [LogTroubleCodes]?

    public init(started: Date, softwareID: String?, romChecksum: String?, source: String,
                extendedRecord: String?, appVersion: String, notes: String, channels: [LogChannel]) {
        self.started = started
        self.softwareID = softwareID
        self.romChecksum = romChecksum
        self.source = source
        self.extendedRecord = extendedRecord
        self.appVersion = appVersion
        self.notes = notes
        self.channels = channels
    }
}

public struct LogTroubleCodes: Codable, Equatable, Sendable {
    public let timeMs: Int
    /// "P0122 Низкий уровень сигнала с датчика положения дросселя (статус 20)".
    public let codes: [String]
}

public struct LogMarker: Codable, Equatable, Sendable {
    public let timeMs: Int
    public let text: String
}

/// Turns diagnostic frames into log rows. Base frame (`21 01`) channels are always
/// present; J5LS channels are added when the ECU answers an extended record.
public enum LogSchema {
    public static let base: [LogChannel] = [
        .init(id: "rpm", name: "Обороты", unit: "об/мин", digits: 0),
        .init(id: "coolant", name: "ТОЖ", unit: "°C", digits: 0),
        .init(id: "throttle", name: "Дроссель", unit: "%", digits: 0),
        .init(id: "ignition", name: "УОЗ", unit: "°", digits: 1),
        .init(id: "inj_ms", name: "Время впрыска", unit: "мс", digits: 3),
        .init(id: "afr", name: "AFR (базовый кадр)", unit: "", digits: 2),
        .init(id: "inj_corr", name: "Коэф. коррекции впрыска", unit: "", digits: 3),
        .init(id: "cycle_air", name: "Цикловой расход воздуха", unit: "мг/такт", digits: 1),
        .init(id: "air_flow", name: "Массовый расход воздуха", unit: "кг/ч", digits: 1),
        .init(id: "voltage", name: "Напряжение", unit: "В", digits: 2),
        .init(id: "idle_rpm", name: "Обороты ХХ", unit: "об/мин", digits: 0),
        .init(id: "idle_target", name: "Желаемые обороты ХХ", unit: "об/мин", digits: 0),
        .init(id: "iac_desired", name: "РХХ желаемое", unit: "шаг", digits: 0),
        .init(id: "iac_actual", name: "РХХ текущее", unit: "шаг", digits: 0),
        .init(id: "lambda_v", name: "Напряжение ДК", unit: "В", digits: 3),
        .init(id: "speed", name: "Скорость", unit: "км/ч", digits: 0),
        .init(id: "fuel_lph", name: "Расход топлива", unit: "л/ч", digits: 2),
        .init(id: "f_idle", name: "Флаг ХХ", unit: "0/1", digits: 0),
        .init(id: "f_fuel_cut", name: "Флаг блокировки подачи топлива", unit: "0/1", digits: 0),
        .init(id: "f_power", name: "Флаг обогащения по мощности", unit: "0/1", digits: 0),
        .init(id: "f_lambda", name: "Флаг регулирования по ДК", unit: "0/1", digits: 0),
        .init(id: "f_knock_zone", name: "Флаг зоны детонации", unit: "0/1", digits: 0),
        .init(id: "f_knock", name: "Флаг обнаружения детонации", unit: "0/1", digits: 0),
        .init(id: "faults", name: "Слова неисправностей 1–4", unit: "hex", digits: 0),
        .init(id: "f_emergency", name: "Аварийный режим (ДМРВ/ДАД, ДПДЗ, ДТОЖ)", unit: "0/1", digits: 0),
    ]

    public static let j5ls: [LogChannel] = [
        .init(id: "map_kpa", name: "Давление во впуске (ДАД)", unit: "кПа", digits: 2),
        .init(id: "air_temp", name: "Температура воздуха", unit: "°C", digits: 0),
        .init(id: "wb_afr", name: "AFR фактический (ШДК)", unit: "", digits: 2),
        .init(id: "target_afr", name: "AFR целевой", unit: "", digits: 2),
        .init(id: "rpm_precise", name: "Обороты точные", unit: "об/мин", digits: 0),
        .init(id: "knock1", name: "Откат УОЗ по детонации, цил. 1", unit: "°", digits: 1),
        .init(id: "knock2", name: "Откат УОЗ по детонации, цил. 2", unit: "°", digits: 1),
        .init(id: "knock3", name: "Откат УОЗ по детонации, цил. 3", unit: "°", digits: 1),
        .init(id: "knock4", name: "Откат УОЗ по детонации, цил. 4", unit: "°", digits: 1),
        .init(id: "knock_v1", name: "Сигнал ДД, цил. 1", unit: "В", digits: 3),
        .init(id: "knock_v2", name: "Сигнал ДД, цил. 2", unit: "В", digits: 3),
        .init(id: "knock_v3", name: "Сигнал ДД, цил. 3", unit: "В", digits: 3),
        .init(id: "knock_v4", name: "Сигнал ДД, цил. 4", unit: "В", digits: 3),
        .init(id: "inj_phase", name: "Фаза впрыска", unit: "°", digits: 0),
        .init(id: "accel_fuel_thr", name: "Ускорнасос по дросселю", unit: "мг/такт", digits: 2),
        .init(id: "accel_fuel_map", name: "Ускорнасос по давлению", unit: "мг/такт", digits: 2),
        .init(id: "idle_rpm_err", name: "Ошибка регулирования ХХ", unit: "об/мин", digits: 0),
        .init(id: "octane", name: "Октан-корректор", unit: "°", digits: 1),
        .init(id: "boost_duty", name: "ШИМ наддува", unit: "%", digits: 1),
        .init(id: "gear", name: "Передача", unit: "", digits: 0),
        .init(id: "fuel_press", name: "Давление топлива", unit: "атм", digits: 2),
        .init(id: "oil_press", name: "Давление масла", unit: "атм", digits: 2),
        .init(id: "ign_volt", name: "Напряжение клеммы 15", unit: "В", digits: 2),
        // Raw sensor voltages: tell a sensor fault from wiring (a capped TPS, a MAP reading high).
        .init(id: "tps_v", name: "Напряжение ДПДЗ", unit: "В", digits: 3),
        .init(id: "map_v", name: "Напряжение ДМРВ/ДАД", unit: "В", digits: 3),
        .init(id: "clt_v", name: "Напряжение ДТОЖ", unit: "В", digits: 3),
        .init(id: "iat_v", name: "Напряжение ДТВ", unit: "В", digits: 3),
    ]

    public static func channels(extended: Bool) -> [LogChannel] {
        extended ? base + j5ls : base
    }

    public static func values(base frame: J5LiveData, extended e: J5LSLiveData?) -> [Double] {
        let b = e.map { frame.withStatus(from: $0) } ?? frame
        func flag(_ f: J5LiveData.Flags, _ bit: Int) -> Double { f[bit] ? 1 : 0 }
        let faults = b.faults.reduce(0) { $0 << 8 | Int($1.raw) }
        var v: [Double] = [
            b.rpm, b.coolantTemp, b.throttle, b.ignitionAdvance, b.injectionTime, b.afr ?? .nan,
            b.injectionCorrection, b.cycleAir, b.airFlow, b.voltage, b.idleRpm, b.idleRpmTarget,
            Double(b.iacDesired), Double(b.iacActual), b.lambdaVoltage ?? .nan, b.speed, b.fuelPerHour,
            flag(b.mode1, 1), flag(b.mode1, 3), flag(b.mode1, 2), flag(b.mode1, 4), flag(b.mode1, 5), flag(b.mode2, 5),
            Double(faults),
            b.emergencyModes.isEmpty ? 0 : 1,
        ]
        if let e, e.has(48) {
            // The same ECU variables as in `21 01` (byte for byte on the car, 27.10.2026), but
            // fresh every row: with the engine running `21 01` is read less often (PollPlan).
            func set(_ id: String, _ x: Double) { v[base.firstIndex { $0.id == id }!] = x }
            set("rpm", e.rpm); set("coolant", e.coolantTemp); set("throttle", e.throttle)
            set("inj_ms", e.injectionTime); set("inj_corr", e.injectionCorrection / 1000)
            set("cycle_air", e.cycleAir); set("air_flow", e.airFlow); set("idle_target", e.idleRpmTarget)
            set("iac_desired", Double(e.iacDesired)); set("iac_actual", Double(e.iacActual)); set("speed", e.speed)
            if b.lambdaVoltage != nil { set("lambda_v", e.lambdaVolts) }
        }
        if let e {
            // A value past the end of a short record (older J5LS) is an empty cell, not a zero:
            // 0 kPa would otherwise pass for a real pressure in the analysis.
            func x(_ value: Double, _ last: Int) -> Double { e.has(last) ? value : .nan }
            v += [x(e.manifoldPressure, 54), x(e.airTemp, 37), x(e.widebandAFR, 41), x(e.targetAFR, 9), x(e.preciseRPM, 15)]
            v += e.knockRetard.map { x($0, 24) } + e.knockVolts.map { x($0, 75) }
            v += [x(e.injectionPhase, 19), x(e.accelFuelThrottle, 40), x(e.accelFuelPressure, 56), x(e.idleRpmError, 71),
                  x(e.octaneCorrection, 34), x(e.boostDuty, 58), x(Double(e.gear), 76), x(e.fuelPressure, 84),
                  x(e.oilPressure, 85), x(e.ignitionVoltage, 27), x(e.throttleVolts, 29), x(e.mafOrMapVolts, 26),
                  x(e.coolantVolts, 30), x(e.airTempVolts, 31)]
        }
        return v
    }
}

/// Writes a sensor log as `<name>.csv` (first column `time_ms`, then channel ids, last `marker`)
/// plus `<name>.json` with the session description. Rows are flushed as they come,
/// so a dropped connection never loses what was recorded.
public final class SensorLogWriter {
    public let csvURL: URL
    public let jsonURL: URL
    public private(set) var session: LogSession
    private let handle: FileHandle
    private let start: Date
    private var pendingMarker: String?
    /// Raw KWP exchanges, opened on the first `appendRaw`.
    private var rawHandle: FileHandle?
    public var rawURL: URL { csvURL.deletingPathExtension().appendingPathExtension("kwp.txt") }

    public init(directory: URL, name: String, session: LogSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        csvURL = directory.appendingPathComponent(name + ".csv")
        jsonURL = directory.appendingPathComponent(name + ".json")
        self.session = session
        start = session.started
        FileManager.default.createFile(atPath: csvURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: csvURL)
        let header = (["time_ms"] + session.channels.map(\.id) + ["marker"]).joined(separator: ",") + "\n"
        try handle.write(contentsOf: Data(header.utf8))
        try saveSession()
    }

    deinit {
        try? handle.close()
        try? rawHandle?.close()
    }

    public var elapsedMs: Int { milliseconds(Date()) }

    private func milliseconds(_ time: Date) -> Int { Int((time.timeIntervalSince(start) * 1000).rounded()) }

    /// Attaches `text` to the next row and records it in the session markers.
    /// Stores a read of the ECU's trouble codes in the session file and as a marker on the timeline.
    public func recordTroubleCodes(_ dtcs: [DTC], at time: Date = Date()) {
        let codes = dtcs.map { "\($0.code) \($0.description) (статус \(String(format: "%02X", $0.status)))" }
        session.troubleCodes = (session.troubleCodes ?? []) + [LogTroubleCodes(timeMs: milliseconds(time), codes: codes)]
        mark(dtcs.isEmpty ? "коды: нет" : "коды: " + dtcs.map(\.code).joined(separator: " "), at: time)
    }

    /// Several marks before the next row (e.g. "обрыв связи" and "связь восстановлена") share it.
    /// The session file is rewritten so marks survive an app that never gets to `finish()`.
    public func mark(_ text: String, at time: Date = Date()) {
        pendingMarker = pendingMarker.map { $0 + "; " + text } ?? text
        session.markers.append(LogMarker(timeMs: milliseconds(time), text: text))
        try? saveSession()
    }

    public func append(_ values: [Double], at time: Date = Date()) throws {
        precondition(values.count == session.channels.count, "Число значений не совпадает с колонками")
        var fields = [String(milliseconds(time))]
        for (value, channel) in zip(values, session.channels) {
            // NaN: the frame has no such field (e.g. AFR in a Р83 frame) — leave the cell empty.
            fields.append(value.isNaN ? ""
                : channel.unit == "hex" ? String(format: "%08X", Int(value))
                : String(format: "%.\(channel.digits)f", value))
        }
        // Quote the marker: free text may contain commas.
        fields.append(pendingMarker.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" } ?? "")
        pendingMarker = nil
        try handle.write(contentsOf: Data((fields.joined(separator: ",") + "\n").utf8))
        session.rows += 1
    }

    /// Records one request/response pair as hex (`time_ms > 21 01 < 61 01 …`), so the log can be
    /// recomputed if a formula turns out wrong.
    public func appendRaw(request: [UInt8], response: [UInt8], at time: Date = Date()) throws {
        if rawHandle == nil {
            FileManager.default.createFile(atPath: rawURL.path, contents: nil)
            rawHandle = try FileHandle(forWritingTo: rawURL)
            session.rawFrames = rawURL.lastPathComponent
            try saveSession() // keep the link even if the app never gets to finish()
        }
        let hex = { (b: [UInt8]) in b.map { String(format: "%02X", $0) }.joined(separator: " ") }
        let line = "\(milliseconds(time)) > \(hex(request)) < \(hex(response))\n"
        try rawHandle?.write(contentsOf: Data(line.utf8))
    }

    public func finish() throws {
        try rawHandle?.synchronize()
        try handle.synchronize()
        try saveSession()
    }

    private func saveSession() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: jsonURL)
    }
}
