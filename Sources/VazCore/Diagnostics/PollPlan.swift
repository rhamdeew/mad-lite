import Foundation

/// What each poll cycle asks the ECU for: fast-changing values every cycle, the rest less often,
/// so they do not eat the line.
///
/// Every request costs P3 (100 ms) plus its bytes at 10400 baud. On a live J5LS
/// (27.10.2026) that is `21 01` ≈ 140 ms, `21 8C` ≈ 240 ms, `21 03` ≈ 160 ms. The old loop asked
/// for `21 01` + `21 8C` every cycle and `21 03` every second: ≈2.4 rows/s.
///
/// - Ignition on, engine stopped: nothing changes fast, a full picture matters more. Every
///   frame every cycle, `21 03` every second.
/// - Engine running with a J5LS record: `21 8C` every cycle. It carries the same RPM, coolant,
///   throttle, IAC, injection, air flow and cycle air as `21 01` (byte for byte on the car logs),
///   and the mode and fault flags (bytes 0–6), and LogSchema / `J5LiveData.withStatus` take them
///   from it. `21 01` is left for the ignition advance (zero in `21 8C` outside engineering
///   ECUs) and AFR: twice a second.
///   `21 03` adds little to J5LS (knock A/D and port copies): every 10 s. ≈3.2 rows/s.
/// - Stock firmware without the record: `21 01` every cycle, `21 03` every 3 s while running.
///
/// The mode stays "running" for `stallHold` after the last RPM above zero, so a stall and the
/// restart right after it are logged at the fast rate.
public struct PollPlan: Sendable {
    public enum Request: Hashable, Sendable, CaseIterable {
        case base, extended, inputs
    }

    public enum Mode: Equatable, Sendable {
        case ignition, running
    }

    public static let stallHold: Duration = .seconds(3)

    public let hasExtended: Bool
    public private(set) var mode: Mode = .ignition
    private var lastRunning: ContinuousClock.Instant?
    private var last: [Request: ContinuousClock.Instant] = [:]

    public init(hasExtended: Bool) {
        self.hasExtended = hasExtended
    }

    /// How often a request is due; `.zero` means every cycle.
    public static func interval(_ request: Request, mode: Mode, hasExtended: Bool) -> Duration {
        switch (request, mode) {
        case (.extended, _): .zero
        case (.base, .ignition): .zero
        case (.base, .running): hasExtended ? .milliseconds(500) : .zero
        case (.inputs, .ignition): .seconds(1)
        case (.inputs, .running): hasExtended ? .seconds(10) : .seconds(3)
        }
    }

    /// Stored codes: a new code shows up within this time.
    public static func troubleCodeInterval(mode: Mode) -> Duration {
        mode == .running ? .seconds(10) : .seconds(5)
    }

    /// Requests due now, in the order to send them. A request never made yet is always due.
    public func due(at now: ContinuousClock.Instant) -> [Request] {
        Request.allCases.filter { request in
            if request == .extended, !hasExtended { return false }
            guard let previous = last[request] else { return true }
            return now - previous >= Self.interval(request, mode: mode, hasExtended: hasExtended)
        }
    }

    public mutating func done(_ request: Request, at now: ContinuousClock.Instant) {
        last[request] = now
    }

    /// Takes the freshest engine speed; returns the new mode when it changed.
    public mutating func update(rpm: Double, at now: ContinuousClock.Instant) -> Mode? {
        if rpm > 0 { lastRunning = now }
        let next: Mode = lastRunning.map { now - $0 < Self.stallHold } ?? false ? .running : .ignition
        guard next != mode else { return nil }
        mode = next
        return next
    }

    /// For the log marker and the agent.
    public var description: String {
        switch mode {
        case .ignition: "зажигание: полный опрос"
        case .running: hasExtended ? "мотор работает: 21 8C каждый цикл (флаги и неисправности тоже), 21 01 раз в 0,5 с (УОЗ, AFR), 21 03 раз в 10 с"
                                   : "мотор работает: 21 01 каждый цикл, 21 03 раз в 3 с"
        }
    }
}
