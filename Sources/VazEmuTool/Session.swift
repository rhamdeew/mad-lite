import VazEmu

/// 1 ms in machine cycles at 16 MHz (6 oscillator periods per cycle).
let ms = 2667

/// ISO 14230 fast init on the emulated K-line: RxD (P3.0) low for 25 ms, high for 25 ms.
func fastInit(_ board: C509Board) throws {
    board.portInputs[0xB0] = 0xFE
    try board.run(machineCycles: 25 * ms)
    board.portInputs[0xB0] = 0xFF
    try board.run(machineCycles: 25 * ms)
}

/// Feeds `request` into the ECU's serial port and returns what it sends within `window` cycles.
func exchange(_ board: C509Board, _ request: [UInt8], window: Int = 300 * ms) throws -> [UInt8] {
    _ = board.takeSerialOutput()
    board.serialIn += request
    try board.run(machineCycles: window)
    return board.takeSerialOutput()
}
