import Foundation
import Testing
@testable import VazCore

/// I205DO54 is the Январь 7.2 image the XDF and the code trace were checked against.
@Suite struct J72CalibrationTests {
    let fw: Firmware
    let def: CalibrationDefinition

    init() throws {
        fw = try load("j72/i205do54/i205do54.bin")
        def = try #require(fw.definition)
    }

    func table(_ id: String) throws -> TableDefinition {
        try #require(def.tables.first { $0.id == id })
    }

    @Test func definitionIsBoundToThisSoftware() {
        #expect(fw.family == .january72)
        #expect(fw.softwareID == "I205DO54")
        #expect(def.softwareIDs == ["I205DO54"])
        #expect(def.tables.count > 400)
        #expect(def.tables.contains { $0.confidence == .confirmed })
    }

    @Test func tablesStayInsideTheCalibrationArea() {
        // Interpolation code starts at 0xAEDF. The header 0x6000–0x604F is not a table.
        for t in def.tables {
            #expect(t.address >= 0x5F00 && t.byteRange.upperBound <= 0xAEDF, "\(t.id)")
            #expect(t.byteRange.lowerBound >= 0x6050 || t.address < 0x6000, "\(t.id) в заголовке")
        }
    }

    @Test func tablesDoNotOverlap() {
        let spans = def.tables.map { ($0.id, $0.byteRange) }.sorted { $0.1.lowerBound < $1.1.lowerBound }
        for pair in zip(spans, spans.dropFirst()) where pair.0.1.overlaps(pair.1.1) {
            Issue.record("\(pair.0.0) пересекается с \(pair.1.0)")
        }
    }

    /// Same breakpoints as J5V05L19: the 0x613C grid bytes match and the code indexes it by 54h.
    @Test func rpmGridMatchesJanuary51() throws {
        let rpm = try #require(def.axes["rpm16"]?.values(in: fw.data))
        #expect(rpm.map { Int($0.rounded()) } ==
            [600, 720, 840, 990, 1170, 1380, 1650, 1950, 2310, 2730, 3210, 3840, 4530, 5340, 6300, 7470])
    }

    @Test func loadGridUsesTheSameFormulaAsJanuary51() throws {
        // 0x6064 = 175 (little-endian), gain 0x6066 = 195. Node 0 = 175 / 6.
        let load = try #require(def.axes["load16"]?.values(in: fw.data))
        #expect(load.count == 16)
        #expect(abs(load[0] - 175.0 / 6) < 0.01)
        #expect(load[1] > load[0])
    }

    @Test func economicIgnitionMap() throws {
        let ign = try table("t6AC8")
        #expect(ign.rows == 16 && ign.cols == 16 && ign.xAxis == "rpm16" && ign.yAxis == "load16")
        #expect(ign.confidence == .confirmed)
        #expect(ign.unit == "°")
        let values = fw.values(of: ign)
        #expect(values[0] == 21.5) // raw 0x2B
        #expect(values[1] == 22.5)
    }

    @Test func economicMixtureIsStoichiometricInTheIdleCorner() throws {
        let mix = try table("t6613")
        #expect(mix.confidence == .confirmed)
        #expect(mix.unit == "AFR")
        #expect(abs(fw.values(of: mix)[0] - 14.7) < 0.001)
    }

    @Test func coolantSensorStoresTemperaturePlus60() throws {
        let sensor = try table("t6104")
        #expect(sensor.cols == 32 && sensor.confidence == .confirmed)
        // Index 20 is raw 80 → 20 °C. The curve falls as the ADC index rises (NTC).
        let values = fw.values(of: sensor)
        #expect(abs(values[20] - 20) < 0.001)
        #expect(values[0] > values[31])
    }

    @Test func mafFailureFillingUsesTheThrottleAxis() throws {
        let map = try table("t726D")
        #expect(map.rows == 16 && map.cols == 16)
        #expect(map.xAxis == "rpm16" && map.yAxis == "throttle16")
        #expect(map.unit == "мг/цикл")
    }

    @Test func editingWritesTheRawByte() throws {
        var copy = fw
        let ign = try table("t6AC8")
        copy.setValue(25.5, of: ign, row: 0, col: 1)
        #expect(copy.data[0x6AC9] == 51)
    }

    /// The 21 01 address list. Same IRAM order as J5; lambda voltage moved F815 → F964,
    /// and one extra XRAM word (F93B) follows the checksum word.
    @Test func diagnosticFrameList() {
        let list = Data([
            0x20, 0x21, 0x2B, 0x2C, 0x5B, 0x23, 0x24, 0x25, 0x49, 0x61, 0x52, 0x55, 0x53, 0x64, 0x65, 0x6F, 0x00,
            0xF8, 0x44, 0xF8, 0xAE, 0xF9, 0x78, 0xF8, 0x49, 0xF9, 0x64, 0xF8, 0x10, 0x00, 0x00,
            0xF8, 0x41, 0xF8, 0x08, 0xF8, 0x2E, 0xF8, 0x62, 0xF8, 0x74, 0xF8, 0xF8, 0xF9, 0x3B, 0x00, 0x00,
        ])
        #expect(fw.data[0xBE75 ..< 0xBE75 + list.count] == list)
    }
}

/// The main maps sit at the same addresses in every raw Январь 7.2 image we have.
/// The full I205DO54 definition is not applied to them: only these entry points were checked.
@Suite struct J72SharedMapAddressesTests {
    static let maps: [UInt16] = [
        0x613C, 0x6104, 0x6613, 0x6713, 0x6953, 0x6AC8, 0x6CC8, 0x6DC8,
        0x726D, 0x7877, 0x75EF, 0x7208, 0x6813, 0x8E2A,
    ]

    @Test func everyRawImageLoadsTheSameMaps() throws {
        let files = FileManager.default.enumerator(at: firmwareDir.appendingPathComponent("j72"), includingPropertiesForKeys: nil)!
        var seen = 0
        for case let url as URL in files {
            // The enumerator also yields directories (a201co56, …). Only raw images.
            guard ["bin", "abs"].contains(url.pathExtension.lowercased()) else { continue }
            let data = try Data(contentsOf: url)
            guard data.count >= 0x10000, !data.starts(with: Data("SMS-Soft".utf8)) else { continue }
            let image = data.prefix(0x10000)
            seen += 1
            for addr in Self.maps {
                let opcode = Data([0x90, UInt8(addr >> 8), UInt8(addr & 0xFF)])
                #expect(image.range(of: opcode) != nil, "\(url.lastPathComponent) не читает \(String(addr, radix: 16))")
            }
        }
        #expect(seen >= 25)
    }
}
