import AppKit
import SwiftUI
import VazCore
import VazEmu
import VazSerial

/// Reads the 64 KB flash window of a Январь 5.1 through the C509 bootstrap loader
/// (`docs/flashing.md`): sync, read-only agent into XRAM, flash ID, image to a file.
/// Nothing is written to the ECU.
@MainActor @Observable
final class FlashReadModel {
    enum Stage: Equatable {
        /// `waiting(echo:)`: sending 00h until the block powers up; `echo` false = the cable
        /// does not hear its own bytes (no 12 V on the OBD socket).
        case idle, waiting(echo: Bool), loading, reading(Int), done, failed(String)

        var title: String {
            switch self {
            case .idle: "Готово к чтению"
            case .waiting(let echo): echo ? "Жду блок — включите питание блока. Если он уже включён — выключите и включите снова: загрузчик отвечает только сразу после включения." : "Кабель не слышит себя: нет 12 В на колодке OBD (выводы 16 и 4/5)?"
            case .loading: "Загрузка агента чтения в XRAM…"
            case .reading(let n): "Чтение флеш: \(n / 1024) из 64 КБ…"
            case .done: "Прочитано"
            case .failed(let message): "Ошибка: \(message)"
            }
        }
    }

    struct Result {
        let file: URL
        let flashID: (UInt8, UInt8)
        let softwareID: String?
        /// Every byte FFh — an erased half.
        let empty: Bool
        let checksum: Checksum.Status?
        /// Bootstrap info block (`23 03 33 13`) found at this address: a non-standard
        /// custom loader / read-lock marker. nil = none.
        let infoBlock: UInt16?
    }

    /// What to read: the flash (firmware) or the serial EEPROM (24C04: immobilizer, adaptations).
    enum Target: String, CaseIterable, Identifiable {
        case flash = "Прошивка (64 КБ)"
        /// The other 64 KB of the 128 KB chip (P6.0 = 0): dual-mode firmware or leftovers.
        case otherHalf = "Вторая половина флеш"
        case eeprom = "EEPROM (512 Б)"
        var id: Self { self }
        var size: Int { self == .eeprom ? 512 : 0x10000 }
    }

    struct EEPROMResult {
        let file: URL
        let bytes: [UInt8]
        let trained: Bool
    }

    var target = Target.flash
    private(set) var eepromResult: EEPROMResult?

    /// Bootstrap loader baud rate: the C509 adapts to it (guaranteed up to ≈12800 at 16 MHz).
    static let baud = 9600

    private(set) var stage = Stage.idle
    private(set) var result: Result?
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch stage {
        case .waiting, .loading, .reading: true
        default: false
        }
    }

    static var directory: URL { DiagnosticsModel.dataDirectory.appendingPathComponent("Flash", isDirectory: true) }

    /// `emulatorImage` runs the read against the bootstrap model instead of a cable.
    func start(port: String?, emulatorImage: [UInt8]?, log: LoaderLog? = nil) {
        guard !isRunning else { return }
        result = nil
        eepromResult = nil
        let target = target
        stage = .waiting(echo: true)
        task = Task {
            var trace: TracingTransport?
            log?.begin(target == .flash ? "Чтение прошивки" : target == .otherHalf ? "Чтение второй половины флеш" : "Чтение EEPROM", source: emulatorImage != nil ? "эмулятор" : (port ?? "кабель"))
            do {
                let transport: any KLineTransport = if let emulatorImage {
                    BootstrapEmulatorTransport(image: emulatorImage)
                } else {
                    try SerialKLineTransport(path: port ?? "", baud: Self.baud, stopBits: 2)
                }
                let traced = TracingTransport(transport)
                trace = traced
                let loader = BootstrapClient(transport: traced)
                log?.event("sync", "Жду загрузчик: 00 каждые 0,2 с, до 60 с")
                try await loader.waitForLoader { n, echo in
                    Task { @MainActor in
                        // A few silent tries at the start are normal (port settling).
                        if case .waiting = self.stage { self.stage = .waiting(echo: echo || n < 5) }
                    }
                }
                log?.event("sync", "Загрузчик ответил 55")
                stage = .loading
                if target == .eeprom {
                    log?.event("agent", "Загрузка агента EEPROM")
                    try await loader.startEEPROMAgent()
                    stage = .reading(0)
                    let bytes = try await loader.readEEPROM(size: 512) { n in Task { @MainActor in self.stage = .reading(n); log?.event("eeprom", "Чтение EEPROM", done: n, total: 512) } }
                    let file = try saveEEPROM(bytes, emulated: emulatorImage != nil)
                    eepromResult = EEPROMResult(file: file, bytes: bytes, trained: Immobilizer.isTrained(eeprom: bytes))
                    stage = .done
                    log?.end(ok: true, "Прочитано 512 Б → \(file.lastPathComponent) · иммобилайзер \(eepromResult!.trained ? "обучен" : "не обучен")")
                    return
                }
                log?.event("agent", "Загрузка агента чтения")
                try await loader.startReadAgent()
                let id = try await loader.flashID()
                log?.event("id", "Флеш: \(String(format: "%02X %02X", id.manufacturer, id.device))\(id == (0x01, 0x20) ? " (AMD Am29F010)" : "")")
                if target == .otherHalf {
                    try await loader.selectFlashHalf(defaultHalf: false)
                    log?.event("bank", "P6.0 = 0: вторая половина флеш (A16 переключён)")
                }
                stage = .reading(0)
                let image = try await loader.readFlash { n in Task { @MainActor in self.stage = .reading(n); if n % 0x2000 == 0 || n == 0x10000 { log?.event("read", "Чтение флеш", done: n, total: 0x10000) } } }
                if target == .otherHalf { try await loader.selectFlashHalf(defaultHalf: true) }
                result = try save(image, flashID: (id.manufacturer, id.device), emulated: emulatorImage != nil, otherHalf: target == .otherHalf)
                stage = .done
                log?.end(ok: true, "Прочитано 64 КБ → \(result?.file.lastPathComponent ?? "")\(result?.infoBlock != nil ? " · внимание: инфо-блок (возможна защита)" : "")")
            } catch is CancellationError {
                stage = .idle
                log?.end(ok: false, "Отменено")
            } catch {
                stage = .failed(error.localizedDescription)
                // Byte trace of the line around the failure, for analysis.
                if let trace { for line in await trace.dump() { log?.event("trace", line) } }
                log?.end(ok: false, error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func saveEEPROM(_ bytes: [UInt8], emulated: Bool) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let file = Self.directory.appendingPathComponent("eeprom_\(formatter.string(from: Date()))\(emulated ? "_emu" : "").bin")
        try Data(bytes).write(to: file)
        return file
    }

    private func save(_ image: [UInt8], flashID: (UInt8, UInt8), emulated: Bool, otherHalf: Bool = false) throws -> Result {
        let data = Data(image)
        let firmware = try? Firmware(data: data)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let id = image.allSatisfy { $0 == 0xFF } ? "empty" : (firmware?.softwareID ?? "unknown")
        let name = "flash_\(formatter.string(from: Date()))\(otherHalf ? "_half2" : "")_\(id)\(emulated ? "_emu" : "").bin"
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let file = Self.directory.appendingPathComponent(name)
        try data.write(to: file)
        return Result(file: file, flashID: flashID, softwareID: firmware?.softwareID, empty: image.allSatisfy { $0 == 0xFF },
                      checksum: Checksum.status(of: data), infoBlock: BootstrapLoader.lockingInfoBlock(in: image))
    }
}

struct FlashReadSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(LoaderLog.self) private var loaderLog
    @Environment(\.dismiss) private var dismiss
    @State private var model = FlashReadModel()
    @State private var accepted = false
    /// Serial port path, or nil for the emulator.
    let port: String?
    let emulatorImage: [UInt8]?

    /// Which of the numbered steps is current (1…4), from the read stage.
    private var currentStep: Int {
        switch model.stage {
        case .idle, .failed: 1
        case .waiting: 2
        case .loading, .reading: 3
        case .done: 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Прочитать прошивку из блока").font(.title2.bold())
            // In a sheet multi-line text needs fixedSize to wrap instead of truncating.
            Text("Через встроенный загрузчик процессора C509, по K-line. **В блок ничего не записывается**: в его память загружается только маленькая программа чтения, после выключения питания её нет.")
                .fixedSize(horizontal: false, vertical: true)
            Picker("Что читать", selection: $model.target) {
                ForEach(FlashReadModel.Target.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)
            if port != nil {
                FlashLiabilityConsent(accepted: $accepted)
                GroupBox("По порядку") {
                    VStack(alignment: .leading, spacing: 8) {
                        step(1, "**Питание блока выключено.** Кабель — в USB и в колодку OBD. На выводе 47 должно быть +12 В вместе с питанием (на стендовом шнуре 47 обычно уже на плюсе; на машине — через выключатель).")
                        step(2, "Нажмите **«Начать чтение»**, затем **включите питание блока** (зажигание или кнопку шнура). Программа ждёт блок до 60 с и подхватит его сама.")
                        step(3, model.target != .eeprom ? "Чтение — около 1,5 мин (\(FlashReadModel.baud) бод). Ничего не трогайте." : "Чтение EEPROM — пара секунд. Ничего не трогайте.")
                        step(4, "Готово — выключите питание блока. На машине — затем уберите +12 В с вывода 47.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Label("Не нажимайте «Проверить кабель» и «Подключить», когда блок включён с +12 В на 47: загрузчик подстроится под чужую скорость и замолчит. Тогда — выключить питание и начать с шага 1.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Блок с коммерческой прошивкой может быть защищён: тогда вход в загрузчик сотрёт прошивку, а обнаружить защиту заранее нельзя. Спросите калибровщика или снимите копию программатором.", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Эмулятор: загрузчик и флеш AM29F010 смоделированы, читается открытая прошивка.", systemImage: "cpu")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            status
            if model.stage == .done, port != nil {
                Text("Для следующего чтения: выключите питание блока, нажмите «Начать заново», затем включите.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.isRunning {
                    Button("Остановить") { model.cancel() }
                } else {
                    Button(model.stage == .idle ? "Начать чтение" : "Начать заново") { model.start(port: port, emulatorImage: emulatorImage, log: loaderLog) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(port != nil && !accepted)
                }
                Spacer()
                Button("Закрыть") { model.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 580)
        // `--flashread-start` (development): start reading as soon as the sheet opens.
        .onAppear { if CommandLine.arguments.contains("--flashread-start") { model.start(port: port, emulatorImage: emulatorImage, log: loaderLog) } }
    }

    /// A numbered step: the current one is bold with an arrow, finished ones are checked.
    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        let state: (icon: String, color: Color) = n < currentStep ? ("checkmark.circle.fill", .green)
            : n == currentStep ? ("arrow.right.circle.fill", .accentColor) : ("\(n).circle", .secondary)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: state.icon).foregroundStyle(state.color)
            Text(text)
                .foregroundStyle(n == currentStep ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var status: some View {
        switch model.stage {
        case .idle:
            EmptyView()
        case .waiting(let echo):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.stage.title).foregroundStyle(echo ? Color.primary : Color.orange)
            }
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.stage.title) }
        case .reading(let n):
            ProgressView(value: Double(n), total: Double(model.target.size)) {
                Text(model.target != .eeprom ? model.stage.title : "Чтение EEPROM: \(n) из 512 Б…")
            }
        case .failed:
            Label(model.stage.title + " Перед повтором: выключите питание блока, нажмите «Начать заново», затем включите питание.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .done:
            if let e = model.eepromResult {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Прочитано 512 Б → \(e.file.lastPathComponent)", systemImage: "checkmark.circle").foregroundStyle(.green)
                    Text("Иммобилайзер: **\(e.trained ? "обучен" : "не обучен")** (байты 02…07: \(e.bytes[2..<8].map { String(format: "%02X", $0) }.joined(separator: " "))). \(e.trained ? "Без своего АПС блок не заведёт мотор." : "Блок заведёт мотор без АПС.")")
                        .fixedSize(horizontal: false, vertical: true)
                    Text(e.bytes.allSatisfy { $0 == 0xFF } ? "Внимание: все байты FF — EEPROM чистая или не ответила." : "Разбор иммобилайзера — по J5V05L19 (предположение для других версий).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Показать в Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([e.file]) }
                }
            } else if let r = model.result {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Прочитано 64 КБ → \(r.file.lastPathComponent)", systemImage: "checkmark.circle").foregroundStyle(.green)
                    Text("Флеш: производитель \(String(format: "%02X", r.flashID.0)), микросхема \(String(format: "%02X", r.flashID.1))\(r.flashID == (0x01, 0x20) ? " — AMD Am29F010" : "")")
                    Text(r.empty ? "Пусто: все 64 КБ — FF (стёртая половина)" : "Прошивка: \(r.softwareID ?? "идентификация не распознана")")
                    if let cs = r.checksum, !r.empty {
                        Text("Контрольная сумма: \(cs.isValid ? "верная" : "не сходится") (в файле \(String(format: "%04X", cs.stored)), посчитано \(String(format: "%04X", cs.computed)))")
                    }
                    if let addr = r.infoBlock {
                        Label("Найден загрузочный инфо-блок по \(String(format: "%04X", addr)) — нестандартный загрузчик или защита. Образ прочитан, но этот блок не как у заводской прошивки.", systemImage: "lock.shield")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Открыть в редакторе") { app.open(r.file, into: .primary); dismiss() }
                        Button("Показать в Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([r.file]) }
                    }
                }
            }
        }
    }
}
