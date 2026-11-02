import SwiftUI
import VazCore

/// Hex dump of `firmware`; bytes that differ from `comparison` are highlighted.
struct HexView: View {
    @Environment(AppModel.self) private var model
    let firmware: Firmware
    let comparison: Firmware?

    static let bytesPerRow = 16
    @State private var highlightedRow: Int?

    private var rowCount: Int { (firmware.size + Self.bytesPerRow - 1) / Self.bytesPerRow }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<rowCount, id: \.self) { row in
                            HexRowView(
                                data: firmware.data,
                                comparison: comparison?.data,
                                row: row,
                                diffOffsets: model.diffOffsets
                            )
                            .background(row == highlightedRow ? Color.accentColor.opacity(0.25) : .clear)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: model.jumpTarget) { _, target in
                    guard let target, target >= 0, target < firmware.size else { return }
                    let row = target / Self.bytesPerRow
                    highlightedRow = row
                    proxy.scrollTo(row, anchor: .center)
                    model.jumpTarget = nil
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private var header: some View {
        let columns = (0..<Self.bytesPerRow).map { HexFormatter.byte(UInt8($0)) }.joined(separator: " ")
        return Text("Адрес  " + columns)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HexRowView: View {
    let data: Data
    let comparison: Data?
    let row: Int
    let diffOffsets: IndexSet

    var body: some View {
        Text(attributed)
            .lineLimit(1)
            .fixedSize()
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        let start = row * HexView.bytesPerRow
        let end = min(start + HexView.bytesPerRow, data.count)
        var line = AttributedString(HexFormatter.offset(start) + "  ")
        line.foregroundColor = .secondary
        var ascii = AttributedString("  ")

        for offset in start..<end {
            let byte = data[data.startIndex + offset]
            var hex = AttributedString(HexFormatter.byte(byte) + " ")
            var char = AttributedString(String(HexFormatter.asciiChar(byte)))
            if diffOffsets.contains(offset) {
                hex.backgroundColor = .orange.opacity(0.45)
                char.backgroundColor = .orange.opacity(0.45)
            } else if byte == 0xFF || byte == 0x00 {
                hex.foregroundColor = .secondary
            }
            line += hex
            ascii += char
        }
        // Pad a short last row so the ASCII column stays aligned.
        if end - start < HexView.bytesPerRow {
            line += AttributedString(String(repeating: "   ", count: HexView.bytesPerRow - (end - start)))
        }
        line += ascii

        // Show the other image's bytes for rows that differ.
        if let comparison, (start..<end).contains(where: diffOffsets.contains) {
            let other = (start..<min(end, comparison.count))
                .map { HexFormatter.byte(comparison[comparison.startIndex + $0]) }
                .joined(separator: " ")
            var tail = AttributedString("   ← " + other)
            tail.foregroundColor = .orange
            line += tail
        }
        return line
    }
}
