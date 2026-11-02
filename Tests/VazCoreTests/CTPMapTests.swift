import Foundation
import Testing
@testable import VazCore

func loadMap(_ name: String) throws -> CTPMap {
    try CTPMap(contentsOf: firmwareDir.appendingPathComponent("maps").appendingPathComponent(name))
}

@Suite struct CTPMapTests {
    @Test(arguments: available(["j5ls_v43.j5", "j5ls_v46.j5", "j5ls_l43.j5", "J5V05N35.j5", "J5v03k22.j5", "J5LS_N35.j5", "j5ls_v43_2010.j5"], in: "maps/"))
    func everyMapParses(name: String) throws {
        let map = try loadMap(name)
        #expect([1, 3].contains(map.version)) // 1 — OpenOLT variant without XOR (J5LS_N35.j5)
        #expect(map.entries.count > 300)
        let imported = map.definition(source: name)
        #expect(imported.definition.tables.count > 300)
        #expect(imported.skipped.count <= 4, "\(imported.skipped)")
        for t in imported.definition.tables {
            #expect(t.byteRange.upperBound <= 0xF000, "\(t.id)")
            for axis in [t.xAxis, t.yAxis].compactMap({ $0 }) {
                #expect(imported.definition.axes[axis]?.points == (axis == t.xAxis ? t.cols : t.rows), "\(t.id) \(axis)")
            }
        }
    }

    /// J5LS V43. Counts match docs/vendor/j5ls_v43_calibs.csv (293 entries,
    /// three of them — two RAM tables of the J5OLT version and the split MAF word — skipped).
    @Test(.enabled(if: hasFirmware("maps/j5ls_v43.j5"))) func j5lsV43() throws {
        let map = try loadMap("j5ls_v43.j5")
        let kinds = Dictionary(grouping: map.entries, by: \.kind).mapValues(\.count)
        #expect(kinds[.constant] == 195 && kinds[.curve] == 72 && kinds[.table] == 26)
        let imported = map.definition(softwareIDs: ["J5LS_V43"], source: "j5ls_v43.j5")
        #expect(imported.skipped.count == 3)
        let def = imported.definition
        #expect(def.tables.filter { $0.id.hasPrefix("c") }.count == 290)

        func table(_ id: String) throws -> TableDefinition { try #require(def.tables.first { $0.id == id }) }

        let ign = try table("c6DC8")
        #expect(ign.name == "УОЗ базовое" && ign.group == "Рабочие режимы / Зажигание")
        #expect(ign.rows == 16 && ign.cols == 16 && ign.type == .s8 && ign.scale == 0.5)
        #expect(ign.xAxis == "rpm16x40" && ign.yAxis == "throttle16")
        #expect(def.axes["rpm16x40"]?.scale == 40)

        // Manifold pressure grid (2 bar MAP sensor): minimum word/60 kPa, range 8248.5/[5EF4] kPa.
        #expect(try table("c5EF2").type == .u16le && table("c5EF2").scale == 1.0 / 60)
        #expect(try table("c5EF4").reciprocal == 8248.5)
        #expect(def.axes["press16"]?.offsetAddress == 0x5EF2)

        // AFR maps use the KWP formula 14.7·(E+128)/256.
        let afr = try table("c6953")
        #expect(abs(afr.value(fromRaw: 128) - 14.7) < 1e-9)

        // Two zone maps share 0x63D3: bits 0–1 and bit 2.
        #expect(try table("c63D3").mask == 3 && table("c63D3_2").mask == 4)

        let flags = def.tables.filter { $0.id.hasPrefix("f") }
        #expect(flags.count == 90)
        #expect(flags.allSatisfy { $0.mask != nil && $0.unit == "0/1" })
    }

    /// CTP's own map of a stock version on that version: grids and values agree with what we
    /// established from the J5V05L19 code.
    @Test func stockMapOnItsFirmware() throws {
        let fw = try load("j5/j5v05n35/J5V05N35.bin")
        let def = try loadMap("J5V05N35.j5").definition(source: "J5V05N35.j5").definition
        let rpm = try #require(def.axes["rpm16x30"]?.values(in: fw.data))
        #expect(rpm.map { Int($0.rounded()) } ==
            [600, 720, 840, 990, 1170, 1380, 1650, 1950, 2310, 2730, 3210, 3840, 4530, 5340, 6300, 7470])
        let minPulse = try #require(def.tables.first { $0.address == 0x5FA8 })
        #expect(abs(fw.values(of: minPulse)[0] - 1.6) < 1e-9)
        let closedLoopAFR = try #require(def.tables.first { $0.address == 0x6713 })
        #expect(fw.values(of: closedLoopAFR).allSatisfy { abs($0 - 14.7) < 1e-9 })
    }

    /// Stock J5 reads the RPM table with `mov a,54h` (30 rpm/step); a J5LS map (40 rpm/step)
    /// laid over a stock image is reported.
    @Test(.enabled(if: hasFirmware("maps/j5ls_v43.j5"))) func mapForAnotherFirmwareIsReported() throws {
        let stock = try load("j5/j5v05n35/J5V05N35.bin")
        #expect(CTPMap.Import.rpmStep(in: stock.data) == 30)
        #expect(try loadMap("J5V05N35.j5").definition(source: "").mismatch(with: stock.data) == nil)
        let j5ls = try loadMap("j5ls_v43.j5").definition(source: "")
        #expect(j5ls.mismatch(with: stock.data)?.contains("40 об/мин") == true)
    }

    /// A real J5LS image with its own map: grids agree, and the V43 map (40 rpm/step) is flagged.
    @Test(.enabled(if: hasFirmware("j5ls/J5LS_N35.BIN"))) func j5lsN35MapOnItsFirmware() throws {
        let fw = try load("j5ls/J5LS_N35.BIN")
        #expect(CTPMap.Import.rpmStep(in: fw.data) == 30)
        let imported = try loadMap("J5LS_N35.j5").definition(source: "")
        #expect(imported.mismatch(with: fw.data) == nil)
        #expect(try loadMap("j5ls_v43.j5").definition(source: "").mismatch(with: fw.data) != nil)
        let rpm = try #require(imported.definition.axes["rpm16x30"]?.values(in: fw.data))
        #expect(rpm.count == 16 && rpm.first! >= 500 && rpm.last! <= 8000 && zip(rpm, rpm.dropFirst()).allSatisfy { $0 < $1 })
    }

    /// The RPM grid follows the firmware's code, not the map's label.
    @Test(.enabled(if: hasFirmware("maps/j5ls_v43.j5"))) func rpmGridFollowsFirmware() throws {
        let stock = try load("j5/j5v05n35/J5V05N35.bin")
        let def = try loadMap("j5ls_v43.j5").definition(source: "").definition(for: stock.data)
        #expect(def.axes["rpm16x40"]?.values(in: stock.data)?.last == 7470) // 249 · 30
    }

    /// The 2010 licensed V43 map re-keyed with the common key: the same tables as j5ls_v43.j5
    /// plus the name of 5F04 bit 2 (fuel-mass correction by pressure with a MAP sensor).
    @Test(.enabled(if: hasFirmware("maps/j5ls_v43_2010.j5"))) func j5lsV43Map2010() throws {
        let old = try loadMap("j5ls_v43.j5").definition(source: "").definition
        let new = try loadMap("j5ls_v43_2010.j5").definition(source: "").definition
        let oldTables = Dictionary(uniqueKeysWithValues: old.tables.map { ($0.id, $0) })
        #expect(new.tables.count == old.tables.count + 1)
        for t in new.tables where t.id != "f5F04.2" {
            #expect(oldTables[t.id]?.address == t.address && oldTables[t.id]?.name == t.name, "\(t.id)")
        }
        let bit = try #require(new.tables.first { $0.id == "f5F04.2" })
        #expect(bit.name.hasPrefix("Использовать поправку Ц") && bit.name.hasSuffix("по давлению при работе с ДАД")) // Latin H in «ЦH»
        #expect(bit.mask == 4)
    }

    /// The same map encrypted with a licence key decodes to addresses above 64 KB.
    @Test func licenceKeyedMapIsRejected() throws {
        // A licensed map XORs the first address of every entry with its own key, on top of the
        // common one. The same layout is made here from a stock map (format 3).
        var data = try Data(contentsOf: firmwareDir.appendingPathComponent("maps/J5V05N35.j5"))
        let key: [UInt8] = [0x24, 0xFA, 0xC0, 0xFB]
        var p = 22
        while p < data.count {
            let type = data[p + 66]
            let length = Int(data[p + 67]) | Int(data[p + 68]) << 8
            let body = p + 69
            if (1...4).contains(type) { for i in 0..<4 { data[body + 4 + i] ^= key[i] } }
            p = body + length
        }
        #expect(throws: CTPMap.ParseError.foreignKey) { try CTPMap(data: data) }
    }

    @Test func maskedWriteKeepsOtherBits() throws {
        var fw = try load("j5/j5v05l19/J5V05L19.BIN")
        let t = TableDefinition(id: "m", name: "m", group: "", address: 0x6000, rows: 1, cols: 1, mask: 0x0C,
                                confidence: .auto)
        fw.write([0b1010_0001], at: 0x6000)
        #expect(fw.rawValues(of: t) == [0])
        fw.setRaw(3, of: t, row: 0, col: 0)
        #expect(fw.data[0x6000] == 0b1010_1101)
        fw.setRaw(9, of: t, row: 0, col: 0) // clamped to the 2-bit range
        #expect(fw.rawValues(of: t) == [3])
    }

    @Test func reciprocalRoundTrip() {
        let t = TableDefinition(id: "r", name: "r", group: "", address: 0, rows: 1, cols: 1, reciprocal: 8248.5,
                                confidence: .auto)
        #expect(abs(t.value(fromRaw: 37) - 222.93) < 0.01)
        #expect(t.raw(fromValue: 222.9) == 37)
        #expect(t.value(fromRaw: 0) == .infinity)
    }

    @Test func otherFilesAreRejected() throws {
        #expect(throws: CTPMap.ParseError.notACTPMap) {
            try CTPMap(data: Data(contentsOf: firmwareDir.appendingPathComponent("j5/j5v05l19/J5V05L19.BIN")))
        }
    }
}
