import Foundation

extension CTPMap {
    public struct Import: Sendable {
        public var definition: CalibrationDefinition
        /// Entries that could not be turned into tables, with the reason.
        public var skipped: [String]
    }

    /// Calibration definition built from the map: folders become groups, constants,
    /// curves and tables keep their CTP names, units and conversions, flag bytes become
    /// one 0/1 table per named bit.
    public func definition(softwareIDs: [String] = [], source: String) -> Import {
        var axes: [String: AxisDefinition] = [:]
        var tables: [TableDefinition] = []
        var skipped: [String] = []
        var usedIDs: Set<String> = []
        var folders: [String] = []

        func uniqueID(_ base: String) -> String {
            var id = base, n = 2
            while usedIDs.contains(id) { id = "\(base)_\(n)"; n += 1 }
            usedIDs.insert(id)
            return id
        }

        func axis(_ table: String, points: Int, start: Double, end: Double, unit: String) -> String {
            let (key, def) = Self.axis(table, points: points, start: start, end: end, unit: unit)
            axes[key] = axes[key] ?? def
            return key
        }

        for e in entries {
            // Top-level entries have level 1; an entry of level L sits in the folder of level L − 1.
            folders = Array(folders.prefix(max(e.level - 1, 0)))
            if e.kind == .folder {
                folders.append(e.name)
                continue
            }
            let group = folders.isEmpty ? "Общие" : folders.joined(separator: " / ")

            switch e.kind {
            case .constant, .curve, .table:
                guard let address = e.address, let conversion = e.conversion else { continue }
                guard let type = Self.dataType(e.constType) else {
                    skipped.append("\(e.name) (тип данных \(e.constType))")
                    continue
                }
                let count = e.kind == .constant ? 1 : e.xPoints * (e.kind == .table ? e.zPoints : 1)
                // 0xF000–0xFFFF is external RAM (learning memory of the J5OLT version); addresses
                // above 64 KB (FFFFFCxx) are CTP "virtual" values computed from other calibrations.
                guard address + count * type.size <= 0xF000 else {
                    skipped.append(address > 0xFFFF ? "\(e.name) (виртуальная, нет адреса в прошивке)"
                                                     : "\(e.name) (ОЗУ \(HexFormatter.offset(address, digits: 4)))")
                    continue
                }
                var t = TableDefinition(
                    id: uniqueID("c" + HexFormatter.offset(address, digits: 4)), name: e.name, group: group,
                    address: address, rows: e.kind == .table ? e.zPoints : 1,
                    cols: e.kind == .constant ? 1 : e.xPoints,
                    unit: e.units.isEmpty ? nil : e.units, dataType: type == .u8 ? nil : type,
                    confidence: .likely,
                    notes: e.lowerLimit == 0 && e.upperLimit == 0 ? "Из карты CTP"
                        : "Из карты CTP, пределы \(Self.format(e.lowerLimit))…\(Self.format(e.upperLimit))")
                if e.kind != .constant {
                    t.xAxis = axis(e.xTable, points: e.xPoints, start: e.xStart, end: e.xEnd, unit: e.xUnits)
                }
                if e.kind == .table {
                    t.yAxis = axis(e.zTable, points: e.zPoints, start: e.zStart, end: e.zEnd, unit: e.zUnits)
                }
                if e.shiftMask != 0, e.shiftMask != 0xFFFF { t.mask = Int(e.shiftMask) }
                Self.apply(conversion, to: &t)
                tables.append(t)

            case .flags:
                for (i, address) in e.flagAddresses.enumerated() {
                    guard let address, address < 0xF000 else { continue }
                    for (bit, bitName) in e.bitNames[i].enumerated() where !bitName.isEmpty {
                        tables.append(TableDefinition(
                            id: uniqueID("f" + HexFormatter.offset(address, digits: 4) + ".\(bit)"),
                            name: bitName,
                            group: ([group, e.name] + (e.itemNames[i].isEmpty ? [] : [e.itemNames[i]]))
                                .joined(separator: " / "),
                            address: address, rows: 1, cols: 1, unit: "0/1", mask: 1 << bit, confidence: .likely,
                            notes: "Карта CTP: байт \(HexFormatter.offset(address, digits: 4)), бит \(bit)"))
                    }
                }

            case .folder, .ident:
                continue
            }
        }
        let definition = CalibrationDefinition(softwareIDs: softwareIDs, family: "J5.1", source: source,
                                               axes: axes, tables: tables)
        return Import(definition: definition, skipped: skipped)
    }

    static func dataType(_ constType: UInt8) -> TableDefinition.DataType? {
        switch constType {
        case 0: .u8
        case 1: .s8
        case 2: .u16le
        default: nil // 3 s16 LE, 4/5 big-endian, 6 split MAF word: not used by the J5 maps we have
        }
    }

    /// (raw − offset1) · step / divStep − offset2  →  raw · scale + offset;
    /// inverted / (raw · divStep)  →  reciprocal / raw.
    static func apply(_ c: Conversion, to t: inout TableDefinition) {
        let div = c.divStep == 0 ? 1 : c.divStep
        if c.inverted != 0 {
            t.reciprocal = c.inverted / div
            return
        }
        let scale = c.step / div
        let offset = -c.offset1 * scale - c.offset2
        t.scale = scale == 1 ? nil : scale
        t.offset = offset == 0 ? nil : offset
    }

    /// Axis key and definition for a CTP axis source. Known ids ("!NNN-ADDR[-ADDR|-SCALE]"):
    /// 613C — RPM quantization (scale from the suffix: 40 rpm per step in J5LS V43, 30 in stock),
    /// 6064-6066 — cyclic air filling grid, 5EF2-5EF4 — J5LS manifold pressure grid,
    /// 7208 — throttle quantization. Anything else becomes a plain point index.
    static func axis(_ table: String, points: Int, start: Double, end: Double, unit: String)
        -> (String, AxisDefinition) {
        let n = max(points, 1)
        let step = 256.0 / Double(n)
        let parts = table.split(separator: "-").map(String.init)
        let unitOrNil = unit.isEmpty ? nil : unit

        if table.isEmpty {
            let delta = n > 1 ? (end - start) / Double(n - 1) : 0
            let key = "lin\(n)_\(format(start))_\(format(end))_\(unit)"
            return (key, AxisDefinition(kind: .linear, points: n, unit: unitOrNil, start: start, step: delta))
        }
        switch parts.dropFirst().first {
        case "613C":
            let scale = parts.count > 2 ? Double(parts[2]) ?? 30 : 30
            return ("rpm\(n)x\(format(scale))",
                    AxisDefinition(kind: .inverseLookup, points: n, unit: "об/мин", step: step, scale: scale,
                                   address: 0x613C, length: 256))
        case "6064":
            return ("load\(n)", AxisDefinition(kind: .j5Load, points: n, unit: "мг/такт", step: step,
                                               offsetAddress: 0x6064, gainAddress: 0x6066, divisor: 6))
        case "5EF2":
            // Same quantization as the air-filling grid (assumption): minimum word/60 kPa,
            // 15 steps of 16·2048/(60·[5EF4]) ≈ the map's "range" 8248.5/[5EF4] kPa.
            return ("press\(n)", AxisDefinition(kind: .j5Load, points: n, unit: "кПа", step: step,
                                                offsetAddress: 0x5EF2, gainAddress: 0x5EF4, divisor: 60))
        case "7208":
            return ("throttle\(n)", AxisDefinition(kind: .inverseLookup, points: n, unit: "% ДЗ", step: step,
                                                   scale: 1, address: 0x7208, length: 101))
        default:
            return ("idx\(n)_\(table)", AxisDefinition(kind: .linear, points: n, unit: "точка (\(table))",
                                                       start: 1, step: 1))
        }
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(v)
    }
}

extension CTPMap.Import {
    /// RPM grid step the firmware itself uses, from the code that reads the 0x613C table:
    /// `mov dptr,#613C; mov a,54h` in every stock J5 and in J5LS N35/V2 (54h = rpm/30),
    /// `mov a,55h` in J5LS V43+ and the MAP-sensor builds J5V8HANG / J5-71_map (55h = rpm/40,
    /// the same variable the KWP frame reports as E·40). Nil when neither is found (tuned J5D07T01).
    public static func rpmStep(in data: Data) -> Double? {
        if data.firstRange(of: Data([0x90, 0x61, 0x3C, 0xE5, 0x55])) != nil { return 40 }
        if data.firstRange(of: Data([0x90, 0x61, 0x3C, 0xE5, 0x54])) != nil { return 30 }
        return nil
    }

    /// The definition with RPM grids scaled the way the firmware's code reads them: the step
    /// found in `data` wins over the map's label (J5V8HANG reads 613C with 55h = rpm/40 while
    /// its CTP map says 30).
    public func definition(for data: Data) -> CalibrationDefinition {
        guard let step = Self.rpmStep(in: data) else { return definition }
        var def = definition
        for (key, axis) in def.axes where axis.kind == .inverseLookup && axis.address == 0x613C {
            def.axes[key]?.scale = step
        }
        return def
    }

    /// Why this map probably does not belong to `data`, or nil when nothing contradicts it.
    public func mismatch(with data: Data) -> String? {
        let mapSteps = Set(definition.axes.values.filter { $0.kind == .inverseLookup && $0.address == 0x613C }
            .compactMap(\.scale))
        guard let step = Self.rpmStep(in: data), let mapStep = mapSteps.first, !mapSteps.contains(step) else {
            return nil
        }
        return "Карта рассчитана на сетку оборотов по \(Int(mapStep)) об/мин, а прошивка использует \(Int(step)). "
            + "Похоже, карта от другой прошивки: адреса таблиц могут не совпадать."
    }
}
