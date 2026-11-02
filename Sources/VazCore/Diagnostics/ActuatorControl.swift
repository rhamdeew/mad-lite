import Foundation

/// Service `30` (inputOutputControlByLocalIdentifier): the tester switches ECU outputs or sets
/// idle targets by hand. Formats from DiagnozNK's «Январь-Евро2» profile, checked against
/// J5V05L19 / J5V07G26 in the emulator (docs/kwp2000-j5.md, «Сервис 30»):
///
///     30 <id> 06 01 / 06 00   on / off           → 70 <id> 06 <v>
///     30 42 07 N              idle rpm = N·10     → 70 42 07 …
///     30 61 08 N              idle air valve step → 70 61 08 N (J5V05L19 rejects: 7F 30 12)
///     30 <id> 00              return control      → 70 <id> 00 <state>
///
/// AvtoVAZ documentation (quoted in the profile) makes returning control mandatory after
/// manual control. Whether the ECU drops manual control by itself when the session ends is
/// not known.
public enum ActuatorCommand: Equatable, Sendable {
    case output(Output, on: Bool)
    /// Desired idle speed, rpm; sent as rpm/10 in one byte (DiagnozNK slider 500…2550).
    case idleRPM(Int)
    /// Desired idle air control valve position, steps (DiagnozNK slider 8…255).
    case iacPosition(Int)
    case returnControl(UInt8)

    public enum Output: UInt8, CaseIterable, Sendable {
        case ignition1 = 0x01, ignition2 = 0x02, ignition3 = 0x03, ignition4 = 0x04
        case injectors14 = 0x05, injectors23 = 0x06
        case fuelPump = 0x09, fan = 0x0A, airConditioner = 0x0B, checkEngine = 0x0C

        public var title: String {
            switch self {
            case .ignition1: "Зажигание, цилиндр 1"
            case .ignition2: "Зажигание, цилиндр 2"
            case .ignition3: "Зажигание, цилиндр 3"
            case .ignition4: "Зажигание, цилиндр 4"
            case .injectors14: "Форсунки 1 и 4"
            case .injectors23: "Форсунки 2 и 3"
            case .fuelPump: "Реле бензонасоса"
            case .fan: "Реле вентилятора"
            case .airConditioner: "Реле кондиционера"
            case .checkEngine: "Лампа Check Engine"
            }
        }
    }

    public static let idleRPMID: UInt8 = 0x42
    public static let iacPositionID: UInt8 = 0x61
    public static let idleRPMRange = 500...2550
    public static let iacPositionRange = 8...255

    /// Identifier the command takes control of.
    public var id: UInt8 {
        switch self {
        case .output(let o, _): o.rawValue
        case .idleRPM: Self.idleRPMID
        case .iacPosition: Self.iacPositionID
        case .returnControl(let id): id
        }
    }

    public var request: [UInt8] {
        switch self {
        case .output(let o, let on): [0x30, o.rawValue, 0x06, on ? 0x01 : 0x00]
        case .idleRPM(let rpm):
            [0x30, Self.idleRPMID, 0x07, UInt8(min(max(rpm, Self.idleRPMRange.lowerBound), Self.idleRPMRange.upperBound) / 10)]
        case .iacPosition(let steps):
            [0x30, Self.iacPositionID, 0x08, UInt8(min(max(steps, Self.iacPositionRange.lowerBound), Self.iacPositionRange.upperBound))]
        case .returnControl(let id): [0x30, id, 0x00]
        }
    }

    /// Plain-language line for the log and the screen.
    public var title: String {
        switch self {
        case .output(let o, let on): "\(o.title): \(on ? "включить" : "выключить")"
        case .idleRPM(let rpm): "Обороты ХХ: \(rpm / 10 * 10) об/мин"
        case .iacPosition(let steps): "Положение РХХ: \(steps) шагов"
        case .returnControl(let id): "Вернуть управление ЭБУ (\(String(format: "%02X", id)))"
        }
    }

    /// Every identifier DiagnozNK returns on «Вернуть управление» (CO trim 41 included).
    public static let allIDs: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x09, 0x0A, 0x0B, 0x0C, 0x41, 0x42, 0x61]
}

extension KWPClient {
    /// Sends the command; returns the positive response (`70 …`). A rejection throws
    /// `KWPError.negativeResponse(service: 0x30, …)`.
    @discardableResult
    public func control(_ command: ActuatorCommand) async throws -> [UInt8] {
        try await request(command.request)
    }

    /// `30 <id> 00` for every identifier; rejections (an id this build lacks) are skipped.
    /// Returns the identifiers the ECU acknowledged.
    @discardableResult
    public func returnAllControl(ids: [UInt8] = ActuatorCommand.allIDs) async throws -> [UInt8] {
        var acknowledged: [UInt8] = []
        for id in ids {
            do {
                try await control(.returnControl(id))
                acknowledged.append(id)
            } catch KWPError.negativeResponse(service: 0x30, code: _) {
                continue
            }
        }
        return acknowledged
    }
}
