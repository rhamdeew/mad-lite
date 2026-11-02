import Foundation
import VazCore
import VazEmu

// vazemu FIRMWARE.bin [machine-cycles]
// Runs the image on the bare CPU core and reports where time is spent and which
// SFRs the firmware touches — used to decide which peripherals to emulate next.

let args = CommandLine.arguments
guard args.count >= 2, let image = FileManager.default.contents(atPath: args[1]) else {
    print("usage: vazemu FIRMWARE.bin [machine-cycles]")
    exit(1)
}
let budget = args.count > 2 ? Int(args[2]) ?? 2_000_000 : 2_000_000

if args.count > 2, args[2] == "engine" {
    // vazemu FW engine RPM [MAF volts]: boot, spin the crank, read 21 01 every second.
    let rpm = args.count > 3 ? Double(args[3]) ?? 800 : 800
    let maf = args.count > 4 ? Double(args[4]) ?? 1.0 : 1.0
    let line = EmulatorTransport(rom: Array(image.prefix(0x10000)))
    await line.setADC(channel: Sensors.coolantChannel, value: Sensors.coolant(celsius: 90))
    if !args.contains("novolt") { await line.setADC(channel: Sensors.voltageChannel, value: Sensors.supply(volts: 14)) }
    if !args.contains("nomaf") { await line.setADC(channel: Sensors.mafChannel, value: Sensors.voltage(maf)) }
    if args.contains("spinboot") { await line.setCrank(rpm: rpm) }
    try await line.boot(ms: args.contains("longboot") ? 10000 : 5000)
    let client = KWPClient(transport: line, interRequestDelay: .zero)
    do {
        print("connect:", try await client.connect())
        print("first read rpm:", try await client.readLiveData().rpm)
    } catch {
        print("connect failed: \(error) — ЭБУ в цикле софт-рестартов (см. docs/emulator.md)")
    }
    await line.setCrank(rpm: rpm)
    for second in 1...6 {
        try await line.run(ms: 1000)
        let d = try await client.readLiveData()
        print(String(format: "t+%ds rpm %4.0f  ЦН %5.1f  впрыск %5.2f мс  УОЗ %5.1f  AFR %@  ХХ %4.0f/%4.0f  РХХ %3d  режим %@  неиспр %@",
                     second, d.rpm, d.cycleAir, d.injectionTime, d.ignitionAdvance, d.afr.map { String(format: "%5.2f", $0) } ?? "  Р83", d.idleRpm, d.idleRpmTarget,
                     d.iacActual, d.mode1.active.joined(separator: ","), d.activeFaults.joined(separator: ",")))
    }
    exit(0)
}

if args.count > 2, args[2] == "kwp" {
    let board = C509Board(rom: Array(image.prefix(0x10000)))
    if let ctArg = args.first(where: { $0.hasPrefix("ct=") }), let v = Double(ctArg.dropFirst(3)) {
        board.adcInputs[Sensors.coolantChannel] = Sensors.coolant(celsius: v)
    }
    if !args.contains("novolt") { board.adcInputs[Sensors.voltageChannel] = Sensors.supply(volts: 14) }
    if let mafArg = args.first(where: { $0.hasPrefix("maf=") }), let v = Double(mafArg.dropFirst(4)) {
        board.adcInputs[Sensors.mafChannel] = Sensors.voltage(v)
    }
    if let rpmArg = args.first(where: { $0.hasPrefix("rpm=") }), let v = Double(rpmArg.dropFirst(4)) {
        board.crankRPM = v
    }
    if let tpsArg = args.first(where: { $0.hasPrefix("tps=") }), let v = Double(tpsArg.dropFirst(4)) {
        board.adcInputs[Sensors.throttleChannel] = Sensors.voltage(v)
    }
    if let atArg = args.first(where: { $0.hasPrefix("at=") }), let v = Double(atArg.dropFirst(3)) {
        board.adcInputs[Sensors.airTempChannel] = Sensors.airTemp(celsius: v)
    }
    var irqCounts: [UInt16: Int] = [:]
    // Optional instrumentation. `trace`: interrupt counts. `s0trace`: serial/ADC SFR writes.
    // `watch`: single-step and stop at the first soft-restart site (0x2054/0x208D/0x4949),
    // logging watchdog-counter writes (IRAM 3C/3D) and EX0 entries.
    if args.contains("trace") {
        let baseAck = board.cpu.onInterruptEntry
        board.cpu.onInterruptEntry = { irqCounts[$0, default: 0] += 1; baseAck?($0) }
    }
    if args.contains("s0trace") {
        let baseWrite = board.cpu.sfrWrite
        board.cpu.sfrWrite = { a, v in
            if [0x98, 0x99, 0xD8, 0xDA, 0xDC].contains(a) {
                let name = [0x98: "S0CON", 0x99: "S0BUF", 0xD8: "ADCON0", 0xDA: "ADDATL", 0xDC: "ADCON1"][a]!
                print("t+\(board.cpu.cycles / 2667) ms  \(name) <- \(String(format: "%02X", v))")
            }
            baseWrite?(a, v)
        }
    }
    let waitSeconds = args.count > 3 ? Int(args[3]) ?? 2 : 2
    let hexs0 = { (b: [UInt8]) in b.map { String(format: "%02X", $0) }.joined(separator: " ") }
    if args.contains("watch") {
        let cpu = board.cpu
        var ex0Times: [Int] = []
        var pcs: [UInt16] = []
        let baseEntry = cpu.onInterruptEntry
        cpu.onInterruptEntry = { if $0 == 0x0003 { ex0Times.append(Int(cpu.cycles / 2667)) }; baseEntry?($0) }
        var t = 0
        // `cells[=38,39,3C,…]`: log every change of these IRAM cells (hex) with the last PCs.
        let cellArg = args.first { $0.hasPrefix("cells") }
        let cells = cellArg.flatMap { $0.split(separator: "=").dropFirst().first }
            .map { $0.split(separator: ",").compactMap { Int($0, radix: 16) } } ?? [0x38, 0x39, 0x3C, 0x3D, 0xBE]
        var lastCells = cells.map { cpu.iram[$0] }
        // `xcells=F4C5,…`: the same for XRAM cells.
        let xcells = (args.first { $0.hasPrefix("xcells=") })
            .map { $0.dropFirst(7).split(separator: ",").compactMap { Int($0, radix: 16) } } ?? []
        var lastX = xcells.map { cpu.xram[$0] }
        // `pc=ADDR`: report the first hits of a code address with its caller.
        let hitAddress = (args.first { $0.hasPrefix("pc=") }).flatMap { UInt16($0.dropFirst(3), radix: 16) }
        var hits = 0
        let limit = (args.first { $0.hasPrefix("ms=") }).flatMap { Int($0.dropFirst(3)) } ?? 4000
        while t < limit {
            pcs.append(cpu.pc)
            if pcs.count > 4096 { pcs.removeFirst(2048) }
            try board.step()
            if let at = hitAddress, cpu.pc == at, hits < 5 {
                // Return address of the LCALL that got here (top of stack: high byte, then low).
                let ret = UInt16(cpu.iram[Int(cpu.sp)]) << 8 | UInt16(cpu.iram[Int(cpu.sp &- 1)])
                print("hit \(hex(at)) at t+\(t) called from \(hex(ret &- 3)) | \(pcs.suffix(8).map { hex($0) }.joined(separator: " "))")
                hits += 1
            }
            for (i, cell) in xcells.enumerated() where cpu.xram[cell] != lastX[i] {
                print("X:\(hex(cell)) \(hex(lastX[i], 2))→\(hex(cpu.xram[cell], 2)) at t+\(t) pc \(hex(cpu.pc)) | \(pcs.suffix(4).map { hex($0) }.joined(separator: " "))")
                lastX[i] = cpu.xram[cell]
            }
            if cellArg != nil {
                for (i, cell) in cells.enumerated() where cpu.iram[cell] != lastCells[i] {
                    print("\(hex(UInt8(cell), 2))h \(hex(lastCells[i], 2))→\(hex(cpu.iram[cell], 2)) at t+\(t) pc \(hex(cpu.pc)) | \(pcs.suffix(4).map { hex($0) }.joined(separator: " "))")
                    lastCells[i] = cpu.iram[cell]
                }
            }
            t = Int(cpu.cycles / 2667)
            if args.contains("chain"), let last = ex0Times.last, t - last > 300, ex0Times.count > 3 {
                print("EX0 stalled after \(ex0Times.count) entries (last t+\(last))")
                print("last PCs: " + pcs.map { hex($0) }.joined(separator: " "))
                break
            }
            if cpu.cycles > 1000 * 2667, [0x2054, 0x208D, 0x4949].contains(cpu.pc) {
                print("SOFT-RESTART site \(hex(cpu.pc)) at t+\(t) ms  3C=\(hex(cpu.iram[0x3C], 2)) 3D=\(hex(cpu.iram[0x3D], 2))")
                break
            }
        }
        if !ex0Times.isEmpty { print("EX0 entries: " + ex0Times.map { "\($0)" }.joined(separator: " ")) }
    } else {
        try board.run(machineCycles: waitSeconds * 1000 * ms)
    }
    print("before init (\(waitSeconds) s), traffic: " + hexs0(board.takeSerialOutput()))
    print("S0CON before init \(String(board.cpu.sfr[0x98], radix: 16))")
    try fastInit(board)
    let hexs = { (b: [UInt8]) in b.map { String(format: "%02X", $0) }.joined(separator: " ") }
    print("startCommunication → " + hexs(try exchange(board, [0x81, 0x10, 0xF1, 0x81, 0x03], window: args.contains("ks") ? 300 * ms : 3_000 * ms)))
    print("S0CON \(String(board.cpu.sfr[0x98], radix: 16))")
    if args.contains("trace") {
        print("interrupts: " + irqCounts.sorted { $0.key < $1.key }.map { "\(hex($0.key))×\($0.value)" }.joined(separator: " "))
    }
    if args.contains("ks") {
        // Read the ROM checksum the firmware computes in the background (XRAM F8F8) over time.
        for second in 1...240 {
            try board.run(machineCycles: 1000 * ms)
            let ks = UInt16(board.cpu.xram[0xF8F8]) | UInt16(board.cpu.xram[0xF8F9]) << 8
            if ks != 0 { print("F8F8 = \(String(format: "%04X", ks)) after +\(second) s"); break }
        }
    }
    exit(0)
}

let board = C509Board(rom: Array(image.prefix(0x10000)))
let cpu = board.cpu
var sfrReads: [UInt8: Int] = [:]
var sfrWrites: [UInt8: Int] = [:]
let boardRead = cpu.sfrRead, boardWrite = cpu.sfrWrite
cpu.sfrRead = { sfrReads[$0, default: 0] += 1; return boardRead?($0) }
cpu.sfrWrite = { addr, v in sfrWrites[addr, default: 0] += 1; boardWrite?(addr, v) }
var interrupts: [UInt16: Int] = [:]
let boardAck = cpu.onInterruptEntry
cpu.onInterruptEntry = { interrupts[$0, default: 0] += 1; boardAck?($0) }

var pcHits: [UInt16: Int] = [:]
var instructions = 0
do {
    while cpu.cycles < UInt64(budget) {
        pcHits[cpu.pc, default: 0] += 1
        try board.step()
        instructions += 1
    }
} catch {
    print("stopped: \(error) after \(instructions) instructions")
}

func hex(_ v: some BinaryInteger, _ width: Int = 4) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, width - s.count)) + s
}

print("cycles \(cpu.cycles), instructions \(instructions), pc \(hex(cpu.pc)), sp \(hex(cpu.sp, 2))")
print("interrupts: " + interrupts.sorted { $0.key < $1.key }.map { "\(hex($0.key))×\($0.value)" }.joined(separator: " "))
print("serial out: " + board.takeSerialOutput().prefix(64).map { hex($0, 2) }.joined(separator: " "))
print("hottest addresses:")
for (pc, n) in pcHits.sorted(by: { $0.value > $1.value }).prefix(12) {
    print("  \(hex(pc))  \(n)")
}
print("SFR reads:  " + sfrReads.sorted { $0.key < $1.key }.map { "\(hex($0.key, 2))×\($0.value)" }.joined(separator: " "))
print("SFR writes: " + sfrWrites.sorted { $0.key < $1.key }.map { "\(hex($0.key, 2))×\($0.value)" }.joined(separator: " "))
let names: [(UInt8, String)] = [(0xB1, "SYSCON"), (0xC8, "T2CON"), (0xC1, "CCEN"), (0xC9, "CC4EN"), (0xE1, "CTCON"),
    (0xBC, "CT1CON"), (0xF6, "CMEN"), (0xF7, "CMSEL"), (0xA8, "IEN0"), (0xB8, "IEN1"), (0x9A, "IEN2"), (0xBE, "IEN3"),
    (0xA9, "IP0"), (0xB9, "IP1"), (0x88, "TCON"), (0x89, "TMOD"), (0xB4, "PRSC"), (0xC0, "IRCON0"), (0xE8, "P4"), (0xF8, "P5"), (0x90, "P1"), (0xB0, "P3")]
print(names.map { "\($0.1)=\(hex(cpu.sfr[Int($0.0)], 2))" }.joined(separator: " "))
let reload = Int(cpu.sfr[0xBA] & 3) << 8 | Int(cpu.sfr[0xAA])
print("S0CON \(hex(cpu.sfr[0x98], 2)) ADCON0 \(hex(cpu.sfr[0xD8], 2)) PCON \(hex(cpu.sfr[0x87], 2)) PRSC \(hex(cpu.sfr[0xB4], 2)) S0REL \(hex(reload, 3)) TMOD \(hex(cpu.sfr[0x89], 2)) TH1 \(hex(cpu.sfr[0x8D], 2))")
let byteCycles = board.serialByteCycles
print("serial byte = \(byteCycles) machine cycles; for 10400 baud fosc = \(Double(byteCycles) * 6 * 10400 / 10 / 1e6) MHz")
