import Foundation
import Observation
import VazCore

/// Shared log of every bootstrap-loader operation (read/write flash, read/write EEPROM,
/// immobilizer defeat). Two consumers:
/// - a JSONL file in Documents/<edition>/Flash for after-the-fact analysis;
/// - the MCP agent (`flash_status`), so Claude can watch a flashing session live and advise.
@MainActor @Observable
final class LoaderLog {
    struct Entry: Codable, Sendable {
        let time: Date
        /// Short phase tag: sync, agent, id, erase, write, verify, eeprom, immo, done, error.
        let phase: String
        let message: String
        let done: Int?
        let total: Int?
    }

    /// Current operation name (nil = idle).
    private(set) var operation: String?
    /// Latest human-readable line.
    private(set) var current: String?
    /// Progress of the current step, if any.
    private(set) var progress: (done: Int, total: Int)?
    /// All entries of the current operation (also the file).
    private(set) var entries: [Entry] = []
    private(set) var lastFile: URL?

    private var handle: FileHandle?

    static var directory: URL { DiagnosticsModel.dataDirectory.appendingPathComponent("Flash", isDirectory: true) }

    /// Starts a new operation and its log file.
    func begin(_ operation: String, source: String) {
        self.operation = operation
        entries = []
        progress = nil
        current = operation
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let url = Self.directory.appendingPathComponent("loader_\(f.string(from: Date())).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        lastFile = url
        event("start", "\(operation) · источник: \(source)")
    }

    /// Records one event (and, when given, the step progress).
    func event(_ phase: String, _ message: String, done: Int? = nil, total: Int? = nil) {
        let entry = Entry(time: Date(), phase: phase, message: message, done: done, total: total)
        entries.append(entry)
        current = message
        if let done, let total { progress = (done, total) }
        if let line = try? JSONEncoder.iso.encode(entry) {
            handle?.write(line); handle?.write(Data([0x0A]))
        }
    }

    /// Ends the operation.
    func end(ok: Bool, _ message: String) {
        event(ok ? "done" : "error", message)
        try? handle?.close()
        handle = nil
        operation = nil
        progress = nil
    }

    /// Recent entries for the agent (most recent last).
    func recent(_ count: Int = 20) -> [Entry] { Array(entries.suffix(count)) }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
