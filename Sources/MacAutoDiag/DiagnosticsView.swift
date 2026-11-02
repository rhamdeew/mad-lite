import AppKit
import SwiftUI
import VazCore
import VazEmu
import VazSerial

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app
    @Environment(DiagnosticsModel.self) private var diag
    @Environment(AgentServer.self) private var agent
    @AppStorage("showSensorInputs") private var showInputs = true
    /// "emulator" or a serial port path.
    @AppStorage("diagnosticsSource") private var source = "emulator"
    @State private var ports: [String] = []
    @State private var showFlashRead = CommandLine.arguments.contains("--flashread") || CommandLine.arguments.contains("--flashread-cable")
    @State private var showFlashWrite = CommandLine.arguments.contains("--flashwrite")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if let report = diag.cableReport, !diag.isActive {
                Label(report.text, systemImage: report.ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(report.ok ? .green : .orange)
                    // No .fixedSize here: in this VStack it blanks the whole tab (seen 26.10.2026).
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Divider()
            }
            if diag.state == .connected {
                RecordingBar()
                Divider()
            }
            if agent.running || agent.problem != nil {
                AgentBar()
                Divider()
            }
            if let report = diag.snapshotReport, diag.isActive {
                HStack {
                    Label(report.text, systemImage: report.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(report.ok ? .green : .orange)
                    Spacer()
                    if let file = diag.lastSnapshotFile {
                        Button("Открыть") { app.openSnapshot(file) }
                            .help("Все ответы снимка; там же — сравнение с другим снимком")
                        Button("Показать в Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                .padding(10)
                Divider()
            }
            ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let live = diag.live {
                            if !live.emergencyModes.isEmpty {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Аварийный режим").font(.headline)
                                        ForEach(live.emergencyModes, id: \.self) { Text($0) }
                                    }
                                } icon: {
                                    Image(systemName: "exclamationmark.octagon.fill")
                                }
                                .foregroundStyle(.red)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            }
                            ParameterGrid(live: live)
                            if let ext = diag.extended {
                                Text("J5LS — расширенный кадр \(String(format: "21 %02X", ext.recordID))").font(.headline)
                                ExtendedGrid(ext: ext)
                            }
                            if let inputs = diag.adcInputs {
                                InputsSection(inputs: inputs, standard: live.standard, isJ5LS: diag.extendedRecord != nil)
                            }
                            if let map = diag.adaptation {
                                // Real axes only from the very firmware the ECU runs.
                                let same = app.primary?.softwareID.map { id in diag.snapshotIdentification?.contains(id) == true } == true
                                AdaptationMapView(map: map, definition: same ? app.definition : nil,
                                                  firmware: same ? app.primary?.data : nil)
                            }
                            FlagsSection(live: live)
                            ControlSection(live: live)
                        } else {
                            ContentUnavailableView(
                                "Нет данных",
                                systemImage: "stethoscope",
                                description: Text(diag.isActive ? diag.state.title : "Нажмите «Подключить»")
                            )
                            .frame(maxWidth: .infinity, minHeight: 300)
                        }
                        DTCSection()
                    }
                    .padding()
            }
        }
        .sheet(isPresented: $showFlashRead) {
            // `--flashread` (development): the sheet on the emulator, whatever source is remembered;
            // `--flashread-cable`: the sheet for the remembered cable port (to check its layout).
            let args = CommandLine.arguments
            let emulate = source == "emulator" || (args.contains("--flashread") && !args.contains("--flashread-cable"))
            FlashReadSheet(port: emulate ? nil : source, emulatorImage: emulate ? romForEmulator : nil)
        }
        .sheet(isPresented: $showFlashWrite) {
            let emulate = source == "emulator" || CommandLine.arguments.contains("--flashwrite")
            FlashWriteSheet(port: emulate ? nil : source, emulatorImage: emulate ? romForEmulator : nil)
        }
        // Sensor sliders drive the emulator only.
        .inspector(isPresented: Binding(get: { showInputs && (source == "emulator" || diag.usesEmulator) }, set: { showInputs = $0 })) {
            EmulatorInputsPanel()
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Источник", selection: $source) {
                Label("Эмулятор ЭБУ", systemImage: "cpu").tag("emulator")
                ForEach(ports, id: \.self) { Label($0, systemImage: "cable.connector").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(diag.isActive)
            .help("Эмулятор исполняет открытую прошивку. KKL-кабель FTDI появляется в списке как /dev/cu.usbserial-…")
            .onAppear {
                ports = SerialKLineTransport.availablePorts()
                // `--cablecheck` (development): check the selected port right away.
                if CommandLine.arguments.contains("--cablecheck"), source != "emulator" { diag.checkCable(path: source) }
            }
            Button("Обновить порты", systemImage: "arrow.clockwise") { ports = SerialKLineTransport.availablePorts() }
                .labelStyle(.iconOnly)
                .disabled(diag.isActive)
            if source != "emulator", !diag.isActive {
                Button("Проверить кабель") { diag.checkCable(path: source) }
                    .fixedSize()
                    .help("Отправляет 4 байта и слушает эхо адаптера: есть ли питание 12 В и в порядке ли линия. ЭБУ эти байты игнорирует.")
            }
            if diag.isActive {
                Button("Отключить") { diag.disconnect() }.fixedSize()
            } else {
                Button("Подключить") { connect() }
                    .disabled(source == "emulator" && romForEmulator == nil)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .help("⇧⌘D")
            }
            if !diag.isActive {
                Button("Прочитать прошивку…", systemImage: "square.and.arrow.down") { showFlashRead = true }
                    .fixedSize()
                    .disabled(source == "emulator" && romForEmulator == nil)
                    .help("Чтение флеш через загрузчик процессора (+12 В на вывод 47). Только чтение: в блок ничего не пишется.")
                Button("Записать в блок…", systemImage: "square.and.arrow.up") { showFlashWrite = true }
                    .fixedSize()
                    .disabled(source == "emulator" && romForEmulator == nil)
                    .help("Запись прошивки и отвязка иммобилайзера через загрузчик. Только для запасного блока: память стирается.")
                EditionDiagnosticsActions(source: source, romForEmulator: romForEmulator)
            }
            statusText
            Spacer()
            if source == "emulator" || diag.usesEmulator {
                Toggle(isOn: $showInputs) { Label("Датчики", systemImage: "slider.horizontal.3") }
                    .toggleStyle(.button)
                    .fixedSize()
            }
            if diag.state == .connected {
                Button { diag.takeSnapshot() } label: {
                    if diag.snapshotRunning {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Снимок…") }
                    } else {
                        Label("Снимок блока", systemImage: "camera")
                    }
                }
                .fixedSize()
                .disabled(diag.snapshotRunning)
                .help("Одним проходом читает всё, что блок отдаёт: идентификацию, все кадры, коды, таблицы адаптации в ОЗУ. Только чтение, ≈5 с. Файл — в Документы/MacAutoDiag/Snapshots.")
                Text("KeyBytes \(diag.keyBytes.map { String(format: "%02X", $0) }.joined(separator: " ")) · запросов \(diag.requests)")
                    .font(.caption).monospaced().foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
    }

    @ViewBuilder private var statusText: some View {
        switch diag.state {
        case .booting, .connecting:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(diag.state.title).lineLimit(1) }
        case .connected:
            Label("Подключено к \(diag.firmwareName)", systemImage: "circle.fill").foregroundStyle(.green)
                .lineLimit(1).fixedSize()
            if let id = diag.extendedRecord {
                Text("J5LS")
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.purple.opacity(0.3), in: Capsule())
                    .help(String(format: "Распознана прошивка J5LS: расширенный кадр 21 %02X читается и пишется в лог", id))
            }
        case .reconnecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(diag.state.title).lineLimit(1).foregroundStyle(.orange)
            }
            .help(diag.state.title)
        case .failed:
            Label(diag.state.title, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .idle:
            Text(source != "emulator"
                 ? "Кабель: включите зажигание и нажмите «Подключить»"
                 : romForEmulator == nil
                 ? "Для эмулятора откройте прошивку Январь 5.1 (64 КБ)"
                 : "Прошивка для эмулятора: \(app.primary?.name ?? "")")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// The emulator runs the open image (with unsaved edits) if it is a 64 KB raw J5.1 ROM.
    private var romForEmulator: [UInt8]? {
        guard let fw = app.primary, fw.format == .raw, fw.size == 0x10000, fw.family == .january51 else { return nil }
        return Array(fw.data)
    }

    private func connect() {
        if source != "emulator" {
            diag.connectSerial(path: source)
            return
        }
        guard let rom = romForEmulator else { return }
        diag.connectEmulator(rom: rom, name: app.primary?.softwareID ?? app.primary?.name ?? "")
    }
}

/// The agent's endpoint and what it did last: the owner sees every call.
private struct AgentBar: View {
    @Environment(AgentServer.self) private var agent

    var body: some View {
        HStack(spacing: 8) {
            if let problem = agent.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                Label("Агент (MCP, только чтение): \(agent.url)", systemImage: "sparkles")
                    .textSelection(.enabled)
                Spacer()
                if let last = agent.events.first {
                    Text("\(last.tool) · \(last.time.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(last.ok ? Color.secondary : Color.orange)
                        .monospacedDigit()
                }
                Text("вызовов: \(agent.events.count)").foregroundStyle(.secondary)
                    .help(agent.events.prefix(15).map { "\($0.time.formatted(date: .omitted, time: .standard))  \($0.tool)\($0.ok ? "" : " — ошибка")" }.joined(separator: "\n"))
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Start/stop recording, markers, and access to saved logs.
private struct RecordingBar: View {
    @Environment(DiagnosticsModel.self) private var diag
    @State private var markText = ""

    var body: some View {
        HStack(spacing: 10) {
            if let log = diag.log {
                Button { diag.stopRecording() } label: {
                    Label("Стоп (⌘R)", systemImage: "stop.circle.fill").foregroundStyle(.red)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("● \(Self.duration(log.elapsedMs)) · \(log.session.rows) стр.")
                        .monospacedDigit().foregroundStyle(.red).lineLimit(1).fixedSize()
                        .help("\(log.session.channels.count) каналов → \(log.csvURL.path)")
                }
                TextField("Метка: что происходит", text: $markText)
                    .frame(maxWidth: 260)
                    .onSubmit(addMark)
                // ⌘K is in the «Диагностика» menu (works whatever has focus); ⌘M is macOS «Minimize».
                Button("Отметить (⌘K)", systemImage: "flag", action: addMark)
            } else {
                Button { diag.startRecording() } label: {
                    Label("Записать лог (⌘R)", systemImage: "record.circle")
                }
                Text(diag.extendedRecord != nil
                     ? "Будут записаны базовый кадр и расширенный кадр J5LS"
                     : "Будет записан базовый кадр 21 01")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let folder = diag.lastLogFolder {
                Button("Показать в Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                .labelStyle(.iconOnly)
                .help("Показать последний лог в Finder")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func addMark() {
        diag.mark(markText)
        markText = ""
    }

    static func duration(_ ms: Int) -> String {
        String(format: "%02d:%02d", ms / 60_000, ms / 1000 % 60)
    }
}

/// Hover text for the parameter tiles: what the value is and what to look at.
let parameterHelp: [String: String] = [
    "Обороты": "Частота вращения коленвала по датчику положения КВ. В кадре — с шагом 40 об/мин.",
    "ТОЖ": "Температура охлаждающей жидкости. При обрыве датчика ЭБУ показывает температуру по модели прогрева, а не −40.",
    "Дроссель": "Положение дроссельной заслонки по ДПДЗ, 0 % — закрыта. В аварийном режиме по ДПДЗ — подставное значение.",
    "УОЗ": "Угол опережения зажигания, градусы до ВМТ: карта УОЗ плюс поправки (температура, ХХ, детонация).",
    "Впрыск": "Время открытия форсунки за цикл, мс. Растёт с нагрузкой, на холодном двигателе и при низком напряжении.",
    "AFR": "Желаемый состав смеси из карты прошивки (воздух/топливо по массе). 14,7 — стехиометрия, меньше — богаче. Это не замер: ШДК нет.",
    "Коррекция СО": "Коррекция состава смеси потенциометром СО (прошивки Р83 без ДК).",
    "Напряжение": "Напряжение бортсети на входе ЭБУ. Норма на работающем двигателе 13,5–14,5 В.",
    "ЦН": "Цикловое наполнение — масса воздуха на один такт, мг. Основная «нагрузка» для карт УОЗ и смеси.",
    "Расход воздуха": "Массовый расход воздуха, кг/ч: по ДМРВ или посчитанный по ДАД.",
    "Обороты ХХ": "Обороты в режиме холостого хода, по которым работает регулятор ХХ.",
    "Желаемые ХХ": "Уставка холостого хода: таблица «Желаемые обороты ХХ по ТОЖ» плюс поправки.",
    "РХХ жел./тек.": "Регулятор холостого хода: желаемое и текущее положение, шаги. Около 0 или максимума — регулятор упёрся (подсос воздуха или грязный дроссель).",
    "Коэф. коррекции": "Поправка подачи топлива по датчику кислорода. 1,0 — без поправки, больше — ЭБУ добавляет топливо (смесь бедная), меньше — убирает.",
    "ДК": "Напряжение узкополосного датчика кислорода: ~0,1 В — бедно, ~0,8 В — богато. Прогретый исправный ДК переключается 1–2 раза в секунду.",
    "Скорость": "Скорость по датчику скорости автомобиля.",
    "Расход топлива": "Мгновенный расход топлива, посчитанный ЭБУ по времени впрыска.",
    "КС ПЗУ": "Контрольная сумма прошивки, которую считает сам ЭБУ (около 165 с после включения). 0000 — ещё не досчитал.",
    "Давление (ДАД)": "Абсолютное давление во впускном коллекторе. На ХХ 30–40 кПа, при полном газе — около атмосферного (~100 кПа).",
    "ДАД, напряжение": "Сырое напряжение сигнала ДАД.",
    "ДПДЗ, напряжение": "Сырое напряжение сигнала ДПДЗ: закрытая заслонка ~0,5 В, полностью открытая ~4,5 В.",
    "Ускорнасос ДЗ / ДАД": "Добавка топлива при разгоне («ускорительный насос») по скорости открытия дросселя и росту давления.",
    "Ошибка ХХ": "Отклонение оборотов ХХ от уставки.",
    "Температура воздуха": "Температура воздуха во впуске по ДТВ.",
    "AFR ШДК": "Состав смеси по широкополосному датчику, если он подключён. «—» — ШДК нет.",
    "Обороты точные": "Обороты с шагом 1 об/мин (расширенный кадр J5LS).",
    "Откат УОЗ 1/2/3/4": "Насколько ЭБУ уменьшил угол в каждом цилиндре из-за детонации.",
    "Фаза впрыска": "Угол коленвала, на котором начинается впрыск.",
    "Передача": "Включённая передача, как её определяет ЭБУ.",
    "Ошибок в памяти": "Число сохранённых кодов неисправностей.",
]

/// J5LS-only parameters.
private struct ExtendedGrid: View {
    let ext: J5LSLiveData

    var body: some View {
        let f = { (v: Double, d: Int) in String(format: "%.\(d)f", v) }
        // Last byte each value needs: older J5LS builds send a shorter record (N35 `21 0D`: 61 bytes).
        let all: [(String, String, String, Int)] = [
            ("Давление (ДАД)", f(ext.manifoldPressure, 1), "кПа", 54),
            ("ДМРВ/ДАД, напряжение", f(ext.mafOrMapVolts, 3), "В", 26),
            ("ДПДЗ, напряжение", f(ext.throttleVolts, 3), "В", 29),
            ("Ускорнасос ДЗ / ДАД", "\(f(ext.accelFuelThrottle, 1)) / \(ext.has(56) ? f(ext.accelFuelPressure, 1) : "—")", "мг/такт", 40),
            ("Ошибка ХХ", f(ext.idleRpmError, 0), "об/мин", 71),
            ("Температура воздуха", f(ext.airTemp, 0), "°C", 37),
            ("AFR ШДК", ext.widebandAFR == 0 ? "—" : f(ext.widebandAFR, 2), "", 41),
            ("Обороты точные", f(ext.preciseRPM, 0), "об/мин", 15),
            ("Откат УОЗ 1/2/3/4", ext.knockRetard.map { f($0, 1) }.joined(separator: " / "), "°", 24),
            ("Фаза впрыска", f(ext.injectionPhase, 0), "°", 19),
            ("Передача", "\(ext.gear)", "", 76),
            ("Ошибок в памяти", "\(ext.storedErrorCount)", "", 2),
        ]
        let items = all.map { name, value, unit, last in ext.has(last) ? (name, value, unit) : (name, "—", "нет в кадре") }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(items, id: \.0) { name, value, unit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value).font(.title3.monospacedDigit().weight(.semibold))
                        Text(unit).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .help(parameterHelp[name] ?? "")
            }
        }
    }
}

private struct ParameterGrid: View {
    let live: J5LiveData

    private var items: [(String, String, String)] {
        func f(_ v: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f", v) }
        func f(_ v: Double?, _ digits: Int = 0) -> String { v.map { f($0, digits) } ?? "—" }
        return [
            ("Обороты", f(live.rpm), "об/мин"),
            ("ТОЖ", f(live.coolantTemp), "°C"),
            ("Дроссель", f(live.throttle), "%"),
            ("УОЗ", f(live.ignitionAdvance, 1), "°"),
            ("Впрыск", f(live.injectionTime, 2), "мс"),
            live.standard == .euro2 ? ("AFR", f(live.afr, 2), "") : ("Коррекция СО", f(live.coCorrection, 3), ""),
            ("Напряжение", f(live.voltage, 2), "В"),
            ("ЦН", f(live.cycleAir, 1), "мг/такт"),
            ("Расход воздуха", f(live.airFlow, 1), "кг/ч"),
            ("Обороты ХХ", f(live.idleRpm), "об/мин"),
            ("Желаемые ХХ", f(live.idleRpmTarget), "об/мин"),
            ("РХХ жел./тек.", "\(live.iacDesired) / \(live.iacActual)", "шаг"),
            ("Коэф. коррекции", f(live.injectionCorrection, 3), ""),
            ("ДК", f(live.lambdaVoltage, 3), live.standard == .euro2 ? "В" : "нет в Р83"),
            ("Скорость", f(live.speed), "км/ч"),
            ("Расход топлива", f(live.fuelPerHour, 2), "л/ч"),
            ("КС ПЗУ", live.romChecksum == 0xFFFF ? "—" : String(format: "%04X", live.romChecksum),
             live.romChecksum == 0 ? "считается ~165 с" : live.romChecksum == 0xFFFF ? "не передаёт (J5LS)" : ""),
        ]
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(items, id: \.0) { name, value, unit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value).font(.title2.monospacedDigit().weight(.semibold))
                        Text(unit).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .help(parameterHelp[name] ?? "")
            }
        }
    }
}

/// `21 03`: voltages at the ECU pins and raw port bytes — for checking a sensor circuit.
private struct InputsSection: View {
    let inputs: J5Inputs
    let standard: J5LiveData.Standard
    /// J5LS: the load sensor may be a MAP sensor, on pin 7 or on pin 40 (not in this frame).
    var isJ5LS = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Напряжения на входах ЭБУ").font(.headline)
                Text("кадр 21 03: раз в секунду, на работающем моторе реже").font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                row("ДПДЗ", inputs.throttleVolts, inputs.throttleCode, "Вывод 53. Закрытая заслонка — около 0,5 В, полностью открытая — около 4,5 В.")
                if isJ5LS {
                    row("Вывод 7 (ДМРВ / ДАД)", inputs.mafVolts, inputs.mafCode, "Вход ДМРВ. У J5LS сюда может быть подключён ДАД; если ДАД на выводе 40, здесь около 0 В — это нормально, напряжение ДАД смотрите в расширенном кадре («ДАД, напряжение»).")
                } else {
                    row("ДМРВ", inputs.mafVolts, inputs.mafCode, "Вывод 7. Без потока воздуха — около 1 В. Расход по этому коду считается по таблице ДМРВ прошивки.")
                }
                row("ДТОЖ", inputs.coolantVolts, inputs.coolantCode, "Вывод 45. Чем горячее, тем ниже: 20 °C — около 3 В, 90 °C — около 0,5 В.")
                row("Бортсеть", inputs.supplyVolts, inputs.supplyCode, "Пересчёт самой прошивки (как в напряжении кадра 21 01).")
                row(standard == .euro2 ? "Датчик кислорода" : "Потенциометр СО (вывод 44)",
                    inputs.fifthVolts(standard), inputs.fifthCode,
                    standard == .euro2 ? "Вывод 28. Прогретый датчик колеблется 0,1–0,9 В." : "Регулировка СО на прошивках без ДК.")
                row("Датчик детонации", inputs.knockVolts, inputs.knockCode, "Канал детонации (выход интегратора).")
            }
            HStack(spacing: 16) {
                port("P1", inputs.port1)
                port("P5", inputs.port5)
                port("P6", inputs.port6)
                port("P8", inputs.port8)
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private func row(_ name: String, _ volts: Double, _ code: UInt8, _ help: String) -> some View {
        GridRow {
            Text(name)
            Text(String(format: "%.2f В", volts)).monospacedDigit().fontWeight(.semibold)
            Text("код \(code)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .help(help)
    }

    private func port(_ name: String, _ value: UInt8) -> some View {
        let bits = String(value, radix: 2)
        return Text("\(name) \(String(repeating: "0", count: 8 - bits.count) + bits)")
            .help("Копия порта \(name) в ОЗУ ЭБУ, старший бит слева.\n" + J5Inputs.portNotes)
    }
}

/// Service 30: hand control of a few outputs and the idle targets — behind an explicit consent.
/// Cylinder cut-out (injectors / ignition) is left out on purpose for now.
private struct ControlSection: View {
    @Environment(DiagnosticsModel.self) private var diag
    let live: J5LiveData
    // `--control` (development, screenshots): open and allowed from the start.
    @State private var expanded = CommandLine.arguments.contains("--control")
    @State private var askConsent = false
    @State private var idleRPM = 900.0
    @State private var iacSteps = 40.0

    private var engineRunning: Bool { live.rpm > 0 }

    var body: some View {
        @Bindable var diag = diag
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if !diag.controlEnabled {
                    Text("Программа будет сама включать и выключать реле и задавать обороты ХХ вместо ЭБУ. Пока управление у программы, ЭБУ этими устройствами не управляет. По документации АВТОВАЗа после проверки управление нужно вернуть ЭБУ — программа делает это сама при отключении и после обрыва связи, а также по кнопке «Вернуть управление».")
                        .frame(maxWidth: 640, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Button("Разрешить ручное управление…") { askConsent = true }
                } else {
                    support
                    relays
                    idle
                    if !diag.controlled.isEmpty {
                        Button {
                            diag.returnAllControl()
                        } label: {
                            Label("Вернуть управление ЭБУ (\(diag.controlled.count))", systemImage: "arrow.uturn.backward.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                    events
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(diag.state != .connected)
        } label: {
            HStack {
                Text("Управление исполнительными механизмами").font(.headline)
                if !diag.controlled.isEmpty {
                    Text("управление у программы").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .confirmationDialog("Разрешить ручное управление на этот сеанс?", isPresented: $askConsent) {
            Button("Разрешить") { diag.controlEnabled = true }
        } message: {
            Text("Проверяйте на стоящей машине, на нейтрали, со включённым ручником. Не оставляйте бензонасос включённым при заглушённом двигателе дольше нескольких секунд. Если что-то пошло не так — «Вернуть управление» или «Отключить».")
        }
    }

    private var support: some View {
        HStack(spacing: 10) {
            Button("Проверить поддержку") { diag.checkControlSupport() }
                .help("Безопасная проверка: лампа Check Engine загорится на 1,5 с, потом управление вернётся ЭБУ. Если блок ответит отказом, ручное управление в этой прошивке недоступно.")
            switch diag.controlSupported {
            case .some(true): Label("Блок принимает команды", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .some(false): Label("Блок не поддерживает ручное управление", systemImage: "xmark.circle").foregroundStyle(.orange)
            case .none: Text("лампа Check Engine мигнёт на 1,5 с").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var relays: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Реле и лампа").font(.subheadline.bold())
            Text("Включите — прислушайтесь: реле щёлкает, насос гудит, вентилятор крутится. Нет реакции — проверьте реле, предохранитель и провод от ЭБУ.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 640, alignment: .leading)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach([ActuatorCommand.Output.fuelPump, .fan, .checkEngine, .airConditioner], id: \.self) { output in
                    GridRow {
                        Text(output.title)
                        Button("Вкл") { diag.control(.output(output, on: true)) }
                        Button("Выкл") { diag.control(.output(output, on: false)) }
                        Button("Вернуть ЭБУ") { diag.control(.returnControl(output.rawValue)) }
                            .disabled(!diag.controlled.contains(output.rawValue))
                        if diag.controlled.contains(output.rawValue) {
                            Image(systemName: "hand.raised.fill").foregroundStyle(.orange).help("Сейчас управляет программа")
                        }
                    }
                }
            }
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Холостой ход").font(.subheadline.bold())
            Text("На прогретом двигателе на ХХ. Задайте обороты и смотрите, держит ли их блок и куда идёт РХХ: если РХХ уходит к нулю, а обороты выше заданных — лишний воздух (подсос, заслонка не закрывается); если РХХ открыт много, а оборотов не хватает — мало воздуха (грязный канал ХХ, РХХ).")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 640, alignment: .leading)
            HStack {
                Text("Обороты ХХ").frame(width: 120, alignment: .leading)
                Slider(value: $idleRPM, in: 600...1500, step: 50).frame(width: 220)
                Text("\(Int(idleRPM)) об/мин").monospacedDigit().frame(width: 90, alignment: .leading)
                Button("Задать") { diag.control(.idleRPM(Int(idleRPM))) }
                Button("Вернуть ЭБУ") { diag.control(.returnControl(ActuatorCommand.idleRPMID)) }
                    .disabled(!diag.controlled.contains(ActuatorCommand.idleRPMID))
            }
            .disabled(!engineRunning)
            HStack {
                Text("Положение РХХ").frame(width: 120, alignment: .leading)
                Slider(value: $iacSteps, in: 10...150, step: 5).frame(width: 220)
                Text("\(Int(iacSteps)) шагов").monospacedDigit().frame(width: 90, alignment: .leading)
                Button("Задать") { diag.control(.iacPosition(Int(iacSteps))) }
                Button("Вернуть ЭБУ") { diag.control(.returnControl(ActuatorCommand.iacPositionID)) }
                    .disabled(!diag.controlled.contains(ActuatorCommand.iacPositionID))
            }
            .disabled(!engineRunning)
            Text("Сейчас: \(Int(live.rpm)) об/мин, желаемые ХХ \(Int(live.idleRpmTarget)), РХХ \(live.iacActual) (желаемое \(live.iacDesired)) шагов"
                 + (engineRunning ? "" : " — двигатель не работает, команды ХХ недоступны"))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(diag.controlEvents.prefix(8)) { e in
                Label(e.text, systemImage: e.ok ? "checkmark" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(e.ok ? Color.secondary : Color.orange)
            }
        }
    }
}

private struct FlagsSection: View {
    let live: J5LiveData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Режим", live.mode1.active + live.mode2.active)
            row("Текущие неисправности", live.activeFaults, warning: true)
            row("Комплектация", live.configuration1.active + live.configuration2.active)
            if let lambda = live.lambdaFlags { row("Датчик кислорода", lambda.active) }
        }
    }

    private func row(_ title: String, _ items: [String], warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if items.isEmpty {
                Text("—").foregroundStyle(.secondary)
            } else {
                FlowText(items: items, tint: warning ? .orange : .accentColor)
            }
        }
    }
}

/// Wrapping row of capsule labels.
private struct FlowText: View {
    let items: [String]
    let tint: Color

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(tint.opacity(0.18), in: Capsule())
            }
        }
    }
}

private struct DTCSection: View {
    @Environment(DiagnosticsModel.self) private var diag
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Коды неисправностей").font(.headline)
                Text("сохранённые в ЭБУ, обновляются каждые 5 с, на работающем моторе — 10 с").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Прочитать") { diag.readDTCs() }
                Button("Сбросить", role: .destructive) { confirmClear = true }
            }
            .disabled(diag.state != .connected)
            .confirmationDialog("Сбросить коды неисправностей в ЭБУ?", isPresented: $confirmClear) {
                Button("Сбросить", role: .destructive) { diag.clearDTCs() }
            } message: {
                Text("Коды сотрутся из памяти ЭБУ. Это не чинит неисправность: если причина осталась, код появится снова. Перед сбросом их стоит записать — при записи лога они уже сохранены в нём.")
            }
            if let dtcs = diag.dtcs {
                if dtcs.isEmpty {
                    Text("Ошибок нет").foregroundStyle(.secondary)
                }
                ForEach(dtcs) { dtc in
                    HStack(alignment: .firstTextBaseline) {
                        Text(dtc.code).monospaced().fontWeight(.semibold)
                        Text(dtc.description)
                        Spacer()
                        if dtc.lampOn {
                            Label("Check Engine", systemImage: "engine.combustion.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text(String(format: "%02X", dtc.status)).font(.caption).monospaced().foregroundStyle(.secondary)
                            .help("Байт статуса кода из ответа ЭБУ. Бит 7 (80) — код зажигает лампу Check Engine (наблюдение в эмуляторе, по стандарту ISO 14230-3). Остальные биты не расшифрованы.")
                    }
                }
            }
        }
    }
}

/// Sliders driving the emulator's sensor inputs.
private struct EmulatorInputsPanel: View {
    @Environment(DiagnosticsModel.self) private var diag

    var body: some View {
        @Bindable var diag = diag
        Form {
            Section("Двигатель (эмулятор)") {
                slider("Обороты", $diag.inputs.rpm, 0...7000, "%.0f об/мин", step: 50)
            }
            Section("Нагрузка (эмулятор)") {
                Picker("Датчик нагрузки", selection: $diag.inputs.usesMAP) {
                    Text("ДМРВ").tag(false)
                    Text("ДАД + ДТВ").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let wiring = diag.wiring {
                    Text(wiring.usesMAP == diag.inputs.usesMAP
                         ? wiringNote(wiring)
                         : "Переключено вручную (по флагам прошивки — \(wiring.usesMAP ? "ДАД" : "ДМРВ")).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if diag.inputs.usesMAP {
                    slider("ДАД", $diag.inputs.mapVolts, 0...5, "%.2f В")
                    slider("Температура воздуха", $diag.inputs.airTemp, -30...80, "%.0f °C")
                } else {
                    slider("ДМРВ", $diag.inputs.mafVolts, 0...5, "%.2f В")
                }
            }
            Section("Датчики (эмулятор)") {
                slider("ТОЖ", $diag.inputs.coolant, -30...120, "%.0f °C")
                slider("ДПДЗ", $diag.inputs.throttleVolts, 0...5, "%.2f В")
                slider("Бортовое напряжение", $diag.inputs.supplyVolts, 8...16, "%.1f В")
                slider("ДК", $diag.inputs.lambdaVolts, 0...1, "%.2f В")
            }
            if let image = diag.driverImage {
                Section("Выходы драйвера (эмулятор)") {
                    // Bits of F999 confirmed in the emulator, docs/emulator.md «Драйвер выходов».
                    ForEach([(6, "Бензонасос"), (1, "Вентилятор"), (4, "Лампа Check Engine"), (0, "Кондиционер")], id: \.0) { bit, name in
                        Label(name, systemImage: image & 1 << bit != 0 ? "circle.fill" : "circle")
                            .foregroundStyle(image & 1 << bit != 0 ? Color.green : Color.secondary)
                    }
                }
            }
            Section {
                Text(diag.inputs.rpm > 0
                    ? "Эмулятор подаёт сигнал ДПКВ 60-2: прошивка сама считает впрыск и УОЗ. Нагрузку задаёт \(diag.inputs.usesMAP ? "ДАД" : "ДМРВ"). Показания фильтруются прошивкой и меняются не мгновенно. Ток нагревателя ДК подаётся «исправный»; датчика фазы нет (P0340 ожидаема)."
                    : "Обороты 0 — двигатель стоит. Показания фильтруются прошивкой и меняются не мгновенно. Ток нагревателя ДК подаётся «исправный»; датчика фазы нет (P0340 ожидаема).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func wiringNote(_ w: Sensors.Wiring) -> String {
        guard w.isJ5LS else { return "Серийная прошивка: нагрузка по ДМРВ." }
        var s = w.usesMAP
            ? "По флагам прошивки: ДАД (вывод \(w.mapChannel == Sensors.mapChannel ? "40" : "7"))."
            : "По флагам прошивки: ДМРВ (флаг «работать без ДМРВ» сброшен)."
        s += w.hasAirTemp ? " ДТВ включён в комплектации." : " ДТВ в комплектации выключен — прошивка его не читает (−40 °C)."
        return s
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ format: String,
                        step: Double? = nil) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
        }
    }
}
