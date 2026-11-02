import Foundation
import Testing
import VazCore
@testable import VazEmu

let firmwareDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("firmware")

/// Images outside firmware/j5 and firmware/j72 are not in the public edition: tests on them
/// use `.enabled(if:)` or `available(_:)`, so they run where the image exists.
func hasFirmware(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: firmwareDir.appendingPathComponent(path).path)
}

func available(_ paths: [String], in folder: String = "") -> [String] {
    paths.filter { hasFirmware(folder + $0) }
}

/// End-to-end: our KWP client against the real J5V05L19 code running in the emulator.
@Suite(.serialized) struct FirmwareSessionTests {
    /// Powers the ECU with the given sensor inputs (ADC channel → 10-bit value) already present.
    func bootedECU(adc: [Int: UInt16] = [:]) async throws -> EmulatorTransport {
        let rom = try Data(contentsOf: firmwareDir.appendingPathComponent("j5/j5v05l19/J5V05L19.BIN"))
        let line = EmulatorTransport(rom: Array(rom))
        for (channel, value) in adc { await line.setADC(channel: channel, value: value) }
        try await line.boot()
        return line
    }

    @Test func startCommunicationReturnsSpecKeyBytes() async throws {
        let client = KWPClient(transport: try await bootedECU())
        #expect(try await client.connect() == [0x6B, 0x8F])
    }

    /// Coolant sensor on ADC channel 4 (2.151 kΩ pull-up): ~241 Ω at 90 °C → 0.50 V → 103 of 1023.
    /// The firmware's own table 0x6104 turns it into the temperature reported over KWP.
    @Test func liveDataFromFirmware() async throws {
        let client = KWPClient(transport: try await bootedECU(adc: [4: 103]))
        try await client.connect()
        let data = try await client.readLiveData()
        #expect((80...95).contains(data.coolantTemp), "coolant \(data.coolantTemp)")
        #expect(data.rpm == 0) // engine not turning
        // The background ROM checksum (F8F8) needs ~165 s of ECU time, so it is still 0 here.
        #expect(data.romChecksum == 0)
    }

    /// The engine turns in the emulator: 60-2 crank wheel at 3000 rpm, warm engine, MAF
    /// 2.5 V. The firmware's own tooth handler, EX0 chain and tables produce speed,
    /// injection and ignition advance (needs the blank EEPROM: immobilizer not trained).
    @Test func spinningEngineReportsRpmInjectionAndAdvance() async throws {
        let line = try await bootedECU(adc: [
            Sensors.coolantChannel: Sensors.coolant(celsius: 90),
            Sensors.voltageChannel: Sensors.supply(volts: 14),
            Sensors.mafChannel: Sensors.voltage(2.5),
        ])
        let client = KWPClient(transport: line, interRequestDelay: .zero)
        try await client.connect()
        await line.setCrank(rpm: 3000)
        try await line.run(ms: 2000)
        let data = try await client.readLiveData()
        #expect(abs(data.rpm - 3000) <= 40, "rpm \(data.rpm)")
        #expect(data.cycleAir > 50, "ЦН \(data.cycleAir)")
        #expect((1...20).contains(data.injectionTime), "впрыск \(data.injectionTime)")
        #expect((10...45).contains(data.ignitionAdvance), "УОЗ \(data.ignitionAdvance)")
    }

    /// With the immobilizer trained (EEPROM F47D.7 = 0) but no immobilizer answering, the
    /// ECU stores P1600 "Нет связи с иммобилизатором". With a blank EEPROM it does not.
    @Test func troubleCodesReadAndClear() async throws {
        let rom = try Data(contentsOf: firmwareDir.appendingPathComponent("j5/j5v05l19/J5V05L19.BIN"))
        let line = EmulatorTransport(rom: Array(rom))
        await line.setADC(channel: 4, value: 103)
        await line.setEEPROM([0xFF, 0x7F, 0xFF, 0x7F, 0xFF, 0x7F], at: 2)
        try await line.boot()
        try await line.run(ms: 20000)
        let client = KWPClient(transport: line)
        try await client.connect()
        let dtcs = try await client.readDTCs()
        print("DTCs:", dtcs.map { "\($0.code) \(String(format: "%02X", $0.status))" })
        #expect(dtcs.contains { $0.code == "P1600" })
        try await client.clearDTCs()
    }
}

extension FirmwareSessionTests {
    /// A sensor unplugged on the fly: TPS signal drops to 0 V. J5V05L19 shows the current fault
    /// within ~0.75 s and stores P0122 within ~1.25 s (the app re-reads stored codes every 5 s).
    @Test func unpluggedSensorShowsUpWithinSeconds() async throws {
        let line = try await bootedECU(adc: [Sensors.coolantChannel: Sensors.coolant(celsius: 90),
                                             Sensors.throttleChannel: Sensors.voltage(0.5),
                                             Sensors.voltageChannel: Sensors.supply(volts: 14)])
        let client = KWPClient(transport: line, interRequestDelay: .zero)
        try await client.connect()
        #expect(try await client.readLiveData().activeFaults.isEmpty)
        #expect(!(try await client.readDTCs().contains { $0.code == "P0122" }))
        await line.setADC(channel: Sensors.throttleChannel, value: 0)
        try await line.run(ms: 2000)
        let data = try await client.readLiveData()
        #expect(data.activeFaults == ["ДПДЗ: низкий сигнал"])
        #expect(data.emergencyModes == ["ДПДЗ неисправен: аварийный УОЗ (7877) и состав смеси"])
        #expect(try await client.readDTCs().contains { $0.code == "P0122" })
    }
}

@Suite(.serialized) struct StockFirmwareProtocolTests {
    /// The stock J5V05L19 accepts startDiagnosticSession and rejects J5LS records with 7F 21 12.
    @Test func stockFirmwareRejectsJ5LSRecords() async throws {
        let rom = try Data(contentsOf: firmwareDir.appendingPathComponent("j5/j5v05l19/J5V05L19.BIN"))
        let line = EmulatorTransport(rom: Array(rom))
        try await line.boot()
        let client = KWPClient(transport: line, interRequestDelay: .zero)
        try await client.connect()
        try await client.startDiagnosticSession()
        #expect(try await client.detectExtendedRecord() == nil)
    }
}
