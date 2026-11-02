import Foundation
import Testing
import VazCore

/// Transferring calibration tables between two images of the same J5LS family
/// (the UI's "Взять из сравнения" / "Перенести калибровки"): copying a table's cells
/// from a source image makes the destination's values match it, bit-exact for packed flags.
@Suite struct CalibrationTransferTests {
    func load(_ path: String) throws -> Firmware {
        try Firmware(data: Data(contentsOf: firmwareDir.appendingPathComponent(path)), name: path)
    }

    func def() throws -> CalibrationDefinition {
        let map = try CTPMap(contentsOf: firmwareDir.appendingPathComponent("maps/J5V05N35.j5"))
        return map.definition(softwareIDs: ["J5V05N35"], source: "J5V05N35.j5").definition
    }

    func copyTable(_ table: TableDefinition, from source: Firmware, into dest: inout Firmware) {
        let raw = source.rawValues(of: table)
        for i in 0..<table.count { dest.setRaw(raw[i], of: table, row: i / table.cols, col: i % table.cols) }
    }

    @Test func transferMakesValuesMatchSource() throws {
        let def = try def()
        var dest = try load("j5/j5v05n35/J5V05N35.bin")
        let source = try load("j5/j5v05l19/J5V05L19.BIN")
        let tables = def.tables.filter { $0.byteRange.upperBound <= 0x10000 }
        #expect(!tables.isEmpty)
        for table in tables.prefix(60) {
            copyTable(table, from: source, into: &dest)
            #expect(dest.rawValues(of: table) == source.rawValues(of: table), "\(table.name)")
        }
    }

    /// Copying a masked flag with an identical source leaves the shared byte unchanged — the
    /// copy touches only that flag's bits, not its neighbours.
    @Test func maskedFlagKeepsNeighbourBits() throws {
        let def = try def()
        let masked = def.tables.filter { ($0.mask ?? 0) > 0 && $0.byteRange.upperBound <= 0x10000 }
        try #require(!masked.isEmpty)
        var dest = try load("j5/j5v05l19/J5V05L19.BIN")
        let source = try load("j5/j5v05l19/J5V05L19.BIN")
        for t in masked.prefix(30) {
            let before = dest.bytes(of: t)
            copyTable(t, from: source, into: &dest)
            #expect(dest.bytes(of: t) == before, "\(t.name)")
        }
    }

    /// The code region (outside any mapped table) is untouched by a full transfer.
    @Test func transferLeavesCodeUntouched() throws {
        let def = try def()
        var dest = try load("j5/j5v05n35/J5V05N35.bin")
        let codeBefore = Array(dest.data.prefix(0x5000))
        let source = try load("j5/j5v05l19/J5V05L19.BIN")
        for t in def.tables where t.byteRange.upperBound <= 0x10000 { copyTable(t, from: source, into: &dest) }
        #expect(Array(dest.data.prefix(0x5000)) == codeBefore)
    }

    /// A transfer is reversible: restoring a table's original bytes undoes it (the UI's
    /// "Отменить изменения").
    @Test func transferIsReversible() throws {
        let def = try def()
        var dest = try load("j5/j5v05n35/J5V05N35.bin")
        let source = try load("j5/j5v05l19/J5V05L19.BIN")
        let table = try #require(def.tables.first { $0.rows > 1 && $0.byteRange.upperBound <= 0x10000 })
        let original = dest.bytes(of: table)
        copyTable(table, from: source, into: &dest)
        #expect(dest.bytes(of: table) != original)       // actually changed
        dest.write(original, at: table.address)          // revert
        #expect(dest.bytes(of: table) == original)
    }

    /// Transferring twice gives the same result as once (idempotent).
    @Test func transferIsIdempotent() throws {
        let def = try def()
        var dest = try load("j5/j5v05n35/J5V05N35.bin")
        let source = try load("j5/j5v05l19/J5V05L19.BIN")
        let tables = def.tables.filter { $0.byteRange.upperBound <= 0x10000 }
        for t in tables { copyTable(t, from: source, into: &dest) }
        let once = dest.data
        for t in tables { copyTable(t, from: source, into: &dest) }
        #expect(dest.data == once)
    }

    /// Writing a masked flag with a *different* value changes only its own bits; the rest of
    /// the shared byte is preserved (the copy path uses this `setRaw`).
    @Test func maskedFlagWriteIsolatesItsBits() throws {
        let def = try def()
        let t = try #require(def.tables.first { ($0.mask ?? 0) > 0 && $0.byteRange.upperBound <= 0x10000 })
        var fw = try load("j5/j5v05l19/J5V05L19.BIN")
        let b = fw.data.startIndex + t.address
        let before = fw.data[b]
        let cur = fw.rawValues(of: t)[0]
        let newRaw = cur == 0 ? 1 : 0
        fw.setRaw(newRaw, of: t, row: 0, col: 0)
        #expect((fw.data[b] & ~UInt8(t.mask!)) == (before & ~UInt8(t.mask!)))  // neighbours kept
        #expect(fw.rawValues(of: t)[0] == newRaw)                              // flag changed
    }
}
