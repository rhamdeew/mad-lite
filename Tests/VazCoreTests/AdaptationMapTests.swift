import Foundation
import Testing
@testable import VazCore

@Suite struct AdaptationMapTests {
    /// A snapshot whose RAM reads return `memory` (512 bytes from FD00).
    static func snapshot(_ memory: [UInt8], id: String = "SAMARA-1.5L,16V 08-05-2003 J5V05L19") -> ECUSnapshot {
        var entries = [ECUSnapshot.Entry(title: "", request: "1A 80", response: "5A 80", note: id)]
        for (_, request) in ECUSnapshot.memoryRequests {
            let start = (Int(request[2]) << 8 | Int(request[3])) - 0xFD00
            let data = Array(memory[start..<start + Int(request[4])])
            entries.append(.init(title: "", request: ECUSnapshot.hex(request), response: ECUSnapshot.hex([0x63] + data)))
        }
        return ECUSnapshot(source: "test", keyBytes: [0x6B, 0x8F], entries: entries)
    }

    @Test func neutralTableIsEmptyLearning() throws {
        let map = try #require(AdaptationMap(snapshot: Self.snapshot(Array(repeating: 0x80, count: 512))))
        #expect(map.layout == .rpmLoad)
        #expect(map.summary().changed == 0)
        #expect(map.verdict.hasPrefix("Обучение пустое"))
    }

    @Test func leanCellsAreReadAsAddedFuel() throws {
        var memory = [UInt8](repeating: 0x80, count: 512)
        memory[3 * 16 + 5] = 0x90      // row 3, rpm column 5: (0x90+128)/256 = 1.0625
        memory[3 * 16 + 6] = 0xFF      // at the limit
        memory[0x100] = 0x70           // purge table, not counted in the learned summary
        let map = try #require(AdaptationMap(snapshot: Self.snapshot(memory, id: "04-11-2005 J5LS_N35")))
        #expect(map.layout == .rpmThrottle)
        #expect(map.coefficient(row: 3, col: 5) == 1.0625)
        #expect(map.coefficient(.purge, row: 0, col: 0) == 0.9375)
        let s = map.summary()
        #expect(s.changed == 2 && s.atLimit == 1)
        #expect(map.verdict.contains("добавляет топливо"))
        #expect(map.verdict.contains("упёрлись в предел"))
    }

    @Test func incompleteReadsGiveNoMap() {
        var s = Self.snapshot(Array(repeating: 0x80, count: 512))
        s.entries[3].response = nil
        s.entries[3].error = "отказ 7F 23 31"
        #expect(AdaptationMap(snapshot: s) == nil)
    }

    /// With the ECU's own firmware the axes come from its grids; without it, the stock ones.
    @Test func axesFromFirmwareOrTypical() throws {
        let map = try #require(AdaptationMap(raw: Array(repeating: 0x80, count: 512), layout: .rpmLoad))
        let typical = map.axes(definition: nil, firmware: nil)
        #expect(typical.typical && typical.rpm == AxisMapping.stockRPM)
        let fw = try Firmware(data: Data(contentsOf: firmwareDir.appendingPathComponent("j5/j5v05l19/J5V05L19.BIN")))
        let real = map.axes(definition: fw.definition, firmware: fw.data)
        #expect(!real.typical)
        #expect(zip(real.rpm, AxisMapping.stockRPM).allSatisfy { abs($0 - $1) < 30 })
        #expect(abs(real.rows[0] - 40) < 5 && real.rows[15] > 400)
    }
}

@Suite struct SnapshotCompareTests {
    @Test func changedAnswersAndMapDifference() throws {
        var memory = [UInt8](repeating: 0x80, count: 512)
        var old = AdaptationMapTests.snapshot(memory)
        old.entries.append(.init(title: "Коды неисправностей", request: "18 00 00 00", response: "58 00", note: "кодов нет"))
        old.entries.append(.init(title: "Расширенный J5LS (21 8C)", request: "21 8C", error: "отказ 7F 21 12"))
        memory[0x22] = 0x88
        var new = AdaptationMapTests.snapshot(memory)
        new.entries.append(.init(title: "Коды неисправностей", request: "18 00 00 00", response: "58 01 01 22 E0",
                                 note: "P0122 Низкий уровень сигнала с датчика положения дросселя"))
        let changes = new.differences(from: old)
        // Codes changed, the RAM is compared as a map, 21 8C is gone from the newer one.
        #expect(changes.map(\.request) == ["18 00 00 00", "21 8C"])
        #expect(changes[0].old == "кодов нет" && changes[0].new?.hasPrefix("P0122") == true)
        #expect(changes[1].new == nil && changes[1].old == "отказ 7F 21 12")
        let a = try #require(AdaptationMap(snapshot: old)), b = try #require(AdaptationMap(snapshot: new))
        #expect(b.coefficient(row: 2, col: 2) - a.coefficient(row: 2, col: 2) == 8.0 / 256)
    }
}
