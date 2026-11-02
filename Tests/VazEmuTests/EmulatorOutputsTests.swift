import Foundation
import Testing
import VazCore
@testable import VazEmu

/// Injector and ignition outputs, the relay driver and the watchdog (docs/emulator.md).
@Suite(.serialized) struct EmulatorOutputsTests {
    func running(_ path: String, rpm: Double) async throws -> (KWPClient, EmulatorTransport) {
        let line = EmulatorTransport(rom: Array(try Data(contentsOf: firmwareDir.appendingPathComponent(path))))
        await line.setADC(channel: Sensors.coolantChannel, value: Sensors.coolant(celsius: 90))
        await line.setADC(channel: Sensors.voltageChannel, value: Sensors.supply(volts: 14))
        await line.setADC(channel: Sensors.mafChannel, value: Sensors.voltage(2.0))
        try await line.boot()
        let client = KWPClient(transport: line, interRequestDelay: .zero)
        try await client.connect()
        await line.setCrank(rpm: rpm)
        try await line.run(ms: 2500)
        return (client, line)
    }

    /// Falling and rising edges of one pin: (crank degrees, rising, cycle).
    func edges(_ trace: C509Board.OutputTrace, port5: Bool, bit: Int) -> [(degrees: Double, rising: Bool, cycle: UInt64)] {
        zip(trace.edges, trace.edges.dropFirst()).compactMap { a, b in
            let x = (port5 ? a.port5 : a.port4) >> bit & 1, y = (port5 ? b.port5 : b.port4) >> bit & 1
            return x == y ? nil : (b.crankDegrees, y == 1, b.cycle)
        }
    }

    func lowWidths(_ e: [(degrees: Double, rising: Bool, cycle: UInt64)]) -> [Double] {
        zip(e, e.dropFirst()).compactMap { a, b in !a.rising && b.rising ? Double(b.cycle - a.cycle) / 2667 : nil }
    }

    /// Injectors P4.0–P4.3 (active low, pairs 1-4 / 2-3 without a phase sensor) are open for the
    /// injection time the ECU reports; the spark (P5.1 / P5.2 rising edge) comes at TDC − advance,
    /// TDC of cylinders 1-4 being the 20th tooth after the gap (114°).
    @Test(arguments: [1000.0, 3000, 5000])
    func injectionAndSparkMatchTheFrame(rpm: Double) async throws {
        let (client, line) = try await running("j5/j5v05l19/J5V05L19.BIN", rpm: rpm)
        await line.startOutputTrace()
        try await line.run(ms: 100)
        let live = try await client.readLiveData()
        let trace = try #require(await line.outputTrace)
        for bit in 0..<4 {
            let w = lowWidths(edges(trace, port5: false, bit: bit))
            #expect(!w.isEmpty && w.allSatisfy { abs($0 - live.injectionTime) < 0.05 }, "P4.\(bit): \(w) vs \(live.injectionTime)")
        }
        let spark14 = edges(trace, port5: true, bit: 1).filter(\.rising).map(\.degrees)
        let spark23 = edges(trace, port5: true, bit: 2).filter(\.rising).map(\.degrees)
        #expect(!spark14.isEmpty && !spark23.isEmpty)
        for s in spark14 { #expect(abs(s + live.ignitionAdvance - 114) < 1.5, "1-4 at \(s)°, advance \(live.ignitionAdvance)") }
        for s in spark23 { #expect(abs(s + live.ignitionAdvance - 294) < 1.5, "2-3 at \(s)°, advance \(live.ignitionAdvance)") }
        #expect(await line.watchdogResets == 0)
    }

    /// Service 30 reaches the relay driver: the output image the firmware shifts out on port 9.
    @Test func relayCommandsReachTheDriver() async throws {
        let (client, line) = try await running("j5/j5v05l19/J5V05L19.BIN", rpm: 0)
        func image() async -> UInt8 { await line.outputDriverImage ?? 0 }
        try await client.control(.output(.fan, on: true)); try await line.run(ms: 300)
        #expect(await image() & 0x02 != 0)
        try await client.control(.output(.fan, on: false)); try await line.run(ms: 300)
        #expect(await image() & 0x02 == 0)
        try await client.control(.output(.fuelPump, on: true)); try await line.run(ms: 300)
        #expect(await image() & 0x40 != 0)
        try await client.control(.output(.fuelPump, on: false)); try await line.run(ms: 300)
        #expect(await image() & 0x40 == 0)
        try await client.control(.output(.checkEngine, on: false)); try await line.run(ms: 300)
        #expect(await image() & 0x10 == 0)
        try await client.returnAllControl(ids: [0x09, 0x0A, 0x0C])
    }

    /// The fan comes on by itself on a hot engine.
    @Test func fanSwitchesOnWhenHot() async throws {
        let (client, line) = try await running("j5/j5v05l19/J5V05L19.BIN", rpm: 900)
        #expect(await (line.outputDriverImage ?? 0) & 0x02 == 0)
        await line.setADC(channel: Sensors.coolantChannel, value: Sensors.coolant(celsius: 112))
        for _ in 0..<6 { try await line.run(ms: 1000); try await client.testerPresent() }
        #expect(await (line.outputDriverImage ?? 0) & 0x02 != 0)
    }

    /// A program that starts the watchdog and never refreshes it is reset with WDTS set;
    /// one that refreshes (setb WDT; setb SWDT) is not.
    @Test func watchdogResetsAStuckProgram() throws {
        // mov WDTREL,#7Fh; setb SWDT; sjmp $
        let stuck = C509Board(rom: [0x75, 0x86, 0x7F, 0xD2, 0xBE, 0x80, 0xFE])
        try stuck.run(machineCycles: 2667) // 1 ms; time-out at fOSC/24 and 7Fh is 378 µs
        #expect(stuck.watchdogResets >= 1)
        #expect(stuck.cpu.sfr[0xA9] & 0x40 != 0) // WDTS
        // mov WDTREL,#7Fh; setb SWDT; loop: setb WDT; setb SWDT; sjmp loop
        let alive = C509Board(rom: [0x75, 0x86, 0x7F, 0xD2, 0xBE, 0xD2, 0xAE, 0xD2, 0xBE, 0x80, 0xFA])
        try alive.run(machineCycles: 2667 * 10)
        #expect(alive.watchdogRunning && alive.watchdogResets == 0)
    }
}
