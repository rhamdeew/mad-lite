import Foundation

/// ECU family detected from the firmware image.
public enum EcuFamily: String, Sendable {
    case january51 = "Январь 5.1"
    case january72 = "Январь 7.2"
    case unknown = "Неизвестно"
}

/// Container format of a firmware file.
public enum FirmwareFormat: String, Sendable {
    /// Plain ROM image, byte-for-byte as stored in the ECU.
    case raw = "Сырой образ"
    /// SMS-Soft / Combiloader compressed container (header "SMS-Soft...").
    case smsSoftCompressed = "Сжатый SMS-Soft / Combiloader"
}

public enum FirmwareError: Error, Equatable, LocalizedError {
    case empty

    public var errorDescription: String? {
        switch self {
        case .empty: "Файл пустой"
        }
    }
}

/// A loaded firmware image with metadata parsed from it.
public struct Firmware: Sendable {
    public let name: String
    public private(set) var data: Data
    public let format: FirmwareFormat
    public let header: FirmwareHeader?
    public let identification: DiagnosticIdentification?

    public init(data: Data, name: String = "") throws {
        guard !data.isEmpty else { throw FirmwareError.empty }
        self.name = name
        self.data = data
        if data.starts(with: Array("SMS-Soft".utf8)) {
            format = .smsSoftCompressed
            header = nil
            identification = nil
        } else {
            format = .raw
            header = FirmwareHeader(parsing: data)
            identification = DiagnosticIdentification(parsing: data)
        }
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url), name: url.lastPathComponent)
    }

    public var size: Int { data.count }

    /// Overwrites bytes in place; the image size never changes.
    public mutating func write(_ bytes: [UInt8], at offset: Int) {
        precondition(offset >= 0 && offset + bytes.count <= data.count, "Запись за пределы образа")
        data.replaceSubrange(data.startIndex + offset ..< data.startIndex + offset + bytes.count, with: bytes)
    }

    /// Calibration layout for this software version, if one is bundled.
    public var definition: CalibrationDefinition? {
        DefinitionStore.definition(forSoftwareID: softwareID, data: data)
    }

    public var family: EcuFamily {
        switch header?.platform {
        case "J5.1": .january51
        case "J7.2": .january72
        default: .unknown
        }
    }

    /// Software ID such as "J5V05L19" or "I203EL36".
    ///
    /// Январь 5.1: the diagnostic identification record wins — it is what the ECU reports to
    /// a tester, while early versions left a stale ID at 0x6020 (J5V05F16 says "J5V05F01",
    /// J5V03F21 "J5V03F02", J5V03H21 "J5V03G21"). Январь 7.2: the 0x6020 header wins
    /// (A205DM53 carries Itelma's "I205DM53" in its identification record).
    public var softwareID: String? {
        if family == .january51, let id = identification?.softwareID { return id }
        return header?.softwareID ?? identification?.softwareID
    }
}
