import Foundation
import Testing
import VazCore
@testable import VazEmu

/// «Снимок блока» against real firmware: every read-only request once, rejections kept.
@Suite(.serialized) struct SnapshotTests {
    func snapshot(_ path: String) async throws -> ECUSnapshot {
        let line = EmulatorTransport(rom: Array(try Data(contentsOf: firmwareDir.appendingPathComponent(path))))
        try await line.boot()
        let client = KWPClient(transport: line)
        try await client.connect()
        return try await client.takeSnapshot(source: path)
    }

    func entry(_ s: ECUSnapshot, _ request: String) throws -> ECUSnapshot.Entry {
        try #require(s.entries.first { $0.request == request })
    }

    @Test func stockFirmware() async throws {
        let s = try await snapshot("j5/j5v05l19/J5V05L19.BIN")
        #expect(s.entries.count == ECUSnapshot.requests.count)
        #expect(try entry(s, "1A 80").note?.hasSuffix("J5V05L19") == true)
        #expect(try entry(s, "21 8C").error?.hasPrefix("отказ 7F 21 12") == true)
        #expect(try entry(s, "21 03").note?.contains("ДПДЗ") == true)
        // All of FD00–FEFF comes back: 8 × 40h bytes.
        let memory = s.entries.filter { $0.request.hasPrefix("23") }
        #expect(memory.count == 8)
        #expect(memory.allSatisfy { ($0.response?.split(separator: " ").count ?? 0) == 1 + 0x40 })
        // Fresh RAM after a checksum reset: learning is 1.0 everywhere.
        let map = try #require(AdaptationMap(snapshot: s))
        #expect(map.layout == .rpmLoad && map.summary().changed == 0)
        let decoded = try ECUSnapshot.decode(try s.json())
        #expect(decoded.entries == s.entries)
        #expect(decoded.keyBytes == "6B 8F")
    }

    /// J5LS N35 sends one byte less than its `21 A3` header says. The broken answer is recorded
    /// and does not spoil the rest: the extended record and the codes still come through.
    @Test(.enabled(if: hasFirmware("j5ls/J5LS_N35.BIN"))) func brokenAnswerDoesNotDesync() async throws {
        let s = try await snapshot("j5ls/J5LS_N35.BIN")
        #expect(try entry(s, "21 A3").error?.contains("timeout") == true)
        #expect(try entry(s, "21 0D").note == "61 байт данных")
        #expect(try entry(s, "18 00 00 00").response != nil)
        #expect(s.answered == s.entries.count - 2) // 21 A3 and 21 8C
        #expect(s.rejected == 1) // 21 8C is a 7F; the 21 A3 timeout is a link error, not "unsupported"
        #expect(s.summary.hasSuffix("(1 — не поддерживаются блоком)"))
        #expect(AdaptationMap(snapshot: s)?.layout == .rpmThrottle)
    }
}
