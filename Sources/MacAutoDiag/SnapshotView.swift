import SwiftUI
import VazCore

/// A saved «Снимок блока»: what the ECU answered and its mixture learning; with a second
/// snapshot, only what changed between them.
struct SnapshotView: View {
    @Environment(AppModel.self) private var model
    let opened: AppModel.OpenedSnapshot

    private var snapshot: ECUSnapshot { opened.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let baseline = opened.baseline {
                        differences(from: baseline.snapshot)
                    } else {
                        answers
                    }
                    learning
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 600, idealHeight: 800)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let baseline = opened.baseline {
                    Text("Сравнение снимков").font(.title3.bold())
                    Text("было: \(baseline.name) (\(Self.date(baseline.snapshot.taken)))")
                    Text("стало: \(opened.name) (\(Self.date(snapshot.taken)))")
                } else {
                    Text("Снимок блока").font(.title3.bold())
                    Text("\(opened.name) · \(Self.date(snapshot.taken)) · \(snapshot.source)")
                    Text("\(snapshot.summary.prefix(1).uppercased() + snapshot.summary.dropFirst()) · KeyBytes \(snapshot.keyBytes) · программа \(snapshot.appVersion)")
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            Spacer()
            Button(opened.baseline == nil ? "Сравнить с другим снимком…" : "Сравнить с другим…") {
                model.presentSnapshotPanel(compare: true)
            }
            Button("Закрыть") { model.openedSnapshot = nil }
                .keyboardShortcut(.cancelAction)
        }
    }

    /// Every request with its decoded or raw answer; RAM reads are shown as the map below.
    private var answers: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ответы блока").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(snapshot.entries.enumerated()).filter { !ECUSnapshot.isMemory($0.element) }, id: \.offset) { _, entry in
                    GridRow {
                        Text(entry.title).foregroundStyle(.secondary)
                        Text(entry.request).font(.body.monospaced())
                        VStack(alignment: .leading, spacing: 2) {
                            if let note = entry.note { Text(note) }
                            if let response = entry.response {
                                Text(response).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if let error = entry.error { Text(error).foregroundStyle(.orange) }
                        }
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func differences(from old: ECUSnapshot) -> some View {
        let changes = snapshot.differences(from: old)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Что изменилось в ответах").font(.headline)
            if changes.isEmpty {
                Text("Ответы одинаковые (кроме ОЗУ — см. обучение ниже).").foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(changes) { change in
                    GridRow {
                        Text(change.title).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("было: " + (change.old ?? "не запрашивалось")).foregroundStyle(.secondary)
                            Text("стало: " + (change.new ?? "не запрашивалось"))
                        }
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder private var learning: some View {
        if let map = AdaptationMap(snapshot: snapshot) {
            let baseline = opened.baseline.flatMap { AdaptationMap(snapshot: $0.snapshot) }
            // Real axes only from the very firmware the snapshot came from.
            let id = snapshot.entries.first { $0.request == "1A 80" }?.note
            let same = model.primary?.softwareID.map { id?.contains($0) == true } == true
            AdaptationMapView(map: map, definition: same ? model.definition : nil,
                              firmware: same ? model.primary?.data : nil, baseline: baseline)
        } else {
            Text("Обучение смеси: в снимке нет всех ответов на чтение ОЗУ FD00–FEFF.").foregroundStyle(.secondary)
        }
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .standard)
    }
}
