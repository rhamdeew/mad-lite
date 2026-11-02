import Foundation
import Testing
import VazCore

/// `BootstrapClient.waitForLoader`: the host sends 00h before the block is powered; the
/// loader answers 55h only once it comes out of reset (live spare ECU, 2026-10-31).
@Suite struct WaitForLoaderTests {
    /// Echoing cable; the block "powers up" after `silentTries` 00h bytes. `replies` are
    /// what it answers from then on (e.g. a power-up glitch before 55h).
    actor FakeLine: KLineTransport {
        nonisolated let echoesWrites: Bool
        var silentTries: Int
        var replies: [UInt8]
        var inbox: [UInt8] = []
        private(set) var sent = 0

        init(echo: Bool = true, silentTries: Int, replies: [UInt8] = [0x55]) {
            echoesWrites = echo; self.silentTries = silentTries; self.replies = replies
        }
        func fastInit() async throws {}
        func write(_ bytes: [UInt8]) async throws {
            sent += bytes.count
            if echoesWrites { inbox += bytes }
            if silentTries > 0 { silentTries -= 1 } else if !replies.isEmpty { inbox.append(replies.removeFirst()) }
        }
        func read(count: Int, timeout: Duration) async throws -> [UInt8] {
            guard inbox.count >= count else { throw KLineError.timeout(expected: count, received: inbox.count) }
            defer { inbox.removeFirst(count) }
            return Array(inbox.prefix(count))
        }
        func flush() async throws { inbox.removeAll() }
    }

    @Test func waitsUntilTheBlockIsPoweredUp() async throws {
        let line = FakeLine(silentTries: 7)
        try await BootstrapClient(transport: line).waitForLoader(timeout: .seconds(5), interval: .milliseconds(1))
        #expect(await line.sent == 8)
    }

    @Test func skipsAPowerUpGlitch() async throws {
        let line = FakeLine(silentTries: 2, replies: [0x00, 0x55])
        try await BootstrapClient(transport: line).waitForLoader(timeout: .seconds(5), interval: .milliseconds(1))
        #expect(await line.sent == 4)
    }

    @Test func givesUpWhenTheLoaderNeverAnswers() async throws {
        let line = FakeLine(echo: true, silentTries: 1_000_000)
        await #expect(throws: BootstrapError.loaderSilent) {
            try await BootstrapClient(transport: line).waitForLoader(timeout: .milliseconds(50), interval: .milliseconds(1))
        }
    }
}
