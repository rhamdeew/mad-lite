import Charts
import SwiftUI
import VazCore

/// Grid editor for one calibration table: heat-mapped cells, axis headers,
/// a value field for the selected cell and a chart for curves.
struct TableEditorView: View {
    @Environment(AppModel.self) private var model
    let table: TableDefinition
    let definition: CalibrationDefinition
    let firmware: Firmware

    @State private var selection: Cell?
    @State private var editText = ""
    @FocusState private var editFocused: Bool
    @AppStorage("show3D") private var show3D = false

    struct Cell: Hashable { var row: Int; var col: Int }

    private var values: [Double] { firmware.values(of: table) }
    private var raws: [Int] { firmware.rawValues(of: table) }
    private var xValues: [Double]? { table.xAxis.flatMap { definition.axes[$0]?.values(in: firmware.data) } }
    private var yValues: [Double]? { table.yAxis.flatMap { definition.axes[$0]?.values(in: firmware.data) } }
    private var comparisonValues: [Double]? { model.comparison?.values(of: table) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if table.rows > 1 && show3D {
                SurfaceView(values: values, rows: table.rows, cols: table.cols,
                            highlighted: selection.map { ($0.row, $0.col) })
            } else {
                // The grid scrolls sideways on its own; a curve's chart fits the window,
                // so a long curve (39 temperature points) is seen whole.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        ScrollView(.horizontal) { grid.padding(.bottom, 8) }
                        if table.rows == 1 && table.cols > 1 {
                            curveChart.frame(height: 240).frame(minWidth: 500)
                        }
                    }
                    .padding()
                }
            }
            Divider()
            editBar
        }
        .onChange(of: selection) { _, cell in
            guard let cell else { return }
            editText = format(values[cell.row * table.cols + cell.col])
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(table.name).font(.title3.bold())
                confidenceBadge
                Spacer()
                if table.rows > 1 {
                    Toggle("3D", isOn: $show3D).toggleStyle(.button)
                }
                if model.canTransfer(table) {
                    Button("Взять из сравнения") { model.transferTable(table) }
                        .help("Скопировать значения этой таблицы из открытого для сравнения образа (\(model.comparisonSoftwareID ?? "сравнение")) в текущий")
                }
                Button("Отменить изменения") { model.revertTable(table) }
                    .disabled(!model.editedOffsets.intersects(integersIn: table.byteRange))
            }
            Text(summary).font(.callout).foregroundStyle(.secondary).monospaced()
            if let notes = table.notes {
                Text(notes).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var summary: String {
        var parts = ["0x" + HexFormatter.offset(table.address, digits: 4), "\(table.rows)×\(table.cols)"]
        if let x = table.xAxis { parts.append("X: \(axisTitle(x))") }
        if let y = table.yAxis { parts.append("Y: \(axisTitle(y))") }
        parts.append("ед.: \(table.unit ?? "сырые")")
        if let s = table.scale, s != 1 { parts.append("×" + String(format: "%g", s)) }
        return parts.joined(separator: "  ·  ")
    }

    private func axisTitle(_ id: String) -> String {
        guard let axis = definition.axes[id] else { return id }
        return axis.unit.map { "\(id), \($0)" } ?? id
    }

    @ViewBuilder private var confidenceBadge: some View {
        switch table.confidence {
        case .confirmed: Label("проверено", systemImage: "checkmark.seal").foregroundStyle(.green)
        case .likely: Label("вероятно", systemImage: "questionmark.circle").foregroundStyle(.orange)
        case .auto: Label("назначение неизвестно", systemImage: "sparkle.magnifyingglass").foregroundStyle(.secondary)
        }
    }

    // MARK: - Grid

    private var grid: some View {
        let (lo, hi) = (values.min() ?? 0, values.max() ?? 1)
        let edited = model.editedOffsets
        return Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            if let xValues {
                GridRow {
                    if table.rows > 1 { axisLabel(yAxisCorner) }
                    ForEach(0..<table.cols, id: \.self) { c in
                        axisLabel(c < xValues.count ? formatAxis(xValues[c]) : "")
                    }
                }
            }
            ForEach(0..<table.rows, id: \.self) { r in
                GridRow {
                    if table.rows > 1 {
                        axisLabel(yValues.map { r < $0.count ? formatAxis($0[r]) : "" } ?? "\(r)")
                    }
                    ForEach(0..<table.cols, id: \.self) { c in
                        cell(row: r, col: c, lo: lo, hi: hi, edited: edited)
                    }
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var yAxisCorner: String { table.yAxis == nil ? "" : "Y \\ X" }

    private func axisLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(minWidth: 44, minHeight: 22)
    }

    private func cell(row: Int, col: Int, lo: Double, hi: Double, edited: IndexSet) -> some View {
        let i = row * table.cols + col
        let value = values[i]
        let isSelected = selection == Cell(row: row, col: col)
        let isEdited = table.offsets(ofCell: i).contains { edited.contains($0) }
        let other = comparisonValues.flatMap { i < $0.count ? $0[i] : nil }
        let differs = other != nil && other != value
        return Text(format(value))
            .fontWeight(isEdited ? .bold : .regular)
            .frame(minWidth: 44, minHeight: 22)
            .background(heat(value, lo: lo, hi: hi))
            .overlay {
                if isSelected {
                    Rectangle().stroke(Color.accentColor, lineWidth: 2)
                } else if isEdited || differs {
                    Rectangle().stroke(.orange, lineWidth: 1.5)
                }
            }
            .help(cellHelp(index: i, other: other))
            .onTapGesture {
                selection = Cell(row: row, col: col)
                editFocused = true
            }
    }

    private func cellHelp(index: Int, other: Double?) -> String {
        var s = "0x\(HexFormatter.offset(table.offsets(ofCell: index)[0], digits: 4)) = \(rawText(raws[index]))"
        if let other { s += "\nв сравниваемой: \(format(other))" }
        return s
    }

    /// Blue → green → red by value position within the table.
    private func heat(_ v: Double, lo: Double, hi: Double) -> Color {
        let t = hi > lo ? (v - lo) / (hi - lo) : 0.5
        return Color(hue: 0.66 * (1 - t), saturation: 0.55, brightness: 0.9).opacity(0.55)
    }

    // MARK: - Chart

    private var curveChart: some View {
        let xs = xValues ?? values.indices.map(Double.init)
        let other = comparisonValues
        return Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("X", xs[min(i, xs.count - 1)]), y: .value("Значение", v), series: .value("Файл", "Текущая"))
                    .foregroundStyle(.blue)
            }
            if let other {
                ForEach(Array(other.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("X", xs[min(i, xs.count - 1)]), y: .value("Значение", v), series: .value("Файл", "Сравнение"))
                        .foregroundStyle(.orange)
                }
            }
            if let selection {
                RuleMark(x: .value("X", xs[min(selection.col, xs.count - 1)])).foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: (xs.min() ?? 0) ... (xs.max() ?? 1))
        .chartXAxisLabel(table.xAxis.map(axisTitle) ?? "индекс")
    }

    // MARK: - Edit bar

    private var editBar: some View {
        HStack {
            if let cell = selection {
                let i = cell.row * table.cols + cell.col
                Text(cellTitle(cell)).monospaced()
                TextField("Значение", text: $editText)
                    .frame(width: 90)
                    .focused($editFocused)
                    .onSubmit { commit(cell) }
                Text(table.unit ?? "").foregroundStyle(.secondary)
                Button("−", action: { nudge(cell, by: -1) }).keyboardShortcut("-", modifiers: [])
                Button("+", action: { nudge(cell, by: 1) }).keyboardShortcut("=", modifiers: [])
                Text("сырое \(rawText(raws[i]))").foregroundStyle(.secondary).monospaced()
            } else {
                Text("Выберите ячейку. Enter — записать значение, «+»/«−» — шаг на 1 единицу.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
    }

    private func cellTitle(_ cell: Cell) -> String {
        var parts: [String] = []
        if let y = yValues, cell.row < y.count { parts.append("Y=\(formatAxis(y[cell.row]))") }
        if let x = xValues, cell.col < x.count { parts.append("X=\(formatAxis(x[cell.col]))") }
        if parts.isEmpty { parts.append("[\(cell.row), \(cell.col)]") }
        return parts.joined(separator: " ")
    }

    private func commit(_ cell: Cell) {
        let normalized = editText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else { return }
        model.setValue(value, table: table, row: cell.row, col: cell.col)
        editText = format(firmware.values(of: table)[cell.row * table.cols + cell.col])
    }

    /// Changes the raw byte by `delta` so one step is exactly one stored unit.
    private func nudge(_ cell: Cell, by delta: Int) {
        let i = cell.row * table.cols + cell.col
        let raw = raws[i] + delta
        guard table.rawRange.contains(raw) else { return }
        model.setRaw(raw, table: table, row: cell.row, col: cell.col)
        editText = format(table.value(fromRaw: raw))
    }

    // MARK: - Formatting

    /// Fine-step tables (coefficients ×1/128) need two decimals, the rest one.
    private func format(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: (table.scale ?? 1) < 0.05 ? "%.2f" : "%.1f", v)
    }

    private func rawText(_ raw: Int) -> String {
        let digits = table.type.size * 2
        let hex = String(UInt16(truncatingIfNeeded: raw) & (digits == 2 ? 0xFF : 0xFFFF), radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, digits - hex.count)) + hex + " (\(raw))"
    }

    /// Whole numbers for rpm/load/temperature grids; two decimals for fine axes (MAF voltage, 0.02 V).
    private func formatAxis(_ v: Double) -> String {
        let step = xValues.flatMap { $0.count > 1 ? abs($0[1] - $0[0]) : nil } ?? 1
        return step < 1 ? String(format: "%.2f", v) : String(Int(v.rounded()))
    }
}
