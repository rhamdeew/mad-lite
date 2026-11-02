import Foundation
import Testing
import VazCore
@testable import VazEmu

/// Every raw Январь 5.1 ROM image in firmware/j5 (EEPROM dumps skipped).
let j5ImagePaths: [String] = {
    let root = firmwareDir.appendingPathComponent("j5")
    return FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        .compactMap { $0 as? URL }
        .filter { ["bin", "abs"].contains($0.pathExtension.lowercased()) }
        .filter { (try? Firmware(contentsOf: $0))?.family == .january51 }
        .map { String($0.path.dropFirst(firmwareDir.path.count + 1)) }
        .sorted()
}()

/// One image per J5 line (2112-41 early/late, 2111-61, 2104-01, Р83 2111-71 and 2112-71).
/// All 35 take ~3 min, so the full sweep runs only with `VAZ_ALL_FW=1 swift test`.
let j5SessionPaths = ProcessInfo.processInfo.environment["VAZ_ALL_FW"] != nil ? j5ImagePaths : [
    "j5/j5v05h16/J5V05H16.BIN", "j5/j5v05n35/J5V05N35.bin", "j5/j5v03l25/J5V03L25.BIN",
    "j5/j5v26l52/j5v26l52.bin", "j5/j5v13l05/J5V13L05.bin", "j5/j5v07j28/J5v07j28.bin",
]

/// Our KWP client and live-data decoder against J5 versions other than the reference
/// J5V05L19, running in the emulator.
@Suite struct J5AllFirmwareSessionTests {
    @Test func everyImageIsCovered() {
        #expect(j5ImagePaths.count == 35)
        #expect(Set(j5SessionPaths).isSubset(of: j5ImagePaths))
    }

    /// Warm engine at 3000 rpm, MAF 2.5 V: every version must answer `21 01` with sane values.
    /// Р83 versions (1411010-71: J5V13, J5V07, A5V13, A5V07) send the shorter frame.
    @Test(arguments: j5SessionPaths)
    func engineRunsAndLiveDataDecodes(path: String) async throws {
        let fw = try Firmware(contentsOf: firmwareDir.appendingPathComponent(path))
        let line = EmulatorTransport(rom: Array(fw.data))
        await line.setADC(channel: Sensors.coolantChannel, value: Sensors.coolant(celsius: 90))
        await line.setADC(channel: Sensors.voltageChannel, value: Sensors.supply(volts: 14))
        await line.setADC(channel: Sensors.mafChannel, value: Sensors.voltage(2.5))
        try await line.boot()
        let client = KWPClient(transport: line, interRequestDelay: .zero)
        #expect(try await client.connect() == [0x6B, 0x8F])
        await line.setCrank(rpm: 3000)
        try await line.run(ms: 1500)
        let d = try await client.readLiveData()
        let r83 = fw.identification?.softwareCode == "1411010-71"
        #expect(d.standard == (r83 ? .r83 : .euro2))
        #expect((d.afr == nil) == r83 && (d.coCorrection == nil) != r83)
        #expect((80...95).contains(d.coolantTemp), "ТОЖ \(d.coolantTemp)")
        #expect(abs(d.rpm - 3000) <= 40, "обороты \(d.rpm)")
        #expect(d.cycleAir > 50, "ЦН \(d.cycleAir)")
        #expect((1...20).contains(d.injectionTime), "впрыск \(d.injectionTime)")
        #expect((10...45).contains(d.ignitionAdvance), "УОЗ \(d.ignitionAdvance)")
        #expect(abs(d.voltage - 14) < 0.3, "напряжение \(d.voltage)")
        _ = try await client.readDTCs()
    }
}
