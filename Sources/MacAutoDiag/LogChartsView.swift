import Charts
import SwiftUI
import VazCore

/// Log channels over time: one small chart per channel on a shared time axis, user markers
/// as vertical lines, and a hover cursor that reads all charts at the same moment.
struct LogChartsView: View {
    let log: SensorLog
    @AppStorage("logChartChannels") private var stored = "rpm,throttle,cycle_air,map_kpa,inj_corr,ignition,lambda_v"
    /// `--charts-cursor <seconds>` (development, tutorial screenshots): the cursor without a mouse.
    @State private var hoverTime: Double? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--charts-cursor"), i + 1 < args.count else { return nil }
        return Double(args[i + 1])
    }()

    private var selected: [String] {
        stored.split(separator: ",").map(String.init).filter { id in
            log.column(id)?.contains { !$0.isNaN } ?? false
        }
    }

    private static let names: [String: LogChannel] = Dictionary(
        (LogSchema.base + LogSchema.j5ls).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    private var times: [Double] { log.timeMs.map { Double($0) / 1000 } }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    readout
                    ForEach(selected, id: \.self) { chart($0) }
                }
                .padding()
            }
            Divider()
            channelList.frame(width: 240)
        }
    }

    /// Values of every shown channel at the hovered moment.
    @ViewBuilder private var readout: some View {
        if let t = hoverTime, let row = nearestRow(to: t) {
            let parts = selected.map { id in "\(Self.names[id]?.name ?? id) \(format(log.column(id)?[row], id: id))" }
            Text(String(format: "%.1f с: ", t) + parts.joined(separator: " · "))
                .font(.caption.monospacedDigit())
                .lineLimit(2)
        } else {
            Text("Наведите курсор на график — значения всех каналов в этот момент. Вертикальные линии — метки.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chart(_ id: String) -> some View {
        let points = samples(id)
        let channel = Self.names[id]
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(channel?.name ?? id)\(channel.map { $0.unit.isEmpty || $0.unit == "0/1" ? "" : ", \($0.unit)" } ?? "")")
                .font(.caption.weight(.semibold))
            Chart {
                ForEach(points, id: \.0) { t, v in
                    LineMark(x: .value("Время", t), y: .value(id, v))
                        .interpolationMethod(id.hasPrefix("f_") ? .stepEnd : .linear)
                }
                ForEach(Array(log.markers.enumerated()), id: \.offset) { n, marker in
                    RuleMark(x: .value("Время", times[marker.row]))
                        .foregroundStyle(.orange)
                        .annotation(position: .overlay, alignment: .topLeading) {
                            // Labels on the first chart only, staggered over three lines so neighbours don't overlap.
                            if id == selected.first {
                                Text(marker.text).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                                    .fixedSize()
                                    .padding(.top, CGFloat(n % 3) * 12)
                            }
                        }
                }
                if let hoverTime {
                    RuleMark(x: .value("Время", hoverTime)).foregroundStyle(.secondary)
                }
            }
            .chartXScale(domain: (times.first ?? 0)...(max(times.last ?? 1, (times.first ?? 0) + 1)))
            // Small swings (correction 0.95…1.05) must stay visible.
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxisLabel(id == selected.last ? "время, с" : "")
            .frame(height: id == selected.first ? 150 : 110)
            .chartOverlay { proxy in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if !CommandLine.arguments.contains("--charts-cursor") { hoverTime = proxy.value(atX: location.x, as: Double.self) }
                        case .ended:
                            if !CommandLine.arguments.contains("--charts-cursor") { hoverTime = nil }
                        }
                    }
            }
        }
    }

    private var channelList: some View {
        List {
            Section("Каналы") {
                ForEach(log.channels.filter { id in log.column(id)?.contains { !$0.isNaN } ?? false }, id: \.self) { id in
                    Toggle(Self.names[id]?.name ?? id, isOn: Binding(
                        get: { selected.contains(id) },
                        set: { on in
                            var ids = stored.split(separator: ",").map(String.init).filter { $0 != id }
                            if on { ids.append(id) }
                            stored = ids.joined(separator: ",")
                        }))
                }
            }
        }
    }

    /// (time, value) pairs, thinned to ~2000 points so long logs stay responsive.
    private func samples(_ id: String) -> [(Double, Double)] {
        guard let column = log.column(id) else { return [] }
        let step = max(1, column.count / 2000)
        return stride(from: 0, to: column.count, by: step).compactMap { i in
            column[i].isNaN ? nil : (times[i], column[i])
        }
    }

    private func nearestRow(to t: Double) -> Int? {
        guard !times.isEmpty else { return nil }
        let ms = Int(t * 1000)
        let i = log.timeMs.firstIndex { $0 >= ms } ?? log.timeMs.count - 1
        return i > 0 && ms - log.timeMs[i - 1] < log.timeMs[i] - ms ? i - 1 : i
    }

    private func format(_ value: Double?, id: String) -> String {
        guard let value, !value.isNaN else { return "—" }
        return String(format: "%.\(Self.names[id]?.digits ?? 2)f", value)
    }
}
