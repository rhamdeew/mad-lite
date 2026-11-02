import Foundation
import Testing
@testable import VazCore

/// Scripted ECU for protocol tests: answers each request frame via `handler`,
/// echoing the request first like a KKL adapter.
actor ScriptedLine: KLineTransport {
    nonisolated let echoesWrites = true
    private var rx: [UInt8] = []
    private let handler: @Sendable ([UInt8]) -> [[UInt8]]
    private(set) var initCount = 0

    init(handler: @escaping @Sendable ([UInt8]) -> [[UInt8]]) {
        self.handler = handler
    }

    func fastInit() async throws { initCount += 1 }

    func write(_ bytes: [UInt8]) async throws {
        rx += bytes
        let request = try KWPFrame.decode(bytes)
        for data in handler(request.data) {
            // ECU replies with the 4-byte header like J5V05L19 does.
            var frame: [UInt8] = [0x80, request.source, request.target, UInt8(data.count)] + data
            frame.append(KWPFrame.checksum(frame))
            rx += frame
        }
    }

    func read(count: Int, timeout: Duration) async throws -> [UInt8] {
        guard rx.count >= count else { throw KLineError.timeout(expected: count, received: rx.count) }
        defer { rx.removeFirst(count) }
        return Array(rx.prefix(count))
    }

    func flush() async throws { rx.removeAll() }
}

@Suite struct KWPFrameTests {
    @Test func shortHeaderRoundTrip() throws {
        let m = KWPMessage(target: 0x10, source: 0xF1, data: [0x81])
        let bytes = try KWPFrame.encode(m)
        #expect(bytes == [0x81, 0x10, 0xF1, 0x81, 0x03]) // 0x81+0x10+0xF1+0x81 = 0x203
        #expect(try KWPFrame.decode(bytes) == m)
    }

    @Test func longHeaderForMoreThan63Bytes() throws {
        let m = KWPMessage(target: 0xF1, source: 0x10, data: Array(repeating: 0xAA, count: 100))
        let bytes = try KWPFrame.encode(m)
        #expect(bytes.prefix(4) == [0x80, 0xF1, 0x10, 100])
        #expect(try KWPFrame.decode(bytes) == m)
    }

    @Test func badChecksumIsRejected() throws {
        var bytes = try KWPFrame.encode(KWPMessage(target: 0x10, source: 0xF1, data: [0x3E]))
        bytes[bytes.count - 1] &+= 1
        #expect(throws: KWPFrameError.self) { try KWPFrame.decode(bytes) }
    }
}

@Suite struct KWPClientTests {
    /// 34 data bytes of a warm idling engine, values chosen to hit every formula.
    static let liveFrame: [UInt8] = [0x61, 0x01,
        0x08, 0x35, 0x12, 0x00, 0x00, 0x08, 0x00, 0x00, // config, mode, faults (ДТОЖ low)
        130, 128, 0, 20, 80, 30, 31, 128, 0x1C,          // 90 °C, 14.7, 0 %, 800, 800, IAC, corr 1.0, 14°
        0, 176, 80, 112, 0x01,                           // 0 km/h, 14.0 V, 800, 0.547 V, ready
        0xFA, 0x00, 0x5A, 0x00, 0x1C, 0x02,              // 2.0 ms, 9.0 kg/h, 90 mg
        0x32, 0x00, 0x00, 0x00, 0x02, 0x76]              // 1.0 l/h, 0, КС 7602

    func makeClient() -> (KWPClient, ScriptedLine) {
        let line = ScriptedLine { request in
            switch request.first {
            case 0x81: [[0xC1, 0x6B, 0x8F]]
            case 0x21: [Self.liveFrame]
            case 0x18: [[0x58, 0x02, 0x01, 0x17, 0xE0, 0x05, 0x05, 0x60]]
            case 0x14: [[0x54, 0x00, 0x00]]
            case 0x23: [[0x7F, 0x23, 0x78], [0x63, 0xDE, 0xAD]]
            default: [[0x7F, request[0], 0x11]]
            }
        }
        return (KWPClient(transport: line), line)
    }

    @Test func connectReturnsKeyBytes() async throws {
        let (client, line) = makeClient()
        #expect(try await client.connect() == [0x6B, 0x8F])
        #expect(await line.initCount == 1)
    }

    @Test func liveDataIsDecoded() async throws {
        let (client, _) = makeClient()
        let d = try await client.readLiveData()
        #expect(d.coolantTemp == 90)
        #expect(abs(try #require(d.afr) - 14.7) < 1e-9)
        #expect(d.standard == .euro2 && d.coCorrection == nil)
        #expect(d.rpm == 800 && d.idleRpm == 800 && d.idleRpmTarget == 800)
        #expect(d.ignitionAdvance == 14)
        #expect(abs(d.voltage - 14.0) < 1e-9)
        #expect(d.injectionTime == 2.0)
        #expect(d.airFlow == 9.0)
        #expect(d.cycleAir == 90)
        #expect(d.romChecksum == 0x7602)
        #expect(d.mode1[1] && d.mode1[4]) // ХХ, регулирование по ДК
        #expect(d.activeFaults == ["ДТОЖ: низкий сигнал"])
        #expect(d.emergencyModes == ["ДТОЖ неисправен: температура по модели прогрева (7DF7)"])
        #expect(d.configuration1.active == ["датчик детонации"])
    }

    /// Р83 frame (32 data bytes, no oxygen sensor): J5V07J28 in the emulator at 3000 rpm.
    @Test func r83LiveDataIsDecoded() throws {
        let d = try J5LiveData(response: [0x61, 0x01, 0x28, 0x75, 0x24, 0x8C, 0x10, 0x00, 0x00, 0x00,
                                          0x82, 0xF4, 0x2D, 0x4B, 0xFF, 0x48, 0x48, 0x80, 0x45, 0x00,
                                          0xAF, 0x50, 0x61, 0x02, 0x99, 0x02, 0x68, 0x04, 0x62, 0x01,
                                          0xFF, 0xFF, 0x00, 0x00])
        #expect(d.standard == .r83)
        #expect(d.afr == nil && d.lambdaVoltage == nil && d.lambdaFlags == nil)
        #expect(d.coCorrection == -12.0 / 256)
        #expect(d.coolantTemp == 90 && d.rpm == 3000 && d.ignitionAdvance == 34.5)
        #expect(abs(d.voltage - 13.95) < 1e-9 && d.idleRpmTarget == 800)
        #expect(d.injectionTime == 609.0 / 125)
        #expect(d.airFlow == 66.5 && d.cycleAir == 188)
        #expect(d.fuelPerHour == 354.0 / 50 && d.romChecksum == 0)
        #expect(d.mode1.active == ["обогащение по мощности", "зона детонации"])
        #expect(d.activeFaults == ["датчик фазы"])
    }

    /// A Р83 ECU has no oxygen-sensor heater: faults word 1 bit 3 has no name there.
    @Test func r83FaultNamesDiffer() throws {
        var frame = [UInt8](repeating: 0, count: 34)
        frame[0] = 0x61; frame[1] = 0x01
        frame[6] = 0x08 // faults 1 bit 3
        frame[7] = 0x02 // faults 2 bit 1
        #expect(try J5LiveData(response: frame).activeFaults == ["потенциометр CO: низкий сигнал"])
    }

    @Test func dtcsAreParsed() async throws {
        let (client, _) = makeClient()
        let dtcs = try await client.readDTCs()
        #expect(dtcs.map(\.code) == ["P0117", "P0505"])
        #expect(dtcs[0].description.contains("температуры охлаждающей"))
    }

    /// The spec's wording wins; codes outside its appendix come from the general dictionary.
    @Test func dtcDescriptions() {
        #expect(DTC(raw: 0x0122, status: 0).description == "Низкий уровень сигнала с датчика положения дросселя")
        #expect(DTC(raw: 0x0107, status: 0).description == "Низкий уровень выходного сигнала датчика давления воздуха")
        #expect(DTC(raw: 0x0116, status: 0).description.hasPrefix("Выход сигнала"))
        #expect(DTC(raw: 0x3FFF, status: 0).description == "Неизвестный код")
        #expect(DTC.generalDescriptions.count == 618)
    }

    @Test func pendingResponseIsAwaited() async throws {
        let (client, _) = makeClient()
        #expect(try await client.readMemory(address: 0xFD00, count: 2) == [0xDE, 0xAD])
    }

    @Test func negativeResponseThrows() async throws {
        let (client, _) = makeClient()
        await #expect(throws: KWPError.negativeResponse(service: 0x3E, code: 0x11)) {
            try await client.testerPresent()
        }
    }
}

@Suite struct J5LSExtendedTests {
    /// 86 data bytes of a J5LS record with known values at documented offsets.
    static let record: [UInt8] = {
        var d = [UInt8](repeating: 0, count: 86)
        d[8] = 130                                  // coolant 90 °C
        d[11] = 12                                  // throttle 12 %
        d[12] = 75                                  // 3000 rpm
        d[14] = 0x68; d[15] = 0x06                  // period 1640 → 3048.8 rpm
        d[21] = 0xFE; d[22] = 0xFC; d[23] = 0; d[24] = 0xFF // knock: cyl2 −1°, cyl1 −2°, cyl3 0, cyl4 −0.5°
        d[37] = 65                                  // air 25 °C
        d[41] = 128                                 // wideband AFR 14.7
        d[43] = 0xE8; d[44] = 0x03                  // 1000 → 8 ms
        d[53] = 0x94; d[54] = 0x27                  // 10132 → 101.32 kPa
        d[76] = 3                                   // 3rd gear
        return [0x61, 0x8C] + d
    }()

    @Test func decodesDocumentedOffsets() throws {
        let r = try J5LSLiveData(response: Self.record)
        #expect(r.recordID == 0x8C)
        #expect(r.coolantTemp == 90 && r.airTemp == 25 && r.throttle == 12)
        #expect(r.rpm == 3000 && abs(r.preciseRPM - 3048.78) < 0.01)
        #expect(r.knockRetard == [-2, -1, 0, -0.5])
        #expect(abs(r.widebandAFR - 14.7) < 1e-9)
        #expect(r.injectionTime == 8)
        #expect(abs(r.manifoldPressure - 101.32) < 1e-9)
        #expect(r.gear == 3)
    }

    @Test func shortRecordReadsMissingAsZero() throws {
        let r = try J5LSLiveData(response: [0x61, 0x0D] + [UInt8](repeating: 1, count: 50))
        #expect(r.manifoldPressure == 0 && r.gear == 0 && r.oilPressure == 0)
    }

    @Test func detectsFirstSupportedRecord() async throws {
        let line = ScriptedLine { req in
            switch (req[0], req.count > 1 ? req[1] : 0) {
            case (0x81, _): [[0xC1, 0x6B, 0x8F]]
            case (0x21, 0x8C): [[0x7F, 0x21, 0x12]]
            case (0x21, 0x0D): [[0x61, 0x0D] + [UInt8](repeating: 0, count: 60)]
            default: [[0x7F, req[0], 0x11]]
            }
        }
        let client = KWPClient(transport: line, interRequestDelay: .zero)
        #expect(try await client.detectExtendedRecord() == 0x0D)
    }

    @Test func stockFirmwareHasNoExtendedRecord() async throws {
        let line = ScriptedLine { req in [[0x7F, req[0], 0x12]] }
        let client = KWPClient(transport: line, interRequestDelay: .zero)
        #expect(try await client.detectExtendedRecord() == nil)
    }
}
