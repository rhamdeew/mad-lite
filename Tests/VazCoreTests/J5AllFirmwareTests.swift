import Foundation
import Testing
@testable import VazCore

/// Raw 64 KB Январь 5.1 ROM images listed in firmware/catalog.json, with the published ID.
func j5CatalogImages() throws -> [(path: String, softwareID: String)] {
    struct Entry: Decodable {
        struct File: Decodable { let path: String; let kind: String }
        let software_id: String
        let files: [File]
    }
    let entries = try JSONDecoder().decode([Entry].self,
                                           from: Data(contentsOf: firmwareDir.appendingPathComponent("catalog.json")))
    return entries.flatMap { e in
        e.files.filter { $0.path.hasPrefix("j5/") && $0.kind.hasPrefix("ПЗУ") }.map { ($0.path, e.software_id) }
    }
}

/// Header, identification and checksum parsing on every J5 version, not only J5V05L19.
@Suite struct J5AllFirmwareTests {
    @Test func everyCatalogImageIsIdentified() throws {
        let images = try j5CatalogImages()
        #expect(images.count == 35)
        for (path, published) in images {
            let fw = try load(path)
            #expect(fw.family == .january51, "\(path)")
            // A5V03L25 calls itself "A5_03L25" in both the header and the identification record.
            #expect(fw.softwareID == (published == "A5V03L25" ? "A5_03L25" : published), "\(path)")
            #expect(fw.checksum?.isValid == true, "\(path)")
            let id = try #require(fw.identification, "\(path)")
            #expect(id.softwareCode.wholeMatch(of: /1411010-\d\d/) != nil, "\(path): \(id.softwareCode)")
            #expect(id.date?.wholeMatch(of: /\d\d-\d\d-\d{4}/) != nil, "\(path): \(id.date ?? "-")")
            #expect(id.engine != nil, "\(path)")
        }
    }

    /// Early versions left a stale ID at 0x6020; the identification record (what the ECU
    /// reports to a tester) is the right one.
    @Test func staleHeaderIDIsOverridden() throws {
        let fw = try load("j5/j5v05f16/J5V05F16.BIN")
        #expect(fw.header?.softwareID == "J5V05F01")
        #expect(fw.softwareID == "J5V05F16")
    }

    /// J5V26K23 keeps each identification field as a ready `5A` frame; the trailing
    /// checksum byte (here printable 'd', 'e', 'l') must not stick to the text.
    @Test func identificationStoredAsResponseFrames() throws {
        let id = try #require(try load("j5/j5v26k23/J5V26K23.bin").identification)
        #expect(id.softwareCode == "1411010-04")
        #expect(id.engine == "LADA -1.45L, 8V")
        #expect(id.date == "10-06-2002")
        #expect(id.softwareID == "J5V26K23")
    }

    /// J7.2 keeps the 0x6020 header ID: A205DM53 carries Itelma's ID in its identification record.
    @Test func january72KeepsHeaderID() throws {
        let fw = try load("j72/a205dm53/A205DM53-000C.bin")
        #expect(fw.identification?.softwareID == "I205DM53")
        #expect(fw.softwareID == "A205DM53")
    }
}
