import AppKit
import SwiftUI
import VazCore
import VazEmu
import VazSerial

/// Writes a firmware image and/or the EEPROM into a Январь 5.1 through the C509 bootstrap
/// loader (`docs/flashing.md`). **For a spare block only.** Each write erases/programs the
/// chip; the firmware write verifies by read-back, the EEPROM write defeats the immobilizer.
@MainActor @Observable
final class FlashWriteModel {
    enum Stage: Equatable {
        case idle, syncing, agent
        case backup(Int), erasing(Int), writing(Int), verifying(Int)
        case eepromReading(Int), eepromWriting(Int)
        case done(String), failed(String)

        var title: String {
            switch self {
            case .idle: "Готово"
            case .syncing: "Жду блок — включите питание блока (с +12 В на выводе 47). Если он уже включён — выключите и включите снова."
            case .agent: "Загрузка агента…"
            case .backup(let n): "Резервная копия перед записью: \(n / 1024) из 64 КБ…"
            case .erasing(let s): "Стирание сектора \(s + 1) из 4 (\(String(format: "%04X", s * 0x4000))–\(String(format: "%04X", s * 0x4000 + 0x3FFF)))…"
            case .writing(let n): "Запись флеш: \(n / 1024) из 64 КБ…"
            case .verifying(let n): "Проверка флеш: \(n / 1024) из 64 КБ…"
            case .eepromReading(let n): "Чтение EEPROM: \(n) из 512 Б…"
            case .eepromWriting(let n): "Запись EEPROM: \(n) из 512 Б…"
            case .done(let m): m
            case .failed(let m): "Ошибка: \(m)"
            }
        }
    }

    private(set) var stage = Stage.idle
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch stage {
        case .idle, .done, .failed: false
        default: true
        }
    }

    private func transport(port: String?, emulatorImage: [UInt8]?) throws -> any KLineTransport {
        if let emulatorImage { return BootstrapEmulatorTransport(image: emulatorImage) }
        return try SerialKLineTransport(path: port ?? "", baud: FlashReadModel.baud, stopBits: 2)
    }

    /// Why the open image must not be written (shown before the confirmation), or nil.
    static func refusal(_ image: [UInt8]) -> String? {
        if let why = FlashWriteAgent.refusalReason(image) { return why }
        if let cs = Checksum.status(of: Data(image)), !cs.isValid {
            return String(format: "Контрольная сумма образа не сходится (в файле %04X, посчитано %04X): блок покажет «Ошибка ПЗУ». Сохраните прошивку в редакторе (КС пересчитается) и откройте снова.", cs.stored, cs.computed)
        }
        return nil
    }

    /// Writes `image` to the block (`BootstrapClient.programImage`): backup read → sector
    /// erase (only differing sectors, or all four with `force`) → program → full verify.
    func writeFlash(_ image: [UInt8], force: Bool, port: String?, emulatorImage: [UInt8]?, log: LoaderLog? = nil) {
        guard !isRunning, Self.refusal(image) == nil else { return }
        stage = .syncing
        task = Task {
            var trace: TracingTransport?
            log?.begin("Запись прошивки", source: emulatorImage != nil ? "эмулятор" : (port ?? "кабель"))
            do {
                let traced = TracingTransport(try transport(port: port, emulatorImage: emulatorImage))
                trace = traced
                let loader = BootstrapClient(transport: traced)
                log?.event("sync", "Жду загрузчик: 00 каждые 0,2 с, до 60 с")
                try await loader.waitForLoader()
                log?.event("sync", "Загрузчик ответил 55")
                stage = .agent
                log?.event("agent", "Загрузка агента записи")
                try await loader.startWriteAgent()
                let id = try await loader.flashID()
                log?.event("id", "Флеш: \(String(format: "%02X %02X", id.manufacturer, id.device))")
                guard id == (0x01, 0x20) else {
                    throw FlashWriteError.refused(String(format: "Флеш %02X %02X — не AMD Am29F010 (01 20). Запись не начата, блок не тронут.", id.manufacturer, id.device))
                }
                // Backup first: nothing is erased until it is on disk.
                stage = .backup(0)
                let current = try await loader.readFlash { n in Task { @MainActor in self.stage = .backup(n); if n % 0x4000 == 0 { log?.event("backup", "Чтение перед записью", done: n, total: 0x10000) } } }
                let backupFile = try save(current, name: "flash_backup_before_write")
                log?.event("backup", "Резервная копия: \(backupFile.lastPathComponent)")
                let report = try await loader.programImage(image, current: current, force: force,
                    onErase: { s in Task { @MainActor in self.stage = .erasing(s); log?.event("erase", String(format: "Стирание сектора %04X–%04X", s * 0x4000, s * 0x4000 + 0x3FFF)) } },
                    onWrite: { n in Task { @MainActor in self.stage = .writing(n); if n % 0x2000 == 0 { log?.event("write", "Запись флеш", done: n) } } },
                    onVerify: { n in Task { @MainActor in self.stage = .verifying(n); if n % 0x4000 == 0 { log?.event("verify", "Проверка флеш", done: n, total: 0x10000) } } })
                let summary = report.sectors.isEmpty
                    ? "Блок уже содержит эту прошивку (0 отличий) — ничего не стёрто и не записано."
                    : "Записано и проверено: секторов \(report.sectors.count) из 4, отличалось \(report.differingBytes) Б, передано \(report.bytesSent) Б. Сверка 64 КБ — совпадает."
                stage = .done(summary)
                log?.end(ok: true, summary)
            } catch is CancellationError { stage = .idle; log?.end(ok: false, "Отменено") }
            catch {
                stage = .failed(error.localizedDescription)
                if let trace { for line in await trace.dump() { log?.event("trace", line) } }
                log?.end(ok: false, error.localizedDescription)
            }
        }
    }

    /// Reads the EEPROM, disables the immobilizer and writes it back; saves both copies.
    func defeatImmobilizer(port: String?, emulatorImage: [UInt8]?, log: LoaderLog? = nil) {
        guard !isRunning else { return }
        stage = .syncing
        task = Task {
            log?.begin("Отвязка иммобилайзера", source: emulatorImage != nil ? "эмулятор" : (port ?? "кабель"))
            do {
                let loader = BootstrapClient(transport: try transport(port: port, emulatorImage: emulatorImage))
                log?.event("sync", "Жду загрузчик: 00 каждые 0,2 с, до 60 с")
                try await loader.waitForLoader()
                log?.event("sync", "Загрузчик ответил 55")
                stage = .agent
                log?.event("agent", "Загрузка агента EEPROM")
                try await loader.startEEPROMAgent()
                let original = try await loader.readEEPROM(size: 512) { n in Task { @MainActor in self.stage = .eepromReading(n); log?.event("eeprom", "Чтение EEPROM", done: n, total: 512) } }
                try save(original, name: "eeprom_original")
                log?.event("immo", "Иммобилайзер обучен: \(Immobilizer.isTrained(eeprom: original) ? "да" : "нет")")
                guard Immobilizer.needsDefeat(eeprom: original) else {
                    stage = .done("Иммобилайзер уже не обучен — менять нечего. Оригинал EEPROM сохранён.")
                    log?.end(ok: true, "Иммобилайзер уже не обучен; оригинал EEPROM сохранён")
                    return
                }
                let defeated = Immobilizer.defeat(eeprom: original)
                try await loader.programEEPROM(defeated,
                    onWrite: { n in Task { @MainActor in self.stage = .eepromWriting(n); log?.event("eeprom", "Запись EEPROM", done: n, total: 512) } },
                    onVerify: { n in Task { @MainActor in self.stage = .eepromReading(n); log?.event("verify", "Проверка EEPROM", done: n, total: 512) } })
                try save(defeated, name: "eeprom_defeated")
                stage = .done("Иммобилайзер отвязан (02…07 = FF). Оригинал и новая копия EEPROM сохранены в Документы/\(Edition.dataFolder)/Flash.")
                log?.end(ok: true, "Иммобилайзер отвязан (02…07 = FF); оригинал и копия сохранены")
            } catch is CancellationError { stage = .idle; log?.end(ok: false, "Отменено") }
            catch { stage = .failed(error.localizedDescription); log?.end(ok: false, error.localizedDescription) }
        }
    }

    func cancel() { task?.cancel(); task = nil }

    @discardableResult
    private func save(_ bytes: [UInt8], name: String) throws -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        try FileManager.default.createDirectory(at: FlashReadModel.directory, withIntermediateDirectories: true)
        let file = FlashReadModel.directory.appendingPathComponent("\(name)_\(f.string(from: Date())).bin")
        try Data(bytes).write(to: file)
        return file
    }
}

struct FlashWriteSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(LoaderLog.self) private var loaderLog
    @Environment(\.dismiss) private var dismiss
    @State private var model = FlashWriteModel()
    @State private var confirmFlash = false
    @State private var confirmImmo = false
    /// Rewrite all four sectors even if they already match (to test the write path).
    @State private var force = false
    @State private var accepted = false
    let port: String?
    let emulatorImage: [UInt8]?

    /// The open 64 KB raw image is the flash-write source.
    private var source: [UInt8]? {
        guard let fw = app.primary, fw.format == .raw, fw.size == 0x10000 else { return nil }
        return Array(fw.data)
    }

    /// The emulator has nothing to lose.
    private var mayStart: Bool { accepted || port == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Записать в блок").font(.title2.bold())
            if port != nil { FlashLiabilityConsent(accepted: $accepted) }
            Label("Только для запасного блока. Запись стирает и перезаписывает память. Порядок: питание блока выключено → нажать кнопку записи → включить питание блока (с +12 В на выводе 47). Программа ждёт блок до 60 с. «Проверить кабель» и «Подключить» перед этим не нажимать.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Прошивка") {
                VStack(alignment: .leading, spacing: 8) {
                    if let s = source {
                        Text("Источник — открытая прошивка: \(app.primary?.softwareID ?? app.primary?.name ?? "") (\(s.count / 1024) КБ)\(app.isDirty ? ", с правками" : "").")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Порядок: резервная копия блока (≈1,5 мин) → стирание только отличающихся секторов по 16 КБ (вторая половина микросхемы не трогается) → запись → сверка всех 64 КБ (≈1,5 мин). Если что-то пойдёт не так, блок восстанавливается этим же окном — загрузчик в процессоре не стирается.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Перезаписать все 4 сектора, даже если совпадают (проверка записи)", isOn: $force)
                            .disabled(model.isRunning)
                        if let why = FlashWriteModel.refusal(s) {
                            Label(why, systemImage: "xmark.octagon").foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Записать прошивку…") { confirmFlash = true }
                            .disabled(!mayStart || model.isRunning || FlashWriteModel.refusal(s) != nil)
                    } else {
                        Text("Откройте прошивку Январь 5.1 (64 КБ), чтобы записать её в блок.")
                            .foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Иммобилайзер (EEPROM)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Прочитать EEPROM, снять привязку иммобилайзера (02…07 = FF) и записать обратно. Оригинал сохраняется. На живом блоке не проверялось, только в эмуляторе.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Отвязать иммобилайзер…") { confirmImmo = true }
                        .disabled(!mayStart || model.isRunning)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }

            status
            HStack {
                if model.isRunning { Button("Остановить") { model.cancel() } }
                Spacer()
                Button("Закрыть") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 580)
        // `--flashwrite-go`, `--flashwrite-immo` (development, tutorial screenshots): on the emulator
        // only, start as soon as the sheet opens.
        .onAppear {
            guard emulatorImage != nil else { return }
            if CommandLine.arguments.contains("--flashwrite-go"), let s = source {
                force = true
                model.writeFlash(s, force: true, port: port, emulatorImage: emulatorImage, log: loaderLog)
            }
            if CommandLine.arguments.contains("--flashwrite-immo") {
                model.defeatImmobilizer(port: port, emulatorImage: emulatorImage, log: loaderLog)
            }
        }
        .confirmationDialog("Записать прошивку в блок? Память будет стёрта и перезаписана.", isPresented: $confirmFlash, titleVisibility: .visible) {
            Button("Записать", role: .destructive) { if let s = source { model.writeFlash(s, force: force, port: port, emulatorImage: emulatorImage, log: loaderLog) } }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Только запасной блок. После записи — выключить зажигание, убрать +12 В с вывода 47.") }
        .confirmationDialog("Отвязать иммобилайзер в EEPROM блока?", isPresented: $confirmImmo, titleVisibility: .visible) {
            Button("Отвязать", role: .destructive) { model.defeatImmobilizer(port: port, emulatorImage: emulatorImage, log: loaderLog) }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Байты 02…07 станут FF. Оригинал EEPROM сохранится отдельно.") }
    }

    @ViewBuilder private var status: some View {
        switch model.stage {
        case .idle: EmptyView()
        case .done(let m):
            Label(m, systemImage: "checkmark.circle").foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
        case .failed:
            Label(model.stage.title, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .backup(let n), .writing(let n), .verifying(let n):
            ProgressView(value: Double(n), total: 0x10000) { Text(model.stage.title) }
        case .eepromReading(let n), .eepromWriting(let n):
            ProgressView(value: Double(n), total: 512) { Text(model.stage.title) }
        default:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.stage.title) }
        }
    }
}
