import SwiftUI
import VazCore

/// Stage 7: a recorded log laid over a fuel table of the open firmware. Each cell shows how
/// much the ECU trimmed fuelling there in closed loop (injection correction coefficient) and
/// how many log rows support it; "Применить" multiplies the cells by the suggested factors.
struct LogAnalysisView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmApply = false
    @AppStorage("logView") private var view = LogView.fromLaunchArguments ?? .cells

    enum LogView: String, CaseIterable {
        case cells = "Ячейки таблицы"
        case charts = "Графики"

        /// `--logview cells|charts` (development, tutorial screenshots).
        static var fromLaunchArguments: LogView? {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: "--logview"), i + 1 < args.count else { return nil }
            return args[i + 1] == "charts" ? .charts : .cells
        }
    }

    var body: some View {
        if let log = model.analysisLog {
            VStack(alignment: .leading, spacing: 0) {
                header(log)
                    .onAppear { if let v = LogView.fromLaunchArguments { view = v } }
                Divider()
                switch view {
                case .cells: content(log)
                case .charts: LogChartsView(log: log)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Лог не открыт", systemImage: "waveform.path.ecg")
            } description: {
                Text("Откройте папку сеанса из «Документы / \(Edition.dataFolder) / Logs» (или log.csv). Разбор покажет, на сколько ЭБУ подправлял впрыск по ДК в каждой ячейке выбранной таблицы.")
            } actions: {
                Button("Открыть лог…") { model.presentLogPanel() }
            }
        }
    }

    private func header(_ log: SensorLog) -> some View {
        @Bindable var model = model
        let seconds = Double((log.timeMs.last ?? 0) - (log.timeMs.first ?? 0)) / 1000
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.analysisLogName).font(.headline)
                Text("\(log.count) записей, \(String(format: "%.0f", seconds)) с, меток: \(log.markers.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Вид", selection: $view) {
                    ForEach(LogView.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Button("Другой лог…") { model.presentLogPanel() }
            }
            if let id = log.session?.softwareID, let open = model.primary?.softwareID, id != open {
                Label("Лог записан с \(id), а открыта \(open) — ячейки могут не совпасть.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if view == .cells {
                HStack {
                    // Without a usable table the generic grid is the only choice; show it as selected.
                    Picker("Сетка", selection: Binding(get: { model.usesGenericGrid },
                                                       set: { model.preferGenericGrid = $0 })) {
                        Text("Таблица прошивки").tag(false)
                        Text("Типовая (без дампа)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 330)
                    .disabled(model.analysisTables.isEmpty)
                    if !model.usesGenericGrid {
                        Picker("Таблица", selection: $model.analysisTableID) {
                            ForEach(model.analysisTables) { t in
                                Text("\(t.name) · 0x\(HexFormatter.offset(t.address, digits: 4))").tag(Optional(t.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 560)
                    }
                }
            }
        }
        .padding()
    }

    @ViewBuilder private func content(_ log: SensorLog) -> some View {
        switch model.fuelAnalysis {
        case .none:
            ContentUnavailableView("Нет подходящей таблицы", systemImage: "tablecells",
                                   description: Text("Нужна таблица с двумя осями (обороты × нагрузка) из описания прошивки или карты CTP."))
        case .failure(let error):
            ContentUnavailableView("Разбор невозможен", systemImage: "exclamationmark.triangle",
                                   description: Text(Self.describe(error)))
        case .success(let analysis):
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 12) {
                    summary(analysis)
                    grid(analysis)
                    legend
                }
                .padding()
            }
            .confirmationDialog("Применить поправки?", isPresented: $confirmApply) {
                Button("Применить к \(model.analysisTable?.name ?? "таблице")") { model.applyFuelCorrection() }
            } message: {
                Text("Ячеек с поправкой: \(analysis.cells.filter { $0.factor != nil }.count). Изменения видны в редакторе таблиц, их можно отменить кнопкой «Отменить изменения». КС пересчитается при сохранении.")
            }
        }
    }

    private func summary(_ a: FuelCorrectionAnalysis) -> some View {
        let generic = model.analysisTables.isEmpty
            ? "Прошивка не открыта или у неё нет описания таблиц — показана типовая сетка: обороты по узлам серийной J5, нагрузка — давление ДАД (если есть в логе), иначе ЦН или дроссель. Применить к таблице нельзя; когда будет дамп, откройте его и тот же лог."
            : "Типовая сетка: обороты по узлам серийной J5, нагрузка — давление ДАД, ЦН или дроссель. Удобно сравнивать логи разных прошивок; применить к таблице нельзя."
        let reasons = a.rejected.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        let suggested = a.cells.filter { $0.factor != nil }.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Учтено записей: \(a.usedRows)").font(.subheadline.weight(.semibold))
                if !model.usesGenericGrid {
                    Button("Применить к таблице (\(suggested))") { confirmApply = true }
                        .disabled(suggested == 0)
                }
            }
            Text("ось X — \(a.xChannel), ось Y — \(a.yChannel); \(a.relation == .inverse ? "таблица AFR: поправка делит значение" : "поправка умножает значение")")
                .foregroundStyle(.secondary)
            if model.usesGenericGrid {
                Text(generic).font(.caption).foregroundStyle(.orange)
            }
            if !reasons.isEmpty {
                Text("Отброшено — \(reasons)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Цифра в ячейке — среднее отклонение коэффициента коррекции от 1,0 (+ — ЭБУ добавлял топливо, смесь по карте бедная). Мелко — число записей. Поправка предлагается от 5 записей и не больше ±25 %.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 820, alignment: .leading)
    }

    private func grid(_ a: FuelCorrectionAnalysis) -> some View {
        let xs = a.xNodes, ys = a.yNodes
        return Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Text("")
                ForEach(0..<a.cols, id: \.self) { c in
                    Text(c < xs.count ? String(format: "%.0f", xs[c]) : "\(c)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ForEach(0..<a.rows, id: \.self) { r in
                GridRow {
                    Text(r < ys.count ? String(format: "%.0f", ys[r]) : "\(r)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    ForEach(0..<a.cols, id: \.self) { c in cell(a[r, c]) }
                }
            }
        }
    }

    private func cell(_ cell: FuelCorrectionAnalysis.Cell) -> some View {
        VStack(spacing: 0) {
            if let trim = cell.meanTrim {
                Text(String(format: "%+.1f", (trim - 1) * 100)).font(.caption.monospacedDigit().weight(.semibold))
            } else {
                Text(" ").font(.caption)
            }
            Text(cell.visits == 0 ? "" : cell.weight > 0 && cell.weight < 1 ? "<1" : String(format: "%.0f", cell.weight))
                .font(.system(size: 8).monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(width: 46, height: 30)
        .background(Self.color(cell))
        .overlay { if cell.factor != nil { Rectangle().stroke(.primary.opacity(0.4), lineWidth: 1) } }
        .help(Self.help(cell))
    }

    private var legend: some View {
        HStack(spacing: 12) {
            swatch(Self.color(.init(visits: 10, weight: 10, meanTrim: 1.1)), "ЭБУ добавлял топливо (+)")
            swatch(Self.color(.init(visits: 10, weight: 10, meanTrim: 0.9)), "ЭБУ убирал топливо (−)")
            swatch(Self.color(.init(visits: 10, weight: 0)), "был, но не в установившемся режиме по ДК")
        }
        .font(.caption)
    }

    private func swatch(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(color).frame(width: 14, height: 14)
            Text(text).foregroundStyle(.secondary)
        }
    }

    /// Red where fuel was added (lean map), blue where removed; intensity by size, faded when few rows.
    static func color(_ cell: FuelCorrectionAnalysis.Cell) -> Color {
        guard let trim = cell.meanTrim else {
            return cell.visits > 0 ? Color.gray.opacity(0.25) : Color.clear
        }
        let strength = min(abs(trim - 1) / 0.15, 1)
        let confidence = min(cell.weight / 5, 1)
        let hue = trim >= 1 ? 0.0 : 0.6
        return Color(hue: hue, saturation: 0.15 + 0.6 * strength, brightness: 0.9).opacity(0.25 + 0.5 * confidence)
    }

    static func help(_ cell: FuelCorrectionAnalysis.Cell) -> String {
        var s = String(format: "Записей (с весом интерполяции): всего %.1f, учтено %.1f", cell.visits, cell.weight)
        if let trim = cell.meanTrim { s += String(format: "\nСредний коэф. коррекции %.3f", trim) }
        if let f = cell.factor { s += String(format: "\nПредлагаемый множитель ячейки ×%.3f", f) }
        return s
    }

    static func describe(_ error: Error) -> String {
        switch error as? FuelCorrectionAnalysis.AnalysisError {
        case .tableNeedsTwoAxes: "У таблицы нет двух вычислимых осей."
        case .noChannel(let axis): "В логе нет колонки для оси \(axis) (для оси давления нужен расширенный кадр J5LS)."
        case .missingColumn(let id): "В логе нет колонки \(id)."
        case nil: error.localizedDescription
        }
    }
}
