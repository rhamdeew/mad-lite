import Foundation

/// A sensor log read back from `log.csv` (+ `log.json` when present).
public struct SensorLog: Sendable {
    public var session: LogSession?
    /// Channel ids in file order (without `time_ms` and `marker`).
    public var channels: [String]
    public var timeMs: [Int]
    /// Values by channel id; NaN where the cell was empty.
    public var values: [String: [Double]]
    /// (row, text) for rows that carry a marker.
    public var markers: [(row: Int, text: String)]

    public var count: Int { timeMs.count }

    public func column(_ id: String) -> [Double]? { values[id] }

    public enum ReadError: Error, Equatable {
        case noHeader
        case badRow(Int)
    }

    /// Reads a session folder written by `SensorLogWriter` (`log.csv`, `log.json`).
    public init(directory: URL, name: String = "log") throws {
        let csv = try String(contentsOf: directory.appendingPathComponent(name + ".csv"), encoding: .utf8)
        try self.init(csv: csv)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        session = try? decoder.decode(LogSession.self,
                                      from: Data(contentsOf: directory.appendingPathComponent(name + ".json")))
    }

    public init(csv: String) throws {
        var lines = csv.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { throw ReadError.noHeader }
        let header = lines.removeFirst().split(separator: ",").map(String.init)
        guard header.first == "time_ms" else { throw ReadError.noHeader }
        let hasMarker = header.last == "marker"
        channels = Array(header.dropFirst().dropLast(hasMarker ? 1 : 0))
        var columns = [[Double]](repeating: [], count: channels.count)
        timeMs = []
        markers = []
        for (n, line) in lines.enumerated() {
            let (fields, marker) = Self.split(line)
            guard fields.count >= channels.count + 1, let t = Int(fields[0]) else { throw ReadError.badRow(n + 2) }
            timeMs.append(t)
            for i in 0..<channels.count {
                let text = fields[i + 1]
                // `faults` is written as 8 hex digits.
                columns[i].append(channels[i] == "faults" ? Double(Int(text, radix: 16) ?? 0) : Double(text) ?? .nan)
            }
            if let marker, !marker.isEmpty { markers.append((timeMs.count - 1, marker)) }
        }
        values = Dictionary(uniqueKeysWithValues: zip(channels, columns))
        session = nil
    }

    /// Fields before the marker, and the marker (quoted free text, may contain commas).
    static func split(_ line: String) -> ([String], String?) {
        guard let quote = line.firstIndex(of: "\"") else {
            var fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let marker = fields.count > 1 ? fields.removeLast() : nil
            return (fields, marker)
        }
        let fields = line[..<quote].split(separator: ",", omittingEmptySubsequences: false).dropLast().map(String.init)
        let marker = String(line[line.index(after: quote)...].dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        return (fields, marker)
    }
}

/// Where a log row falls on a table: fractional node position along one axis and the
/// log channel that feeds it.
public struct AxisMapping: Sendable {
    public var channel: String
    public var nodes: [Double]

    public init(channel: String, nodes: [Double]) {
        self.channel = channel
        self.nodes = nodes
    }

    /// Grid for looking at a log without the firmware dump (the real grids live in the ROM:
    /// 613C, 6064/6066, 5EF2/5EF4). RPM: the 16 stock J5 nodes (J5V05L19 613C). Load: manifold
    /// pressure when the log has it (J5LS extended frame, not all zero), 16 steps from 20 kPa to the next 10 kPa
    /// above the logged maximum; else cycle air on the stock 40…519 mg grid; else throttle.
    public static func generic(for log: SensorLog) -> (x: AxisMapping, y: AxisMapping)? {
        let rpmChannel = ["rpm_precise", "rpm"].first { has($0, in: log) }
        guard let rpmChannel else { return nil }
        let x = AxisMapping(channel: rpmChannel, nodes: stockRPM)
        // A record that sends the pressure bytes but never fills them (J5LS N35) logs 0 kPa throughout.
        if has("map_kpa", in: log), let top = log.column("map_kpa")?.filter({ !$0.isNaN }).max(), top > 10 {
            let high = max(100, (top / 10).rounded(.up) * 10)
            return (x, AxisMapping(channel: "map_kpa", nodes: linear(from: 20, to: high, count: 16)))
        }
        if has("cycle_air", in: log) {
            return (x, AxisMapping(channel: "cycle_air", nodes: linear(from: 40, to: 40 + 15 * 31.94, count: 16)))
        }
        if has("throttle", in: log) { return (x, AxisMapping(channel: "throttle", nodes: stockThrottle)) }
        return nil
    }

    /// J5V05L19 grids (CalibrationTests.rpmGrid / throttleGrid).
    public static let stockRPM: [Double] = [600, 720, 840, 990, 1170, 1380, 1650, 1950, 2310, 2730, 3210, 3840,
                                            4530, 5340, 6300, 7470]
    public static let stockThrottle: [Double] = [0, 2, 4, 6, 8, 10, 14, 18, 23, 29, 37, 46, 56, 66, 80, 98]

    static func has(_ id: String, in log: SensorLog) -> Bool {
        log.column(id)?.contains { !$0.isNaN } ?? false
    }

    static func linear(from a: Double, to b: Double, count: Int) -> [Double] {
        (0..<count).map { a + (b - a) * Double($0) / Double(count - 1) }
    }

    /// Log channel for an axis, chosen by its unit: rpm, cycle air (мг/такт), throttle (%),
    /// manifold pressure (кПа, J5LS extended frame), coolant (°C).
    public static func channel(for axis: AxisDefinition, in log: SensorLog) -> String? {
        let unit = (axis.unit ?? "").lowercased()
        let candidates: [String] = switch true {
        case unit.contains("об/мин"): ["rpm_precise", "rpm"]
        case unit.contains("мг"): ["cycle_air"]
        case unit.contains("дз") || unit.contains("%"): ["throttle"]
        case unit.contains("кпа"): ["map_kpa"]
        case unit.contains("°c") || unit.contains("град"): ["coolant"]
        default: []
        }
        return candidates.first { id in log.column(id).map { $0.contains { !$0.isNaN } } ?? false }
    }

    /// Two neighbouring nodes and the weight of the upper one, as the ECU's interpolation
    /// sees `value` (clamped to the grid ends).
    public func position(of value: Double) -> (lower: Int, upper: Int, t: Double) {
        guard nodes.count > 1, value > nodes[0] else { return (0, 0, 0) }
        guard let k = nodes.firstIndex(where: { $0 >= value }) else { return (nodes.count - 1, nodes.count - 1, 0) }
        let lo = nodes[k - 1], hi = nodes[k]
        return (k - 1, k, hi > lo ? (value - lo) / (hi - lo) : 0)
    }
}

/// Fuel-map error from the injection correction coefficient (`inj_corr`, 1.0 = no correction):
/// in closed loop the ECU trims fuelling by the narrow-band O2 sensor, so the average trim in a
/// cell is how far the base map is off there. Method: docs/plan-logging.md (no wideband sensor).
public struct FuelCorrectionAnalysis: Sendable {
    public struct Options: Sendable {
        /// Ignore rows on a cold engine (warm-up enrichment is active).
        public var minCoolant = 75.0
        /// Steady state: throttle and rpm must not have moved more than this over `settleMs`.
        public var maxThrottleChange = 3.0
        public var maxRpmChange = 250.0
        public var settleMs = 1000
        /// Cells with less total weight get no suggestion.
        public var minWeight = 5.0
        /// Suggestions are clamped to ±this fraction (a bigger error needs a look, not a click).
        public var maxCorrection = 0.25

        public init() {}
    }

    /// How a table value relates to the amount of fuel.
    public enum Relation: Sendable {
        /// Fuel ∝ value (cyclic fuel, filling, correction coefficients): new = old · trim.
        case proportional
        /// Fuel ∝ 1/value (air-fuel ratio targets): new = old / trim.
        case inverse

        /// AFR maps are inverse; everything else is treated as proportional.
        public static func guess(for table: TableDefinition) -> Relation {
            let text = ((table.unit ?? "") + " " + table.name).lowercased()
            let afr = text.contains("воздух/топливо") || text.contains("состав смеси") || text.contains("afr")
            return afr ? .inverse : .proportional
        }
    }

    public struct Cell: Sendable, Equatable {
        /// Sum of interpolation weights of all rows that touched the cell (≈ number of rows).
        public var visits = 0.0
        /// Same, only rows that passed the filters.
        public var weight = 0.0
        /// Weighted mean of `inj_corr` over the filtered rows.
        public var meanTrim: Double?
        /// Factor to apply to the cell (trim for proportional tables, 1/trim for inverse), clamped.
        public var factor: Double?

        public init(visits: Double = 0, weight: Double = 0, meanTrim: Double? = nil, factor: Double? = nil) {
            self.visits = visits
            self.weight = weight
            self.meanTrim = meanTrim
            self.factor = factor
        }
    }

    public enum AnalysisError: Error, Equatable {
        case tableNeedsTwoAxes
        case noChannel(axis: String)
        case missingColumn(String)
    }

    public let rows: Int
    public let cols: Int
    public let cells: [Cell]
    public let xChannel: String
    public let yChannel: String
    /// Node values of the grid (columns, rows).
    public let xNodes: [Double]
    public let yNodes: [Double]
    /// Rows used / total, and why the rest were dropped.
    public let usedRows: Int
    public let rejected: [String: Int]
    public let relation: Relation

    public subscript(row: Int, col: Int) -> Cell { cells[row * cols + col] }

    public init(log: SensorLog, table: TableDefinition, definition: CalibrationDefinition, firmware data: Data,
                relation: Relation? = nil, options: Options = Options()) throws {
        guard let xKey = table.xAxis, let yKey = table.yAxis,
              let xAxis = definition.axes[xKey], let yAxis = definition.axes[yKey],
              let xNodes = xAxis.values(in: data), let yNodes = yAxis.values(in: data) else {
            throw AnalysisError.tableNeedsTwoAxes
        }
        guard let xChannel = AxisMapping.channel(for: xAxis, in: log) else { throw AnalysisError.noChannel(axis: xKey) }
        guard let yChannel = AxisMapping.channel(for: yAxis, in: log) else { throw AnalysisError.noChannel(axis: yKey) }
        try self.init(log: log, x: AxisMapping(channel: xChannel, nodes: xNodes),
                      y: AxisMapping(channel: yChannel, nodes: yNodes),
                      relation: relation ?? Relation.guess(for: table), options: options)
    }

    /// The same analysis on a grid given by its nodes (no firmware needed): columns follow
    /// `x`, rows follow `y`.
    public init(log: SensorLog, x: AxisMapping, y: AxisMapping, relation: Relation = .proportional,
                options: Options = Options()) throws {
        let xChannel = x.channel, yChannel = y.channel
        func column(_ id: String) throws -> [Double] {
            guard let c = log.column(id) else { throw AnalysisError.missingColumn(id) }
            return c
        }
        let xs = try column(xChannel), ys = try column(yChannel)
        let trim = try column("inj_corr"), lambda = try column("f_lambda")
        let rpm = try column("rpm"), throttle = try column("throttle"), coolant = try column("coolant")
        let cut = log.column("f_fuel_cut"), power = log.column("f_power")

        rows = y.nodes.count
        cols = x.nodes.count
        self.xChannel = xChannel
        self.yChannel = yChannel
        xNodes = x.nodes
        yNodes = y.nodes
        self.relation = relation
        var visits = [Double](repeating: 0, count: rows * cols)
        var weight = visits, sum = visits
        var rejected: [String: Int] = [:]
        var used = 0

        for i in 0..<log.count {
            guard !xs[i].isNaN, !ys[i].isNaN, rpm[i] > 0 else {
                rejected["двигатель стоит", default: 0] += 1
                continue
            }
            let px = x.position(of: xs[i]), py = y.position(of: ys[i])
            let corners = [(py.lower, px.lower, (1 - py.t) * (1 - px.t)), (py.lower, px.upper, (1 - py.t) * px.t),
                           (py.upper, px.lower, py.t * (1 - px.t)), (py.upper, px.upper, py.t * px.t)]
            for (r, c, w) in corners where w > 0 && r < rows && c < cols { visits[r * cols + c] += w }

            let reason: String? = if coolant[i] < options.minCoolant { "холодный двигатель" }
                else if lambda[i] != 1 { "нет регулирования по ДК" }
                else if cut?[i] == 1 { "отсечка топлива" }
                else if power?[i] == 1 { "обогащение по мощности" }
                else if trim[i].isNaN { "нет коэффициента" }
                else if !Self.steady(i, log: log, rpm: rpm, throttle: throttle, options: options) { "переходный режим" }
                else { nil }
            if let reason {
                rejected[reason, default: 0] += 1
                continue
            }
            used += 1
            for (r, c, w) in corners where w > 0 && r < rows && c < cols {
                weight[r * cols + c] += w
                sum[r * cols + c] += w * trim[i]
            }
        }

        let rel = self.relation
        cells = (0..<rows * cols).map { k in
            var cell = Cell(visits: visits[k], weight: weight[k])
            guard weight[k] > 0 else { return cell }
            let mean = sum[k] / weight[k]
            cell.meanTrim = mean
            if weight[k] >= options.minWeight, mean > 0 {
                let raw = rel == .proportional ? mean : 1 / mean
                cell.factor = min(max(raw, 1 - options.maxCorrection), 1 + options.maxCorrection)
            }
            return cell
        }
        usedRows = used
        self.rejected = rejected
    }

    /// Throttle and rpm stayed within limits over the last `settleMs`.
    static func steady(_ i: Int, log: SensorLog, rpm: [Double], throttle: [Double], options: Options) -> Bool {
        let from = log.timeMs[i] - options.settleMs
        var j = i
        while j > 0, log.timeMs[j - 1] >= from { j -= 1 }
        // Not enough history to call it steady (log start, or a gap in the recording).
        guard j < i, log.timeMs[i] - log.timeMs[j] >= options.settleMs / 2 else { return false }
        let t = throttle[j...i].filter { !$0.isNaN }, r = rpm[j...i].filter { !$0.isNaN }
        guard let tMin = t.min(), let tMax = t.max(), let rMin = r.min(), let rMax = r.max() else { return false }
        return tMax - tMin <= options.maxThrottleChange && rMax - rMin <= options.maxRpmChange
    }

    /// Table values after applying the suggested factors (cells without a suggestion unchanged).
    public func corrected(_ values: [Double]) -> [Double] {
        precondition(values.count == cells.count)
        return zip(values, cells).map { v, cell in cell.factor.map { v * $0 } ?? v }
    }
}
