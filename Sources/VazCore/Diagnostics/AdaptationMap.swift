import Foundation

/// Mixture self-learning kept in battery-backed XRAM `FD00–FEFF`, read by «Снимок блока».
///
/// Traced in J5V05L19 (docs/j5-reverse-notes.md, «Обучение смеси в ОЗУ»):
/// - `FD00` — 16×16 learned coefficient, (E+128)/256, `80h` = 1.0. With the oxygen sensor
///   working the ECU nudges the cell it runs in by ±1 (`0x9D44`, cell index 5Fh); the result is
///   the base of the injection correction (6Fh, `0x488B`) to which the fast O2 regulator adds.
/// - `FE00` — the same table plus `76EF` (correction during canister purge, bit 5Eh), used
///   instead of `FD00` while purging (`0x2916`).
/// - Reset after a RAM checksum error copies `6813` («коэффициент коррекции без ДК») into
///   `FD00` (`0x9DAC`) — `80h` in every stock build checked.
///
/// Stock builds index rows by load (5Ch), J5LS N35 and V2 by throttle (`7208[52h]`), columns by
/// rpm (57h) in both; J5LS reset fills `80h`. Other J5LS builds were not checked.
public struct AdaptationMap: Equatable, Sendable {
    public enum Layout: Equatable, Sendable {
        /// Stock Январь 5.1: rows by load (cycle air).
        case rpmLoad
        /// J5LS: rows by throttle.
        case rpmThrottle

        public var rowTitle: String { self == .rpmLoad ? "нагрузка" : "дроссель" }
        public var rowAxisName: String { self == .rpmLoad ? "load16" : "throttle16" }
    }

    public static let address = 0xFD00
    public static let byteCount = 0x200
    /// Value the ECU starts from: 1.0.
    public static let neutral: UInt8 = 0x80

    /// 512 bytes from `FD00`.
    public let raw: [UInt8]
    public let layout: Layout

    public init?(raw: [UInt8], layout: Layout) {
        guard raw.count == Self.byteCount else { return nil }
        self.raw = raw
        self.layout = layout
    }

    /// From a snapshot: all `23` answers must be there; J5LS is told by its identification.
    public init?(snapshot: ECUSnapshot) {
        var bytes = [UInt8?](repeating: nil, count: Self.byteCount)
        for entry in snapshot.entries {
            let request = Self.bytes(entry.request)
            guard request.count == 5, request[0] == 0x23, let response = entry.response else { continue }
            let data = Self.bytes(response).dropFirst() // after 63
            let start = (Int(request[2]) << 8 | Int(request[3])) - Self.address
            guard start >= 0, data.count == Int(request[4]) else { continue }
            for (i, b) in data.enumerated() where start + i < Self.byteCount { bytes[start + i] = b }
        }
        guard bytes.allSatisfy({ $0 != nil }) else { return nil }
        let isJ5LS = snapshot.entries.contains { $0.request.hasPrefix("1A") && ($0.note ?? "").contains("J5LS") }
        self.init(raw: bytes.map { $0! }, layout: isJ5LS ? .rpmThrottle : .rpmLoad)
    }

    static func bytes(_ hex: String) -> [UInt8] { hex.split(separator: " ").compactMap { UInt8($0, radix: 16) } }

    public enum Table: Sendable { case learned, purge }

    /// Coefficient of cell (row, col); row is load or throttle, col is rpm.
    public func coefficient(_ table: Table = .learned, row: Int, col: Int) -> Double {
        Self.coefficient(raw[(table == .learned ? 0 : 0x100) + row * 16 + col])
    }

    public static func coefficient(_ e: UInt8) -> Double { (Double(e) + 128) / 256 }

    public struct Summary: Equatable, Sendable {
        /// Cells that moved away from 1.0.
        public var changed: Int
        public var min: Double
        public var max: Double
        /// Mean over the changed cells; 1.0 when none changed.
        public var mean: Double
        /// Cells stuck at the learning limit (00 / FF): the ECU could not correct further.
        public var atLimit: Int
    }

    public func summary(_ table: Table = .learned) -> Summary {
        let cells = Array(raw[(table == .learned ? 0 : 0x100)...].prefix(256))
        let moved = cells.filter { $0 != Self.neutral }.map(Self.coefficient)
        return Summary(changed: moved.count,
                       min: moved.min() ?? 1, max: moved.max() ?? 1,
                       mean: moved.isEmpty ? 1 : moved.reduce(0, +) / Double(moved.count),
                       atLimit: cells.filter { $0 == 0x00 || $0 == 0xFF }.count)
    }

    /// Plain-language reading for the owner.
    public var verdict: String {
        let s = summary()
        if s.changed == 0 {
            return "Обучение пустое: все ячейки 1,0. Блок недавно обесточивали (снимали клемму) или ещё не ездили с работающим ДК."
        }
        let percent = (s.mean - 1) * 100
        var text = String(format: "Обучено ячеек: %d из 256, в среднем %+.0f %% топлива.", s.changed, percent)
        if percent > 5 {
            text += " Блок добавляет топливо — смесь сама по себе бедная: подсос воздуха, низкое давление топлива, датчик нагрузки занижает."
        } else if percent < -5 {
            text += " Блок убавляет топливо — смесь сама по себе богатая: датчик нагрузки завышает, форсунки льют, высокое давление топлива."
        } else {
            text += " Поправки небольшие (±5 %) — с составом смеси в обученных режимах порядок."
        }
        if s.atLimit > 0 { text += " \(s.atLimit) ячеек упёрлись в предел обучения — блок больше не может поправить." }
        return text
    }

    /// Axis nodes: from the open firmware's definition when it has them, else the stock J5 grids
    /// (`FuelCorrectionAnalysis.AxisMapping`), marked as typical.
    public func axes(definition: CalibrationDefinition?, firmware: Data?) -> (rpm: [Double], rows: [Double], typical: Bool) {
        if let definition, let firmware,
           let rpm = definition.axes["rpm16"]?.values(in: firmware),
           let rows = definition.axes[layout.rowAxisName]?.values(in: firmware), rpm.count == 16, rows.count == 16 {
            return (rpm, rows, false)
        }
        let rows = layout == .rpmLoad
            ? (0..<16).map { 40 + 31.94 * Double($0) } // mg/cycle, J5V05L19 load16
            : AxisMapping.stockThrottle
        return (AxisMapping.stockRPM, rows, true)
    }
}
