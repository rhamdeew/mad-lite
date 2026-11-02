import SwiftUI
import VazCore

/// Mixture self-learning from a snapshot as a 16×16 heat map: orange where the ECU adds fuel,
/// blue where it takes fuel away, grey where the cell never moved from 1.0.
struct AdaptationMapView: View {
    let map: AdaptationMap
    /// Open firmware, for real axis nodes; without it the stock grids are shown.
    var definition: CalibrationDefinition?
    var firmware: Data?
    /// Second snapshot to compare with: cells then show the change, not the value.
    var baseline: AdaptationMap?
    @State private var table: AdaptationMap.Table = .learned
    /// Set by the user; nil follows the default: collapsed while there is nothing to show.
    @State private var expanded: Bool?

    /// Nothing learned (or, comparing, nothing changed): the grid would be all «·».
    private var isEmpty: Bool {
        guard let baseline else { return map.summary().changed == 0 }
        return map.raw == baseline.raw
    }

    var body: some View {
        let open = expanded ?? !isEmpty
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    withAnimation(.snappy) { expanded = !open }
                } label: {
                    Label(baseline == nil ? "Обучение смеси (из снимка)" : "Обучение смеси: изменение между снимками",
                          systemImage: open ? "chevron.down" : "chevron.right")
                        .font(.headline)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if open { picker }
            }
            Text(baseline == nil ? map.verdict : changeText)
                .fixedSize(horizontal: false, vertical: true)
            if open { details }
        }
        // A new snapshot (or comparison) gets the default again.
        .onChange(of: map.raw) { expanded = nil }
        .onChange(of: baseline?.raw) { expanded = nil }
    }

    private var picker: some View {
        Picker("", selection: $table) {
            Text("Обучение").tag(AdaptationMap.Table.learned)
            Text("При продувке адсорбера").tag(AdaptationMap.Table.purge)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Вторая таблица — та же плюс поправка 76EF; блок берёт её, пока продувается адсорбер.")
    }

    @ViewBuilder private var details: some View {
        let axes = map.axes(definition: definition, firmware: firmware)
        grid(rpm: axes.rpm, rows: axes.rows)
        Text("Строки — \(map.layout.rowTitle)\(map.layout == .rpmLoad ? ", мг/такт" : ", %"), столбцы — обороты. "
             + (axes.typical ? "Подписи осей — по типовой сетке J5 (откройте прошивку блока для точных). " : "")
             + (baseline == nil ? "В ячейке — поправка топлива в %, «·» — без поправки."
                                : "В ячейке — на сколько процентов изменилась поправка, «·» — не изменилась."))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var changeText: String {
        guard let baseline else { return "" }
        let moved = (0..<256).filter { map.raw[$0] != baseline.raw[$0] }.count
        return moved == 0 ? "Между снимками обучение не изменилось."
                          : "Изменилось ячеек: \(moved). В ячейке — насколько изменилась поправка, %."
    }

    private func percent(row: Int, col: Int) -> Double {
        let now = map.coefficient(table, row: row, col: col)
        guard let baseline else { return (now - 1) * 100 }
        return (now - baseline.coefficient(table, row: row, col: col)) * 100
    }

    private func grid(rpm: [Double], rows: [Double]) -> some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Text("")
                ForEach(0..<16, id: \.self) { col in
                    Text(String(format: "%.0f", rpm[col])).font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            // Highest load on top, as on a map of the engine's working range.
            ForEach((0..<16).reversed(), id: \.self) { row in
                GridRow {
                    Text(String(format: "%.0f", rows[row])).font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                    ForEach(0..<16, id: \.self) { col in
                        let p = percent(row: row, col: col)
                        Text(abs(p) < 0.2 ? "·" : String(format: "%+.0f", p))
                            .font(.system(size: 10).monospacedDigit())
                            .frame(minWidth: 30, maxWidth: .infinity, minHeight: 20)
                            .background(Self.color(p), in: RoundedRectangle(cornerRadius: 3))
                            .help(String(format: "обороты %.0f, %@ %.0f: коэффициент %.3f",
                                         rpm[col], map.layout.rowTitle, rows[row],
                                         map.coefficient(table, row: row, col: col)))
                    }
                }
            }
        }
    }

    /// ±20 % reaches full colour.
    static func color(_ percent: Double) -> Color {
        let t = min(abs(percent) / 20, 1)
        if abs(percent) < 0.2 { return Color.secondary.opacity(0.12) }
        return (percent > 0 ? Color.orange : Color.blue).opacity(0.2 + 0.6 * t)
    }
}
