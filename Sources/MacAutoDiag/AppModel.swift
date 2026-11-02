import AppKit
import Observation
import UniformTypeIdentifiers
import VazCore

@MainActor @Observable
final class AppModel {
    enum Slot { case primary, comparison }
    enum Mode: String, CaseIterable { case tables = "Таблицы", hex = "Hex", diagnostics = "Диагностика", log = "Лог" }

    private(set) var primary: Firmware?
    /// The primary image as it was loaded, to mark and count edits.
    private(set) var original: Firmware?
    private(set) var comparison: Firmware?
    private(set) var diffRanges: [Range<Int>] = []
    /// Offsets of differing bytes, for O(1) lookup while rendering rows.
    private(set) var diffOffsets = IndexSet()
    var errorMessage: String?
    /// Offset the hex view should scroll to; reset by the view after scrolling.
    var jumpTarget: Int?
    var mode: Mode = .tables
    var selectedTableID: TableDefinition.ID?
    var tableFilter = ""

    /// Definition imported from a ChipTuningPRO map for the open image; replaces the bundled one.
    private(set) var mapDefinition: CalibrationDefinition?

    var definition: CalibrationDefinition? { mapDefinition ?? primary?.definition }

    var selectedTable: TableDefinition? {
        definition?.tables.first { $0.id == selectedTableID }
    }

    /// Offsets edited since loading.
    var editedOffsets: IndexSet {
        guard let primary, let original else { return IndexSet() }
        var set = IndexSet()
        for range in FirmwareDiff.ranges(original.data, primary.data) { set.insert(integersIn: range) }
        return set
    }

    var isDirty: Bool { primary?.data != original?.data }

    /// Shows a file panel as a sheet on the app window, after bringing the app to the front.
    /// Run with `swift run` the app is not a bundle and is not activated; a free-standing
    /// `runModal()` panel came up behind other windows and, the app being inactive, the first
    /// click only activated it — double clicks into folders didn't work (user report 27.10.2026).
    static func run(_ panel: NSSavePanel) async -> URL? {
        // macOS 14 cooperative activation: allowed right after the user's click in our window.
        NSApp.activate()
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        guard let window else { return panel.runModal() == .OK ? panel.url : nil }
        window.makeKeyAndOrderFront(nil)
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }

    func presentOpenPanel(for slot: Slot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = slot == .primary ? "Выберите прошивку" : "Выберите прошивку для сравнения"
        Task {
            guard let url = await Self.run(panel) else { return }
            open(url, into: slot)
        }
    }

    func open(_ url: URL, into slot: Slot) {
        do {
            let firmware = try Firmware(contentsOf: url)
            switch slot {
            case .primary:
                primary = firmware
                original = firmware
                comparison = nil
                mapDefinition = nil
                selectedTableID = firmware.definition?.tables.first { $0.group == "Зажигание" }?.id
                if firmware.definition == nil { mode = .hex }
            case .comparison:
                comparison = firmware
            }
            recomputeDiff()
        } catch {
            errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func presentMapPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.message = "Выберите карту ChipTuningPRO (.j5) для открытой прошивки"
        Task {
            guard let url = await Self.run(panel) else { return }
            importMap(url)
        }
    }

    /// Describes the open image's tables with a ChipTuningPRO map (e.g. j5ls_v43.j5 for J5LS).
    func importMap(_ url: URL) {
        do {
            let result = try CTPMap(contentsOf: url).definition(
                softwareIDs: primary?.softwareID.map { [$0] } ?? [],
                source: "Карта ChipTuningPRO \(url.lastPathComponent)")
            mapDefinition = primary.map { result.definition(for: $0.data) } ?? result.definition
            mode = .tables
            let tables = result.definition.tables
            selectedTableID = (tables.first { $0.group.contains("Зажигание") && $0.rows > 1 } ?? tables.first)?.id
            var note = "Карта \(url.lastPathComponent): \(tables.count) таблиц и констант."
            if !result.skipped.isEmpty {
                note += " Пропущено: " + result.skipped.joined(separator: ", ") + "."
            }
            note += " Названия и формулы — из карты, по коду прошивки не проверены."
            if let primary, let warning = result.mismatch(with: primary.data) { note = "⚠️ " + warning + "\n\n" + note }
            infoMessage = note
        } catch {
            errorMessage = "\(url.lastPathComponent): не удалось прочитать карту CTP — \(error.localizedDescription)"
        }
    }

    /// `MacAutoDiag <firmware> [<comparison>] [--map <file.j5>] [--rpm N] [--diag] [--record]`
    /// opens the given files on launch.
    func openLaunchArguments() {
        var args = Array(CommandLine.arguments.dropFirst())
        var mapPath: String?
        if let i = args.firstIndex(of: "--map"), i + 1 < args.count {
            mapPath = args[i + 1]
            args.removeSubrange(i ... i + 1)
        }
        // Option values are not file names.
        for option in ["--charts-cursor", "--snapshotfile", "--compare", "--rpm", "--log", "--tps", "--maf", "--clt", "--volt", "--mapv", "--load", "--table", "--logview"] {
            if let i = args.firstIndex(of: option), i + 1 < args.count { args.removeSubrange(i ... i + 1) }
        }
        let paths = args.filter { !$0.hasPrefix("-") }
        if let first = paths.first { open(URL(fileURLWithPath: first), into: .primary) }
        if paths.count > 1 { open(URL(fileURLWithPath: paths[paths.startIndex + 1]), into: .comparison) }
        if let mapPath { importMap(URL(fileURLWithPath: mapPath)) }
        // `--table t6AC8` (development, tutorial screenshots): select a table by id.
        let all = CommandLine.arguments
        // `--snapshotfile A.json [--compare B.json]` (development, screenshots): open snapshots.
        if let i = all.firstIndex(of: "--snapshotfile"), i + 1 < all.count { openSnapshot(URL(fileURLWithPath: all[i + 1])) }
        if let i = all.firstIndex(of: "--compare"), i + 1 < all.count { compareSnapshot(URL(fileURLWithPath: all[i + 1])) }
        if let i = all.firstIndex(of: "--table"), i + 1 < all.count,
           let table = definition?.tables.first(where: { $0.id == all[i + 1] }) {
            mode = .tables
            selectedTableID = table.id
        }
    }

    func closeComparison() {
        comparison = nil
        recomputeDiff()
    }

    func setValue(_ value: Double, table: TableDefinition, row: Int, col: Int) {
        primary?.setValue(value, of: table, row: row, col: col)
        recomputeDiff()
    }

    func setRaw(_ raw: Int, table: TableDefinition, row: Int, col: Int) {
        primary?.setRaw(raw, of: table, row: row, col: col)
        recomputeDiff()
    }

    func revertTable(_ table: TableDefinition) {
        guard let original else { return }
        primary?.write(original.bytes(of: table), at: table.address)
        recomputeDiff()
    }

    // MARK: - Transfer calibrations from the comparison image

    /// Software ID of the comparison image, for the transfer UI.
    var comparisonSoftwareID: String? { comparison?.softwareID }

    /// A table can be transferred when a comparison image is open and the table fits in both
    /// images. The comparison must use the same calibration layout (same J5LS/J5TRS family).
    func canTransfer(_ table: TableDefinition) -> Bool {
        guard let primary, let comparison else { return false }
        return table.byteRange.upperBound <= primary.data.count
            && table.byteRange.upperBound <= comparison.data.count
    }

    /// Copies `table`'s cells from the comparison image into the primary, cell by cell so
    /// packed flag bytes keep their other bits (same definition → raw == value).
    func transferTable(_ table: TableDefinition) {
        guard canTransfer(table), let comparison else { return }
        let raw = comparison.rawValues(of: table)
        guard raw.count == table.count else { return }
        for i in 0..<table.count {
            primary?.setRaw(raw[i], of: table, row: i / table.cols, col: i % table.cols)
        }
        recomputeDiff()
        infoMessage = "«\(table.name)» перенесена из \(comparisonSoftwareID ?? "сравнения"). «Отменить изменения» вернёт исходное."
    }

    /// Copies every calibration table of the current definition from the comparison image.
    func transferAllCalibrations() {
        guard let definition, comparison != nil else { return }
        var moved = 0
        for table in definition.tables where canTransfer(table) {
            let before = primary?.bytes(of: table)
            transferTableSilently(table)
            if primary?.bytes(of: table) != before { moved += 1 }
        }
        recomputeDiff()
        infoMessage = "Перенесено калибровок из \(comparisonSoftwareID ?? "сравнения"): \(moved) из \(definition.tables.count). Код прошивки не затронут. «Сравнить» покажет отличия; сохранение пересчитает КС."
    }

    private func transferTableSilently(_ table: TableDefinition) {
        guard let comparison else { return }
        let raw = comparison.rawValues(of: table)
        guard raw.count == table.count else { return }
        for i in 0..<table.count {
            primary?.setRaw(raw[i], of: table, row: i / table.cols, col: i % table.cols)
        }
    }

    // MARK: - Log analysis (stage 7)

    private(set) var analysisLog: SensorLog?
    private(set) var analysisLogName = ""
    var analysisTableID: TableDefinition.ID?

    /// Tables a log can be laid over: both axes defined.
    var analysisTables: [TableDefinition] {
        definition?.tables.filter { $0.xAxis != nil && $0.yAxis != nil && $0.rows > 1 && $0.cols > 1 } ?? []
    }

    var analysisTable: TableDefinition? {
        analysisTables.first { $0.id == analysisTableID }
    }

    /// The user chose the generic grid (no firmware dump, or to compare logs across firmwares).
    var preferGenericGrid = false

    /// Generic grid when asked for or when no table of the open firmware can take the log.
    var usesGenericGrid: Bool { preferGenericGrid || analysisTable == nil }

    var fuelAnalysis: Result<FuelCorrectionAnalysis, Error>? {
        guard let log = analysisLog else { return nil }
        if usesGenericGrid {
            guard let grid = AxisMapping.generic(for: log) else {
                return .failure(FuelCorrectionAnalysis.AnalysisError.missingColumn("rpm"))
            }
            return Result { try FuelCorrectionAnalysis(log: log, x: grid.x, y: grid.y) }
        }
        guard let table = analysisTable, let definition, let primary else { return nil }
        return Result { try FuelCorrectionAnalysis(log: log, table: table, definition: definition, firmware: primary.data) }
    }

    // MARK: Snapshots

    struct OpenedSnapshot: Identifiable {
        let id = UUID()
        var snapshot: ECUSnapshot
        var name: String
        /// The earlier of the two when comparing; `snapshot` is then the later one.
        var baseline: (snapshot: ECUSnapshot, name: String)?
    }

    /// Shown as a sheet over the window.
    var openedSnapshot: OpenedSnapshot?

    func presentSnapshotPanel(compare: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.directoryURL = DiagnosticsModel.snapshotsDirectory
        panel.message = compare ? "Выберите второй снимок для сравнения" : "Выберите снимок блока (snapshot_….json)"
        Task {
            guard let url = await Self.run(panel) else { return }
            if compare { compareSnapshot(url) } else { openSnapshot(url) }
        }
    }

    func openSnapshot(_ url: URL) {
        do {
            openedSnapshot = OpenedSnapshot(snapshot: try ECUSnapshot.decode(Data(contentsOf: url)), name: url.lastPathComponent)
        } catch {
            errorMessage = "Не удалось открыть снимок \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Adds a second snapshot; whichever was taken earlier becomes the baseline.
    func compareSnapshot(_ url: URL) {
        guard let current = openedSnapshot else { return openSnapshot(url) }
        do {
            let other = try ECUSnapshot.decode(Data(contentsOf: url))
            let a = (snapshot: current.snapshot, name: current.name), b = (snapshot: other, name: url.lastPathComponent)
            let (old, new) = a.snapshot.taken <= b.snapshot.taken ? (a, b) : (b, a)
            openedSnapshot = OpenedSnapshot(snapshot: new.snapshot, name: new.name, baseline: old)
        } catch {
            errorMessage = "Не удалось открыть снимок \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func presentLogPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.commaSeparatedText, .folder]
        panel.directoryURL = DiagnosticsModel.logsDirectory
        panel.message = "Выберите папку сеанса (или log.csv)"
        Task {
            guard let url = await Self.run(panel) else { return }
            openLog(url)
        }
    }

    /// Opens a session folder or its `.csv`.
    func openLog(_ url: URL) {
        do {
            let isCSV = url.pathExtension.lowercased() == "csv"
            let folder = isCSV ? url.deletingLastPathComponent() : url
            let name = isCSV ? url.deletingPathExtension().lastPathComponent : "log"
            analysisLog = try SensorLog(directory: folder, name: name)
            analysisLogName = folder.lastPathComponent
            mode = .log
            if analysisTable == nil { analysisTableID = Self.defaultAnalysisTable(in: analysisTables)?.id }
        } catch {
            errorMessage = "\(url.lastPathComponent): не удалось прочитать лог (\(error))"
        }
    }

    /// The table fuel trims usually go to: filling correction by pressure (J5LS with a MAP
    /// sensor), then any correction table, then the first 2D table.
    static func defaultAnalysisTable(in tables: [TableDefinition]) -> TableDefinition? {
        let lower = { (t: TableDefinition) in t.name.lowercased() }
        return tables.first { lower($0).contains("поправка циклового наполнения") && $0.yAxis?.hasPrefix("press") == true }
            ?? tables.first { lower($0).contains("поправка циклового наполнения") }
            ?? tables.first { lower($0).contains("коррекц") && lower($0).contains("впрыск") }
            ?? tables.first
    }

    func applyFuelCorrection() {
        guard !usesGenericGrid, case .success(let analysis)? = fuelAnalysis, let table = analysisTable,
              var image = primary else { return }
        let before = image.values(of: table)
        let after = analysis.corrected(before)
        for (k, (old, new)) in zip(before, after).enumerated() where new != old {
            image.setValue(new, of: table, row: k / table.cols, col: k % table.cols)
        }
        primary = image
        recomputeDiff()
        infoMessage = "Поправки внесены в «\(table.name)». Проверьте в редакторе таблиц; «Отменить изменения» вернёт исходные значения."
    }

    /// Shown after saving: what happened to the checksum.
    var infoMessage: String?

    func presentSavePanel() {
        Task { await save() }
    }

    private func save() async {
        guard var image = primary else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (image.name as NSString).deletingPathExtension + "_mod.bin"
        let firmwareChecks = image.checksum != nil && Checksum.isCheckedByFirmware(image.data)
        // Recompute FFFE whenever the image uses the January CS convention (valid mirror),
        // so edited V43/TRS bases stay valid for CTP/Combiloader even though their firmware
        // does not check it at runtime. A dummy word without a mirror (N35) is left alone.
        let recompute = image.checksum != nil && (firmwareChecks || Checksum.maintainsStructure(image.data))
        panel.message = recompute
            ? (firmwareChecks
                ? "Контрольная сумма будет пересчитана (прошивка её проверяет)."
                : "Контрольная сумма будет пересчитана для совместимости с загрузчиками (прошивка её не проверяет).")
            : image.checksum != nil
                ? "У прошивки нет январской структуры КС (FFFE без зеркала) — байты FFFA–FFFF не трогаем."
                : "Контрольная сумма для этого формата не пересчитывается."
        guard let url = await Self.run(panel) else { return }
        do {
            var note = "Сохранено: \(url.lastPathComponent)."
            if recompute {
                let result = try image.fixChecksum()
                note += Self.describe(result)
                if !firmwareChecks { note += " (для загрузчиков; прошивка КС не проверяет)" }
            } else if image.checksum != nil {
                note += " КС не пересчитана: у прошивки нет январской структуры КС (как в J5LS N35)."
            }
            try image.data.write(to: url)
            primary = image
            original = image
            recomputeDiff()
            infoMessage = note
        } catch {
            errorMessage = "Не удалось сохранить: \(error.localizedDescription)"
        }
    }

    private static func describe(_ r: Checksum.FixResult) -> String {
        let hex = { String(format: "%04X", $0) }
        if r.before.isValid {
            return " КС \(hex(r.after.stored)) была верной."
        }
        return " КС пересчитана: \(hex(r.before.stored)) → \(hex(r.after.stored)) (0xFFFE), зеркало \(hex(r.after.mirror)) (0xFFFA)."
    }

    private func recomputeDiff() {
        guard let primary, let comparison else {
            diffRanges = []
            diffOffsets = IndexSet()
            return
        }
        diffRanges = FirmwareDiff.ranges(primary.data, comparison.data)
        var offsets = IndexSet()
        for range in diffRanges { offsets.insert(integersIn: range) }
        diffOffsets = offsets
    }
}
