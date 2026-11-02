import Foundation
import VazCore
import VazSerial

/// What the agent may do through MCP. Level 1 — reading only: every value comes from the
/// regular poll loop (the agent never puts its own requests on the K-line), files go to
/// Documents/MacAutoDiag. Writing to the ECU, clearing codes and manual control are not here:
/// they need the owner's confirmation in the window (next level, docs/agent.md).
@MainActor final class AgentTools {
    let app: AppModel
    let diag: DiagnosticsModel
    let loaderLog: LoaderLog
    static let iso8601 = ISO8601DateFormatter()

    init(app: AppModel, diag: DiagnosticsModel, loaderLog: LoaderLog) {
        self.app = app
        self.diag = diag
        self.loaderLog = loaderLog
    }

    static let instructions = """
    \(Edition.name) — диагностика ЭБУ ВАЗ Январь 5.1 (в т. ч. J5LS) по K-line через KKL-кабель или на эмуляторе с настоящей прошивкой.
    Доступ только на чтение: ЭБУ ничего не записывается, коды не сбрасываются, исполнительными механизмами агент не управляет.
    Все значения уже расшифрованы (единицы в ответе). Поля, которых нет в кадре этого блока, не приходят — это не ноль.
    Опрос идёт ≈5 раз в секунду; агент читает последний кадр (read_live) или сводку за отрезок времени (sample), а не поток.
    Обычный порядок: status → connect → check_parked (зажигание вкл., мотор заглушен) → take_snapshot → read_dtcs → sample при нужном режиме.
    Пользователь видит в окне приложения каждый вызов. Просьбы к водителю (завести, нажать педаль) передавайте человеку — сами вы на машину не влияете.
    Прошивка блока (чтение/запись флеш и EEPROM, отвязка иммо) запускается человеком кнопками в окне — агент её не начинает. За ходом следите через flash_status (операция, шаг, прогресс, события) и подсказывайте: можно шиться «вместе», человек нажимает — вы наблюдаете и предупреждаете. Запись и вход в режим программирования (+12 В на вывод 47) — только на запасном блоке.
    """

    static let tools: [MCPTool] = [
        MCPTool(name: "status", description: "Состояние связи: источник (кабель/эмулятор), подключено ли, J5LS ли блок, идёт ли запись лога, открытая прошивка, доступные порты."),
        MCPTool(name: "list_ports", description: "Последовательные порты (KKL-кабель FTDI — /dev/cu.usbserial-…)."),
        MCPTool(name: "check_cable", description: "Проверка KKL-кабеля по эху адаптера (4 байта, ЭБУ их игнорирует): есть ли 12 В на колодке и цела ли линия. Только когда сеанс не идёт.",
                properties: ["port": ["type": "string", "description": "Путь порта; по умолчанию — единственный /dev/cu.usbserial-…"]]),
        MCPTool(name: "connect", description: "Подключиться к ЭБУ и начать опрос. source: путь порта кабеля, \"cable\" (единственный usbserial-порт) или \"emulator\" (открытая в приложении прошивка J5.1 64 КБ). Ждёт до 30 с.",
                properties: ["source": ["type": "string"]], required: ["source"]),
        MCPTool(name: "disconnect", description: "Завершить сеанс (останавливает запись лога, возвращает ЭБУ всё, что было под ручным управлением)."),
        MCPTool(name: "read_live", description: "Последний кадр: обороты, ТОЖ, дроссель, УОЗ, впрыск, наполнение, ДК, флаги режимов; у J5LS — давление ДАД, ТВ, напряжения датчиков, откат по детонации; текущие неисправности и аварийные режимы; напряжения на входах ЭБУ (21 03), если блок их отдаёт."),
        MCPTool(name: "read_dtcs", description: "Сохранённые коды неисправностей с расшифровкой (блок перечитывает их каждые 5 с) и когда они прочитаны."),
        MCPTool(name: "sample", description: "Сводка за seconds секунд (1–120): min/max/среднее/последнее по каждому параметру, неисправности и аварийные режимы, замеченные за это время. Для оценки режима: ХХ, прогрев, газ на месте, поездка.",
                properties: ["seconds": ["type": "number", "minimum": 1, "maximum": 120],
                             "channels": ["type": "array", "items": ["type": "string"], "description": "id параметров (как в read_live); по умолчанию все"]],
                required: ["seconds"]),
        MCPTool(name: "check_parked", description: "Проверка датчиков на стоянке: зажигание включено, мотор ЗАГЛУШЕН, педаль отпущена. Бортсеть, ДТОЖ, ДТВ, ДПДЗ, ДАД против атмосферы; с характеристикой ДАД — сверяет её с прошивкой. Каждый пункт: норма / отклонение / нет данных и подсказка.",
                properties: ["seconds": ["type": "number", "minimum": 1, "maximum": 30, "description": "по умолчанию 3"],
                             "map_sensor": ["type": "string", "enum": ["map_20_300kpa", "gaz_45.3829"], "description": "известный датчик ДАД: map_20_300kpa — 20–300 кПа, Bosch 0 281 002 996 и аналоги"],
                             "map_slope_kpa_per_v": ["type": "number", "description": "наклон характеристики ДАД, кПа/В (форма J5LS: P = (U + смещение)·наклон)"],
                             "map_offset_v": ["type": "number", "description": "смещение характеристики ДАД, В"]]),
        MCPTool(name: "take_snapshot", description: "«Снимок блока»: одним проходом (≈5 с, только чтение) все ответы ЭБУ — идентификация, кадры, коды, таблица обучения смеси — в JSON-файл. Возвращает путь, число ответов и вывод по обучению смеси."),
        MCPTool(name: "start_log", description: "Начать запись лога (Документы/\(Edition.dataFolder)/Logs/<дата>_…): CSV всех параметров, сырые кадры, коды."),
        MCPTool(name: "stop_log", description: "Остановить запись лога."),
        MCPTool(name: "mark", description: "Метка в лог с текстом (что сейчас происходит: «газ до 3000», «выстрел во впуск»).",
                properties: ["text": ["type": "string"]], required: ["text"]),
        MCPTool(name: "flash_status", description: "Состояние работы с загрузчиком (чтение/запись флеш и EEPROM, отвязка иммо): текущая операция, шаг, прогресс и последние события. Запуск — только человеком из окна приложения; агент наблюдает и советует.",
                properties: ["events": ["type": "number", "minimum": 1, "maximum": 100, "description": "сколько последних событий вернуть (по умолчанию 20)"]]),
    ]

    func call(_ name: String, _ a: [String: JSONValue]) async -> MCPToolResult {
        do {
            switch name {
            case "status": return .ok(status())
            case "list_ports": return .ok(["ports": .array(SerialKLineTransport.availablePorts().map { .string($0) })])
            case "check_cable": return try await checkCable(a["port"]?.stringValue)
            case "connect": return try await connect(a["source"]?.stringValue ?? "")
            case "disconnect":
                diag.disconnect()
                return .ok(["state": .string(diag.state.title)])
            case "read_live": return readLive()
            case "read_dtcs": return readDTCs()
            case "sample": return try await sample(a)
            case "check_parked": return try await checkParked(a)
            case "take_snapshot": return try await snapshot()
            case "start_log":
                guard diag.state == .connected else { return notConnected }
                diag.startRecording()
                return .ok(["recording": .bool(diag.log != nil), "folder": .string(diag.lastLogFolder?.path ?? "")])
            case "stop_log":
                diag.stopRecording()
                return .ok(["recording": false, "folder": .string(diag.lastLogFolder?.path ?? "")])
            case "flash_status": return flashStatus(Int(a["events"]?.doubleValue ?? 20))
        case "mark":
                guard diag.log != nil else { return .failure("Лог не пишется: сначала start_log.") }
                diag.mark("агент: " + (a["text"]?.stringValue ?? ""))
                return .ok(["marked": true])
            default: return .failure("Нет такого инструмента")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private var notConnected: MCPToolResult { .failure("Нет связи с ЭБУ (\(diag.state.title)). Сначала connect.") }

    private func status() -> JSONValue {
        [
            "state": .string(diag.state.title),
            "connected": .bool(diag.state == .connected),
            "source": diag.isActive ? .string(diag.usesEmulator ? "эмулятор" : "кабель") : .null,
            "session": .string(diag.firmwareName),
            "key_bytes": .string(DiagnosticsModel.hex(diag.keyBytes)),
            "j5ls_extended_record": diag.extendedRecord.map { .string(String(format: "21 %02X", $0)) } ?? .null,
            "recording": .bool(diag.log != nil),
            "log_folder": diag.log != nil ? .string(diag.lastLogFolder?.path ?? "") : .null,
            "requests": .int(diag.requests),
            "open_firmware": app.primary.map { .string($0.softwareID ?? $0.name) } ?? .null,
            "emulator_available": .bool(emulatorROM != nil),
            "ports": .array(SerialKLineTransport.availablePorts().map { .string($0) }),
            "access": "только чтение",
        ]
    }

    /// Loader progress for live monitoring: the user runs read/write/EEPROM from the window,
    /// the agent watches and advises. Read-only — the agent cannot start or write anything.
    private func flashStatus(_ count: Int) -> MCPToolResult {
        let events = loaderLog.recent(min(max(count, 1), 100)).map { e -> JSONValue in
            var o: [String: JSONValue] = [
                "time": .string(Self.iso8601.string(from: e.time)),
                "phase": .string(e.phase),
                "message": .string(e.message),
            ]
            if let d = e.done, let t = e.total { o["progress"] = .string("\(d) / \(t)") }
            return .object(o)
        }
        return .ok([
            "operation": loaderLog.operation.map { .string($0) } ?? .null,
            "current": loaderLog.current.map { .string($0) } ?? .null,
            "progress": loaderLog.progress.map { .string("\($0.done) / \($0.total)") } ?? .null,
            "last_file": loaderLog.lastFile.map { .string($0.path) } ?? .null,
            "events": .array(events),
        ])
    }

    /// The emulator runs the open image if it is a 64 KB raw J5.1 ROM (as the «Подключить» button).
    private var emulatorROM: [UInt8]? {
        guard let fw = app.primary, fw.format == .raw, fw.size == 0x10000, fw.family == .january51 else { return nil }
        return Array(fw.data)
    }

    private func cablePort(_ given: String?) throws -> String {
        if let given, given != "cable", !given.isEmpty { return given }
        let ports = SerialKLineTransport.availablePorts().filter { $0.contains("usbserial") }
        guard ports.count == 1 else {
            throw AgentError(ports.isEmpty ? "KKL-кабель не найден: нет порта /dev/cu.usbserial-…. Вставьте кабель в USB."
                                           : "Несколько кабелей: \(ports.joined(separator: ", ")). Укажите порт.")
        }
        return ports[0]
    }

    private func checkCable(_ port: String?) async throws -> MCPToolResult {
        guard !diag.isActive else { return .failure("Идёт сеанс: проверка кабеля — только без подключения.") }
        diag.checkCable(path: try cablePort(port))
        guard await wait(seconds: 5, until: { self.diag.cableReport != nil }), let r = diag.cableReport else {
            return .failure("Кабель не ответил за 5 с.")
        }
        return .ok(["ok": .bool(r.ok), "report": .string(r.text)])
    }

    private func connect(_ source: String) async throws -> MCPToolResult {
        guard !diag.isActive else { return .ok(["state": .string(diag.state.title), "note": "Уже подключено."]) }
        app.mode = .diagnostics
        if source == "emulator" {
            guard let rom = emulatorROM else {
                return .failure("Для эмулятора откройте в приложении прошивку Январь 5.1 (64 КБ).")
            }
            diag.connectEmulator(rom: rom, name: app.primary?.softwareID ?? app.primary?.name ?? "")
        } else {
            diag.connectSerial(path: try cablePort(source))
        }
        _ = await wait(seconds: 30) {
            switch self.diag.state { case .connected, .failed, .idle: true; default: false }
        }
        guard diag.state == .connected else {
            return .failure("Не подключилось: \(diag.state.title). Зажигание включено? Подождите 3–5 с после включения (иммобилизация) и повторите.")
        }
        // The first frames arrive right after the session starts.
        _ = await wait(seconds: 3) { self.diag.live != nil }
        return .ok(status())
    }

    private func readLive() -> MCPToolResult {
        guard diag.state == .connected, let live = diag.live else { return notConnected }
        let ext = diag.extended
        var out: [String: JSONValue] = [
            "values": channelValues(LogSchema.channels(extended: ext != nil), LogSchema.values(base: live, extended: ext)),
            "active_faults": .array(live.activeFaults.map { .string($0) }),
            "emergency_modes": .array(live.emergencyModes.map { .string($0) }),
            "mode_flags": .array((live.mode1.active + live.mode2.active).map { .string($0) }),
            // With the engine running 21 01 values (advance, AFR, flags) can be up to 0.5 s old.
            "poll_plan": .string(diag.pollPlan.description),
        ]
        if let i = diag.adcInputs {
            out["ecu_inputs_21_03"] = [
                "coolant_v": .measured(i.coolantVolts, digits: 3), "throttle_v": .measured(i.throttleVolts, digits: 3),
                "maf_or_map_v": .measured(i.mafVolts, digits: 3), "supply_v": .measured(i.supplyVolts, digits: 2),
                "knock_v": .measured(i.knockVolts, digits: 3),
            ]
        }
        return .ok(.object(out))
    }

    private func readDTCs() -> MCPToolResult {
        guard diag.state == .connected, let dtcs = diag.dtcs else { return notConnected }
        let codes: [JSONValue] = dtcs.map {
            ["code": .string($0.code), "description": .string($0.description),
             "status": .string(String(format: "%02X", $0.status)), "lamp_on": .bool($0.lampOn)]
        }
        let age = diag.dtcsReadAt.map { Date().timeIntervalSince($0) } ?? 0
        return .ok(["codes": .array(codes), "read_seconds_ago": .measured(age, digits: 0)])
    }

    private func sample(_ a: [String: JSONValue]) async throws -> MCPToolResult {
        guard diag.state == .connected else { return notConnected }
        let seconds = min(max(a["seconds"]?.doubleValue ?? 5, 1), 120)
        let only: [String] = if case .array(let ids) = a["channels"] ?? .null { ids.compactMap(\.stringValue) } else { [] }
        let stats = try await diag.sample(seconds: seconds)
        guard stats.rows > 0 else { return .failure("За \(Int(seconds)) с не пришло ни одного кадра: \(diag.state.title).") }
        return .ok(stats.json(only: only))
    }

    private func checkParked(_ a: [String: JSONValue]) async throws -> MCPToolResult {
        guard diag.state == .connected else { return notConnected }
        var map: MAPCharacteristic? = switch a["map_sensor"]?.stringValue {
        case "map_20_300kpa": .range20to300kPa
        case "gaz_45.3829": .gaz453829
        default: nil
        }
        if let slope = a["map_slope_kpa_per_v"]?.doubleValue {
            map = MAPCharacteristic(slope: slope, offset: a["map_offset_v"]?.doubleValue ?? 0)
        }
        let stats = try await diag.sample(seconds: min(max(a["seconds"]?.doubleValue ?? 3, 1), 30))
        guard stats.rows > 0 else { return .failure("Кадры не пришли: \(diag.state.title).") }
        let findings = ParkedCheck.run(stats, map: map)
        let deviations = findings.filter { $0.verdict == .deviation }.count
        return .ok([
            "summary": .string(deviations == 0 ? "Отклонений нет" : "Отклонений: \(deviations)"),
            "findings": .array(findings.map(\.json)),
        ])
    }

    private func snapshot() async throws -> MCPToolResult {
        guard diag.state == .connected else { return notConnected }
        try await diag.takeSnapshotAndWait()
        guard let report = diag.snapshotReport else { return .failure("Снимок не завершился за 60 с.") }
        var out: [String: JSONValue] = ["ok": .bool(report.ok), "report": .string(report.text),
                                        "file": .string(diag.lastSnapshotFile?.path ?? "")]
        if let id = diag.snapshotIdentification { out["identification"] = .string(id) }
        if let map = diag.adaptation {
            let s = map.summary()
            out["mixture_learning"] = [
                "verdict": .string(map.verdict), "cells_changed": .int(s.changed),
                "mean": .measured(s.mean, digits: 3), "min": .measured(s.min, digits: 3), "max": .measured(s.max, digits: 3),
                "cells_at_limit": .int(s.atLimit),
            ]
        }
        return .ok(.object(out))
    }

    private func wait(seconds: Double, until done: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !done() {
            guard ContinuousClock.now < end else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}

struct AgentError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
