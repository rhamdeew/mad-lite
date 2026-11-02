import Foundation

/// «Снимок блока»: one pass over every read-only request the ECU may answer, saved raw, so a
/// short first session with an unknown firmware still brings home all it can.
/// Nothing here writes: no `14`, `30`, `31`, `3B`; `23` reads only the RAM the spec allows.
///
/// Rejections and broken answers are recorded too — what a build does not support is a
/// finding as well. Checked in the emulator on J5V05L19 and J5LS N35 / V2 (27.10.2026).
public struct ECUSnapshot: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var title: String
        public var request: String
        /// Positive answer, hex, starting with SId+0x40.
        public var response: String?
        /// Rejection or link error, in words.
        public var error: String?
        /// What the answer says, where we know how to read it.
        public var note: String?
    }

    public var taken: Date
    public var appVersion: String
    public var source: String
    public var keyBytes: String
    public var entries: [Entry]

    /// Requests in order. Identification first: it is what the session is for if the link is
    /// poor. `21 A3` comes before the rest on purpose: J5LS N35 sends one byte less than its
    /// header says, and the following requests check that the client recovers.
    public static let requests: [(String, [UInt8])] = readRequests + memoryRequests

    static let readRequests: [(String, [UInt8])] = [
        ("Идентификация 80", [0x1A, 0x80]),
        ("Идентификация 90", [0x1A, 0x90]),
        ("Иммобилайзер (21 A0)", [0x21, 0xA0]),
        ("VIN (21 A1)", [0x21, 0xA1]),
        ("Двигатель (21 A2)", [0x21, 0xA2]),
        ("Дата (21 A3)", [0x21, 0xA3]),
        ("Кадр СТО (21 01)", [0x21, 0x01]),
        ("Кадр конвейера (21 02)", [0x21, 0x02]),
        ("Входной контроль (21 03)", [0x21, 0x03]),
        ("Расширенный J5LS (21 8C)", [0x21, 0x8C]),
        ("Расширенный J5LS (21 0D)", [0x21, 0x0D]),
        ("Расширенный J5LS (21 0F)", [0x21, 0x0F]),
        ("Коды неисправностей", [0x18, 0x00, 0x00, 0x00]),
    ]

    /// Adaptation tables in XRAM FD00–FEFF. J5V05L19 rejects 78h bytes at once (`7F 23 31`)
    /// although the spec allows it; 77h passes.
    static let memoryRequests: [(String, [UInt8])] = stride(from: 0xFD00, to: 0xFF00, by: memoryChunk).map { address in
        let title = String(format: "ОЗУ %04X–%04X", address, address + memoryChunk - 1)
        let request: [UInt8] = [0x23, 0x00, UInt8(address >> 8), UInt8(address & 0xFF), UInt8(memoryChunk)]
        return (title, request)
    }

    static let memoryChunk = 0x40

    public init(taken: Date = Date(), appVersion: String = AppVersion.current, source: String,
                keyBytes: [UInt8], entries: [Entry]) {
        self.taken = taken
        self.appVersion = appVersion
        self.source = source
        self.keyBytes = Self.hex(keyBytes)
        self.entries = entries
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

    public var answered: Int { entries.filter { $0.response != nil }.count }
    /// Requests the ECU rejected with `7F`: not supported by the build, not a link fault
    /// (some J5LS builds: `21 A0`, `21 0D`).
    public var rejected: Int { entries.filter { $0.response == nil && $0.error?.hasPrefix("отказ 7F") == true }.count }

    public var summary: String {
        "ответов \(answered) из \(entries.count)" + (rejected > 0 ? " (\(rejected) — не поддерживаются блоком)" : "")
    }

    /// Plain-language reading of an answer, or nil.
    static func note(request: [UInt8], response d: [UInt8]) -> String? {
        switch request.first {
        case 0x1A:
            // ASCII fields padded with FF / "-" (J5V05L19: «2112 -1411020-41…SAMARA-1.5L,16V…J5V05L19»).
            let text = String(decoding: d.dropFirst(2).map { (0x20..<0x7F).contains($0) ? $0 : 0x20 }, as: UTF8.self)
                .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            return text.isEmpty ? nil : text
        case 0x18:
            guard let codes = try? DTC.parse(response: d) else { return nil }
            return codes.isEmpty ? "кодов нет" : codes.map { "\($0.code) \($0.description)" }.joined(separator: "; ")
        case 0x21 where request.count > 1:
            switch request[1] {
            case 0x01:
                guard let l = try? J5LiveData(response: d) else { return nil }
                return String(format: "%.0f об/мин, ТОЖ %.0f °C, ДЗ %.0f %%, %.1f В", l.rpm, l.coolantTemp, l.throttle, l.voltage)
            case 0x03:
                guard let i = try? J5Inputs(response: d) else { return nil }
                return String(format: "ДТОЖ %.2f В, ДМРВ/ДАД %.2f В, ДПДЗ %.2f В, бортсеть %.1f В",
                              i.coolantVolts, i.mafVolts, i.throttleVolts, i.supplyVolts)
            case let id where J5LSLiveData.recordIDs.contains(id):
                return "\(d.count - 2) байт данных"
            default: return nil
            }
        default: return nil
        }
    }

    /// Request that is not a RAM read: the memory is compared as a map (`AdaptationMap`).
    public static func isMemory(_ entry: Entry) -> Bool { entry.request.hasPrefix("23") }

    /// What the entry says, for the screen: the decoded note, else the raw answer, else the error.
    public static func text(_ entry: Entry) -> String {
        entry.note ?? entry.response ?? entry.error ?? "—"
    }

    public struct Difference: Equatable, Sendable, Identifiable {
        public var id: String { request }
        public var title: String
        public var request: String
        public var old: String?
        public var new: String?
    }

    /// Requests whose answer changed since `old` (RAM reads left out), in this snapshot's order;
    /// a request only one of the two has shows with the other side nil.
    public func differences(from old: ECUSnapshot) -> [Difference] {
        let before = Dictionary(old.entries.filter { !Self.isMemory($0) }.map { ($0.request, $0) },
                                uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var result: [Difference] = []
        for entry in entries where !Self.isMemory(entry) {
            seen.insert(entry.request)
            let previous = before[entry.request]
            guard previous?.response != entry.response || previous?.error != entry.error else { continue }
            result.append(Difference(title: entry.title, request: entry.request,
                                     old: previous.map(Self.text), new: Self.text(entry)))
        }
        for entry in old.entries where !Self.isMemory(entry) && !seen.contains(entry.request) {
            result.append(Difference(title: entry.title, request: entry.request, old: Self.text(entry), new: nil))
        }
        return result
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ECUSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ECUSnapshot.self, from: data)
    }
}

extension KWPClient {
    /// Runs `ECUSnapshot.requests` on an open session. A rejection or a broken answer is
    /// recorded and the pass goes on (the next request starts with a flushed line); three link
    /// errors in a row mean the ECU is gone, and the pass stops with what it has.
    public func takeSnapshot(source: String) async throws -> ECUSnapshot {
        var entries: [ECUSnapshot.Entry] = []
        var linkErrors = 0
        for (title, request) in ECUSnapshot.requests {
            try Task.checkCancellation()
            var entry = ECUSnapshot.Entry(title: title, request: ECUSnapshot.hex(request))
            do {
                let d = try await self.request(request)
                entry.response = ECUSnapshot.hex(d)
                entry.note = ECUSnapshot.note(request: request, response: d)
                linkErrors = 0
            } catch let KWPError.negativeResponse(service, code) {
                entry.error = String(format: "отказ 7F %02X %02X: ", service, code) + KWPError.describe(code: code)
                linkErrors = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                entry.error = "\(error)"
                linkErrors += 1
            }
            entries.append(entry)
            if linkErrors >= 3 { break }
        }
        return ECUSnapshot(source: source, keyBytes: keyBytes ?? [], entries: entries)
    }
}
