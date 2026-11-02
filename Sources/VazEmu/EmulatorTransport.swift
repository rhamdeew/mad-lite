import VazCore

/// K-line transport backed by the firmware emulator, so `KWPClient` can talk to
/// real ECU code. Time is emulated: timeouts are measured in ECU machine cycles,
/// not wall-clock time.
public actor EmulatorTransport: KLineTransport {
    /// Machine cycles per millisecond at the Январь 5.1 crystal (16 MHz, 6 clocks per cycle).
    public static let cyclesPerMs = 2667
    /// RxD is P3.0.
    static let port3: UInt8 = 0xB0

    private let board: C509Board
    private var received: [UInt8] = []

    /// The emulator has no adapter echo.
    public nonisolated let echoesWrites = false

    public init(rom: [UInt8]) {
        board = C509Board(rom: rom)
    }

    /// Runs the ECU for `ms` milliseconds of emulated time, collecting what it transmits.
    public func run(ms: Int) throws {
        for _ in 0..<ms {
            try board.run(machineCycles: Self.cyclesPerMs)
            received += board.takeSerialOutput()
        }
    }

    /// UART 0 baud rate reload (S0RELH:S0RELL): tells whether the firmware switched speed.
    func serialReload() -> Int {
        Int(board.cpu.sfr[Int(C509Board.S0RELH)] & 0x03) << 8 | Int(board.cpu.sfr[Int(C509Board.S0RELL)])
    }

    /// Powers the ECU on and waits until the immobilizer handshake has given up
    /// (≈3–4 s for J5V05L19 without an immobilizer), discarding its traffic.
    public func boot(ms: Int = 5000) throws {
        try run(ms: ms)
        received.removeAll()
    }

    /// Spins the crank wheel at `rpm` (nil or 0 stops the engine).
    public func setCrank(rpm: Double?) {
        board.crankRPM = rpm.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Writes serial EEPROM bytes (blank = FFh), e.g. before `boot` to set the
    /// immobilizer state: bytes 02…07 hold [F47C, F47D] three times (2-of-3 vote),
    /// F47D.7 = 0 means "immobilizer trained" (2Dh.2).
    public func setEEPROM(_ bytes: [UInt8], at address: Int) {
        board.eeprom.memory.replaceSubrange(address..<address + bytes.count, with: bytes)
    }

    /// Output image the firmware last sent to the relay driver (`F999` in J5V05L19), nil
    /// before the first transfer.
    public var outputDriverImage: UInt8? { board.outputDriver.latched }

    /// Starts recording port 4/5 pin changes (injectors, ignition) with the crank angle.
    public func startOutputTrace() { board.outputTrace = .init() }

    /// Recorded pin changes since `startOutputTrace`.
    public var outputTrace: C509Board.OutputTrace? { board.outputTrace }

    /// Watchdog resets since power-on (0 while the firmware refreshes it).
    public var watchdogResets: Int { board.watchdogResets }

    /// Sets a 10-bit A/D input (see docs/j5-hardware.md for the channel map).
    public func setADC(channel: Int, value: UInt16) {
        board.adcInputs[channel] = value
    }

    public func fastInit() async throws {
        board.portInputs[Self.port3] = 0xFE
        try run(ms: 25)
        board.portInputs[Self.port3] = 0xFF
        try run(ms: 25)
    }

    public func write(_ bytes: [UInt8]) async throws {
        board.serialIn += bytes
    }

    public func read(count: Int, timeout: Duration) async throws -> [UInt8] {
        let limit = Int(timeout.components.seconds) * 1000 + Int(timeout.components.attoseconds / 1_000_000_000_000_000)
        var elapsed = 0
        while received.count < count {
            guard elapsed < max(limit, 1) else {
                throw KLineError.timeout(expected: count, received: received.count)
            }
            try run(ms: 1)
            elapsed += 1
        }
        defer { received.removeFirst(count) }
        return Array(received.prefix(count))
    }

    public func flush() async throws {
        received.removeAll()
    }
}
