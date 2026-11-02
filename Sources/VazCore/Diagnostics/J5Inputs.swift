import Foundation

/// Decoded `61 03` frame («входной контроль»): raw A/D codes of the sensors and copies of the
/// output ports, so a sensor circuit can be checked by its voltage at the ECU.
///
/// The firmware builds the frame from a ROM list right after the `21 02` one (J5V05L19
/// `0x59CA`: IRAM `76h`, then XRAM `F80B F80C F80D F815 F8A9 F8B3 F8B6 F8B7 F8B5`). Byte 5 is
/// the oxygen sensor (`F815`) in Euro 2 builds, the CO potentiometer A/D on pin 44 in Р83 builds
/// (`F84D` / `F80E`). Январь 7.2 uses the same list plus one byte (`F80E`), but its ADC
/// channels were not traced, so only the J5 meaning is given here. docs/kwp2000-j5.md, «21 03».
public struct J5Inputs: Equatable, Sendable {
    public static let dataLength = 10

    public let knockCode: UInt8
    public let coolantCode: UInt8
    public let mafCode: UInt8
    public let supplyCode: UInt8
    /// Oxygen sensor (Euro 2) or CO potentiometer (Р83).
    public let fifthCode: UInt8
    public let throttleCode: UInt8
    /// Port copies made by the firmware: P1 (`F8B3`), P5 (`F8B6`), P6 (`F8B7`), P8 (`F8B5`).
    public let port1, port5, port6, port8: UInt8
    /// Bytes after the J5 payload (Январь 7.2: `F80E`).
    public let extra: [UInt8]

    public init(response d: [UInt8]) throws {
        guard d.count >= 2 + Self.dataLength, d[0] == 0x61, d[1] == 0x03 else {
            throw KWPError.unexpectedResponse(d)
        }
        let b = Array(d.dropFirst(2))
        knockCode = b[0]
        coolantCode = b[1]
        mafCode = b[2]
        supplyCode = b[3]
        fifthCode = b[4]
        throttleCode = b[5]
        port1 = b[6]
        port5 = b[7]
        port6 = b[8]
        port8 = b[9]
        extra = Array(b.dropFirst(Self.dataLength))
    }

    /// 8-bit A/D code → volts at the ECU pin (5 V reference, upper 8 of 10 bits).
    public static func volts(_ code: UInt8) -> Double { Double(code) * 5 / 256 }

    public var knockVolts: Double { Self.volts(knockCode) }
    public var coolantVolts: Double { Self.volts(coolantCode) }
    public var mafVolts: Double { Self.volts(mafCode) }
    public var throttleVolts: Double { Self.volts(throttleCode) }

    /// On-board voltage: pin volts through the 2490/681 divider. Matches the firmware's own
    /// `21 01` voltage — codes 100 / 150 give 9.1 / 13.7 V in J5V05L19 and J5V13I02 (emulator,
    /// 27.10.2026; at 200 the `21 01` byte saturates at 17.95 V). DiagnozNK's `E·0.287·5/256`
    /// gives 0.4 V and is wrong.
    public var supplyVolts: Double { Self.volts(supplyCode) * (2490 + 681) / 681 }

    /// Byte 5 in volts: oxygen sensor with the `21 01` scale (1.25 V full range) for Euro 2,
    /// pin 44 on the 5 V scale for Р83.
    public func fifthVolts(_ standard: J5LiveData.Standard) -> Double {
        standard == .euro2 ? Double(fifthCode) * 1.25 / 256 : Self.volts(fifthCode)
    }

    /// What is known of the port bits (J5V05L19, emulator, 27.10.2026): P5.1 / P5.2 are the
    /// ignition outputs 1-4 / 2-3, P4.0–P4.3 the injectors; the relays and the CE lamp are not on
    /// these ports but on an external driver fed over port 9. DiagnozNK's names (fuel pump on
    /// P5.1 and so on) do not fit Январь 5.1.
    public static let portNotes = "В Январе 5.1 реле и лампа подключены через драйвер на порту 9, их в этом кадре нет. P5.1 / P5.2 — выходы зажигания 1-4 / 2-3, P4.0–P4.3 — форсунки (по эмулятору)."
}

extension KWPClient {
    /// `21 03`. Stock J5 and J7.2 answer it; nil when the ECU rejects the identifier.
    public func readInputs() async throws -> J5Inputs? {
        do {
            return try J5Inputs(response: try await request([Service.readDataByLocalIdentifier.rawValue, 0x03]))
        } catch KWPError.negativeResponse(service: 0x21, code: _) {
            return nil
        }
    }
}
