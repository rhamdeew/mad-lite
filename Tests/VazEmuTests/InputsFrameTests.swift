import Foundation
import Testing
import VazCore
@testable import VazEmu

/// `21 03` against the real firmware: each byte follows its own A/D channel.
@Suite(.serialized) struct InputsFrameTests {
    func client(_ path: String, adc: [Int: UInt16]) async throws -> KWPClient {
        let line = EmulatorTransport(rom: Array(try Data(contentsOf: firmwareDir.appendingPathComponent(path))))
        for (channel, value) in adc { await line.setADC(channel: channel, value: value) }
        try await line.boot()
        let client = KWPClient(transport: line)
        try await client.connect()
        return client
    }

    /// 10-bit inputs come back as their upper 8 bits; byte 5 is the oxygen sensor in Euro 2.
    @Test func euro2() async throws {
        let c = try await client("j5/j5v05l19/J5V05L19.BIN", adc: [4: 103, 0: 512, 1: 600, 3: 200, 10: 100])
        let i = try #require(try await c.readInputs())
        #expect([i.coolantCode, i.mafCode, i.supplyCode, i.throttleCode] == [25, 128, 150, 50])
        #expect(abs(i.fifthVolts(.euro2) - 0.47) < 0.01) // 100/1023 · 5 V = 0.49 V on the lambda pin
        let live = try await c.readLiveData()
        #expect(abs(i.supplyVolts - live.voltage) < 0.1, "\(i.supplyVolts) vs \(live.voltage)")
        #expect(i.extra.isEmpty)
    }

    /// Р83 (2112-71): byte 5 is the CO potentiometer on pin 44 (A/D channel 2).
    @Test func r83() async throws {
        let c = try await client("j5/j5v07g26/J5V07G26.BIN", adc: [2: 700, 3: 200])
        let i = try #require(try await c.readInputs())
        #expect(i.fifthCode == 175 && i.throttleCode == 50)
    }

    /// Январь 7.2 answers with one more byte (F80E).
    @Test func j72AnswersWithAnExtraByte() async throws {
        let c = try await client("j72/i205do54/i205do54.bin", adc: [4: 103])
        let i = try #require(try await c.readInputs())
        #expect(i.coolantCode == 25 && i.extra.count == 1)
    }
}
