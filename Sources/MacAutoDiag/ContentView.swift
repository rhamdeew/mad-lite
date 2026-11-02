import SwiftUI
import VazCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiagnosticsModel.self) private var diagnostics
    @State private var offsetText = ""
    @State private var showTransferConfirm = false
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            detail
        }
        .toolbar { toolbarItems }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            // Dropping onto an open image adds it as the comparison.
            model.open(url, into: model.primary == nil ? .primary : .comparison)
            return true
        }
        .modifier(MessageAlerts())
        .onChange(of: model.mode) { _, mode in
            // Diagnostics and log analysis need the width (gauges, sliders, 16-column grid).
            columns = Self.wideModes.contains(mode) ? .detailOnly : .all
        }
        .navigationTitle(title)
        .task { start() }
    }

    private static let wideModes: Set<AppModel.Mode> = [.diagnostics, .log]

    private var title: String {
        guard let primary = model.primary else { return Edition.name }
        return primary.name + (model.isDirty ? " — изменено" : "")
    }

    private func start() {
        model.openLaunchArguments()
        // `--diag`: open diagnostics and connect to the emulator running the opened image.
        // `--log <folder>`: open a recorded log in the analysis view.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--log"), i + 1 < args.count { model.openLog(URL(fileURLWithPath: args[i + 1])) }
        // `--openpanel` (development): show the open panel right away, to check it comes up in front.
        if CommandLine.arguments.contains("--openpanel") { model.presentOpenPanel(for: .primary) }
        // `--flashread` (development): the diagnostics tab with the flash read sheet open.
        if CommandLine.arguments.contains("--flashread") || CommandLine.arguments.contains("--flashread-cable") || CommandLine.arguments.contains("--flashwrite") || CommandLine.arguments.contains("--firmwarestart") { model.mode = .diagnostics }
        // `--diag` without a firmware: just the diagnostics tab (cable).
        if CommandLine.arguments.contains("--diag"), model.primary == nil { model.mode = .diagnostics }
        if CommandLine.arguments.contains("--diag"), let fw = model.primary, fw.size == 0x10000 {
            model.mode = .diagnostics
            diagnostics.connectEmulator(rom: Array(fw.data), name: fw.softwareID ?? fw.name)
        }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup {
            Button("Открыть", systemImage: "folder") { model.presentOpenPanel(for: .primary) }
            Button("Сохранить как", systemImage: "square.and.arrow.down") { model.presentSavePanel() }
                .disabled(model.primary == nil)
            Button("Сравнить", systemImage: "rectangle.split.2x1") { model.presentOpenPanel(for: .comparison) }
                .disabled(model.primary == nil)
            if model.comparison != nil, model.definition != nil {
                Button("Перенести калибровки", systemImage: "arrow.left.square") { showTransferConfirm = true }
                    .help("Скопировать все калибровки из образа сравнения (\(model.comparisonSoftwareID ?? "сравнение")) в текущий. Код прошивки не трогается.")
                    .confirmationDialog("Перенести все калибровки из \(model.comparisonSoftwareID ?? "сравнения") в текущую прошивку?",
                                        isPresented: $showTransferConfirm, titleVisibility: .visible) {
                        Button("Перенести") { model.transferAllCalibrations() }
                        Button("Отмена", role: .cancel) {}
                    } message: {
                        Text("Значения всех таблиц заменятся на значения из сравнения. Код прошивки не затрагивается. Проверьте результат и при необходимости «Отменить изменения».")
                    }
            }
            Picker("Режим", selection: $model.mode) {
                ForEach(AppModel.Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            // Diagnostics over the cable and log analysis work without a firmware file.
            if model.mode == .hex {
                TextField("Адрес, hex", text: $offsetText)
                    .frame(width: 110)
                    .onSubmit {
                        if let offset = HexFormatter.parseOffset(offsetText) { model.jumpTarget = offset }
                    }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if model.mode == .log, model.analysisLog != nil {
            // A log can be looked at without its firmware (no dump yet).
            LogAnalysisView()
        } else if model.mode == .diagnostics {
            // The car can be read over K-line without its firmware; the emulator needs one.
            DiagnosticsView()
        } else if let primary = model.primary {
            switch model.mode {
            case .hex:
                HexView(firmware: primary, comparison: model.comparison)
            case .diagnostics:
                DiagnosticsView()
            case .log:
                LogAnalysisView()
            case .tables:
                if let table = model.selectedTable, let definition = model.definition {
                    TableEditorView(table: table, definition: definition, firmware: primary)
                        .id(table.id)
                } else if model.definition == nil {
                    ContentUnavailableView {
                        Label("Нет описания калибровок", systemImage: "tablecells.badge.ellipsis")
                    } description: {
                        Text("Для \(primary.softwareID ?? "этой прошивки") описание ещё не составлено. Доступен режим Hex или карта ChipTuningPRO (.j5), например j5ls_v43.j5 для J5LS.")
                    } actions: {
                        Button("Открыть карту CTP…") { model.presentMapPanel() }
                    }
                } else {
                    ContentUnavailableView("Выберите таблицу", systemImage: "tablecells")
                }
            }
        } else {
            ContentUnavailableView {
                Label("Нет прошивки", systemImage: "memorychip")
            } description: {
                Text("Откройте .bin (⌘O) или перетащите файл в окно")
            } actions: {
                Button("Открыть…") { model.presentOpenPanel(for: .primary) }
                Button("Открыть лог…") { model.presentLogPanel() }
                Button("Диагностика по кабелю") { model.mode = .diagnostics }
            }
        }
    }
}

/// Error and info alerts driven by `AppModel` messages.
struct MessageAlerts: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .alert("Ошибка", isPresented: .constant(model.errorMessage != nil), presenting: model.errorMessage) { _ in
                Button("OK") { model.errorMessage = nil }
            } message: { Text($0) }
            .alert("Готово", isPresented: .constant(model.infoMessage != nil), presenting: model.infoMessage) { _ in
                Button("OK") { model.infoMessage = nil }
            } message: { Text($0) }
            .sheet(item: Binding(get: { model.openedSnapshot }, set: { model.openedSnapshot = $0 })) { opened in
                SnapshotView(opened: opened)
            }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
        List(selection: $model.selectedTableID) {
            if model.mode == .tables, let definition = model.definition {
                TableListSections(definition: definition, filter: model.tableFilter, edited: model.editedOffsets)
            }
            if let primary = model.primary {
                FirmwareInfoSection(title: "Прошивка", firmware: primary)
            }
            if let comparison = model.comparison {
                FirmwareInfoSection(title: "Сравнение", firmware: comparison)
                Section {
                    Button("Закрыть сравнение") { model.closeComparison() }
                }
                DiffSection(ranges: model.diffRanges)
            }
        }
        .listStyle(.sidebar)
        // A table chosen elsewhere (launch option, log analysis) is brought into view.
        // No anchor: a row that is already visible (a click) does not move.
        .onAppear { if let id = model.selectedTableID { proxy.scrollTo(id) } }
        .onChange(of: model.selectedTableID) { _, id in if let id { proxy.scrollTo(id) } }
        }
        .searchable(text: $model.tableFilter, placement: .sidebar, prompt: "Таблица или адрес")
    }
}

struct TableListSections: View {
    let definition: CalibrationDefinition
    let filter: String
    let edited: IndexSet

    /// Named groups first, generic "Не определено…" and constants last.
    private var groups: [(String, [TableDefinition])] {
        let q = filter.lowercased()
        let matching = definition.tables.filter {
            q.isEmpty || $0.name.lowercased().contains(q) || $0.address == HexFormatter.parseOffset(q)
        }
        let grouped = Dictionary(grouping: matching, by: \.group)
        func rank(_ g: String) -> Int { g.hasPrefix("Не определено") ? 1 : g == "Константы" ? 2 : 0 }
        return grouped.sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }
            .map { ($0.key, $0.value.sorted { $0.address < $1.address }) }
    }

    var body: some View {
        ForEach(groups, id: \.0) { group, tables in
            Section(group) {
                ForEach(tables) { table in
                    TableRow(table: table, isEdited: edited.intersects(integersIn: table.byteRange))
                        .tag(table.id)
                }
            }
        }
    }
}

struct TableRow: View {
    let table: TableDefinition
    let isEdited: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: table.isScalar ? "number" : table.rows > 1 ? "square.grid.3x3" : "chart.xyaxis.line")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(table.name).lineLimit(1)
                Text("0x" + HexFormatter.offset(table.address, digits: 4) + " · \(table.rows)×\(table.cols)")
                    .font(.caption).monospaced().foregroundStyle(.secondary)
            }
            Spacer()
            if isEdited {
                Circle().fill(.orange).frame(width: 7, height: 7).help("Изменено")
            }
            if table.confidence == .likely {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary).help("Назначение вероятное, не проверено")
            }
        }
    }
}

struct FirmwareInfoSection: View {
    let title: String
    let firmware: Firmware

    var body: some View {
        Section(title) {
            InfoRow("Файл", firmware.name)
            InfoRow("Размер", "\(firmware.size) Б (0x\(String(firmware.size, radix: 16, uppercase: true)))")
            InfoRow("Формат", firmware.format.rawValue)
            InfoRow("ЭБУ", firmware.family.rawValue)
            InfoRow("ID ПО", firmware.softwareID)
            InfoRow("Сборка", firmware.header?.buildDate)
            InfoRow("Модель", firmware.header?.model)
            if let id = firmware.identification {
                InfoRow("Код ПО", id.softwareCode)
                InfoRow("Двигатель", id.engine)
                InfoRow("Дата", id.date)
                InfoRow("Блок ID", "0x" + HexFormatter.offset(id.offset, digits: 4))
            }
            InfoRow("Описание", firmware.definition.map { "\($0.tables.count) таблиц" } ?? "нет")
            if let cs = firmware.checksum {
                LabeledContent("КС") {
                    HStack(spacing: 4) {
                        Text(String(format: "%04X", cs.stored)).monospaced()
                        if cs.isValid {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help(String(format: "Сумма байт %04X, записано %04X, зеркало %04X. Будет исправлено при сохранении.", cs.computed, cs.stored, cs.mirror))
                        }
                    }
                }
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        LabeledContent(label) {
            Text(value ?? "—").textSelection(.enabled).monospaced()
        }
    }
}

struct DiffSection: View {
    @Environment(AppModel.self) private var model
    let ranges: [Range<Int>]

    var body: some View {
        Section("Отличия: \(ranges.count) блоков, \(FirmwareDiff.byteCount(ranges)) Б") {
            if ranges.isEmpty {
                Text("Файлы идентичны").foregroundStyle(.secondary)
            }
            ForEach(ranges.prefix(500), id: \.lowerBound) { range in
                Button {
                    model.mode = .hex
                    model.jumpTarget = range.lowerBound
                } label: {
                    HStack {
                        Text("0x" + HexFormatter.offset(range.lowerBound)).monospaced()
                        Spacer()
                        Text("\(range.count) Б").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            if ranges.count > 500 {
                Text("… и ещё \(ranges.count - 500)").foregroundStyle(.secondary)
            }
        }
    }
}
