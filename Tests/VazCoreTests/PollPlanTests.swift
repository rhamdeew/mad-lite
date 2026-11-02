import Foundation
import Testing
@testable import VazCore

@Suite struct PollPlanTests {
    let t0 = ContinuousClock.now

    func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    mutating func run(_ plan: inout PollPlan, at ms: Int) -> [PollPlan.Request] {
        let due = plan.due(at: at(ms))
        for request in due { plan.done(request, at: at(ms)) }
        return due
    }

    @Test mutating func ignitionReadsEveryFrameEveryCycle() {
        var plan = PollPlan(hasExtended: true)
        #expect(run(&plan, at: 0) == [.base, .extended, .inputs])
        #expect(run(&plan, at: 500) == [.base, .extended])
        #expect(run(&plan, at: 1000) == [.base, .extended, .inputs])
    }

    @Test mutating func runningKeepsTheRecordFastAndThinsTheRest() {
        var plan = PollPlan(hasExtended: true)
        _ = run(&plan, at: 0)
        #expect(plan.update(rpm: 800, at: at(0)) == .running)
        #expect(run(&plan, at: 250) == [.extended])
        #expect(run(&plan, at: 500) == [.base, .extended])
        #expect(run(&plan, at: 750) == [.extended])
        #expect(run(&plan, at: 9750) == [.base, .extended])
        #expect(run(&plan, at: 10000) == [.extended, .inputs])
    }

    @Test mutating func stockFirmwareReadsBaseEveryCycle() {
        var plan = PollPlan(hasExtended: false)
        _ = run(&plan, at: 0)
        _ = plan.update(rpm: 800, at: at(0))
        #expect(run(&plan, at: 150) == [.base])
        #expect(run(&plan, at: 3000) == [.base, .inputs])
    }

    /// A stall and the restart right after it stay at the running rate.
    @Test func stallHoldsTheRunningModeForThreeSeconds() {
        var plan = PollPlan(hasExtended: true)
        #expect(plan.update(rpm: 0, at: at(0)) == nil)
        #expect(plan.update(rpm: 200, at: at(100)) == .running) // cranking
        #expect(plan.update(rpm: 0, at: at(2000)) == nil)
        #expect(plan.update(rpm: 0, at: at(3100)) == .ignition)
        #expect(plan.mode == .ignition)
    }

    /// With the record present the row takes RPM, injection and the rest from it (fresh every
    /// cycle), the ignition advance still from `21 01`.
    @Test func rowTakesSharedValuesFromTheRecord() throws {
        let base = try J5LiveData(response: KWPClientTests.liveFrame)
        let ext = try J5LSLiveData(response: J5LSExtendedTests.record)
        let ids = LogSchema.channels(extended: true).map(\.id)
        let row = LogSchema.values(base: base, extended: ext)
        func value(_ id: String) -> Double { row[ids.firstIndex(of: id)!] }
        #expect(value("rpm") == ext.rpm)
        #expect(value("throttle") == ext.throttle)
        #expect(value("cycle_air") == ext.cycleAir)
        #expect(abs(value("inj_corr") - ext.injectionCorrection / 1000) < 1e-9)
        #expect(value("ignition") == base.ignitionAdvance)
    }

    /// Car, 27.10.2026, sensors unplugged: `21 8C` starts `11 04 02 00 60 00 00` — mode flags,
    /// two stored errors, TPS and MAF/MAP low in faults 2 — the same as `21 01` sent.
    @Test func flagsAndFaultsComeFromTheRecord() throws {
        let hex = "61 0D 11 04 02 00 60 00 00 00 32 00 16 00 00 00 00 00 6D 6D 80 1E 00 00 00 00 00 00 00 4D 00 03 B8 1D 5E 00 00 00 00 99 DB 00 00 00 FF 00 00 00 00 00 00 00 00 00 3C 99"
        let ext = try J5LSLiveData(response: hex.split(separator: " ").map { UInt8($0, radix: 16)! })
        let base = try J5LiveData(response: KWPClientTests.liveFrame) // ДТОЖ low, no TPS/MAF fault
        let merged = base.withStatus(from: ext)
        #expect(merged.mode1.raw == 0x11 && merged.mode2.raw == 0x04)
        #expect(merged.faults.map(\.raw) == [0x00, 0x60, 0x00, 0x00])
        #expect(merged.emergencyModes.first?.hasPrefix("ДМРВ/ДАД и ДПДЗ неисправны") == true)
        #expect(merged.ignitionAdvance == base.ignitionAdvance)
        let ids = LogSchema.channels(extended: true).map(\.id)
        let row = LogSchema.values(base: base, extended: ext)
        #expect(row[ids.firstIndex(of: "faults")!] == Double(0x0060_0000))
        #expect(row[ids.firstIndex(of: "f_emergency")!] == 1)
    }
}
