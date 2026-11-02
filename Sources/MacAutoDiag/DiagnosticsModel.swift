import Foundation
import Observation
import VazCore
import VazEmu
import VazSerial

/// Diagnostic session state: connects a `KWPClient` to the emulator (or, later,
/// a KKL cable), polls live data and manages trouble codes.
@MainActor @Observable
final class DiagnosticsModel {
    enum State: Equatable {
        case idle
        case booting
        case connecting
        case connected
        /// Link lost during a session; trying again (the log stays open).
        case reconnecting(attempt: Int, reason: String)
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Не подключено"
            case .booting: "Эмулятор: включение ЭБУ и иммобилизация (≈4 с времени ЭБУ)…"
            case .connecting: "Быстрая инициализация и startCommunication…"
            case .connected: "Подключено"
            case .reconnecting(let n, let reason): "Связь потеряна (\(reason)). Переподключение, попытка \(n)…"
            case .failed(let message): "Ошибка: \(message)"
            }
        }
    }

    /// Simulated sensor inputs for the emulator.
    struct Inputs: Equatable {
        var coolant = 90.0
        var airTemp = 25.0
        var throttleVolts = 0.5
        var supplyVolts = 14.0
        var mafVolts = 1.0
        /// Crank wheel speed; 0 — engine stopped.
        var rpm = 0.0
        /// Load sensor: MAF, or MAP + intake air temperature (J5LS). Set from the image's flags.
        var usesMAP = false
        var mapVolts = 1.0
        var lambdaVolts = 0.45
    }

    /// Air-sensor wiring read from the image the emulator runs (J5LS flags).
    private(set) var wiring: Sensors.Wiring?

    private(set) var state: State = .idle
    /// `live` as merged with the J5LS record's flags; this is the last `21 01` as received.
    private var lastBase: J5LiveData?
    private(set) var live: J5LiveData?
    private(set) var dtcs: [DTC]?
    /// Stored codes are re-read while connected (PollPlan.troubleCodeInterval), so a new one shows up by itself.
    private var lastDTCRead: ContinuousClock.Instant?
    /// Wall-clock time of the last code read, for the agent (how fresh `dtcs` is).
    private(set) var dtcsReadAt: Date?
    private(set) var keyBytes: [UInt8] = []
    private(set) var firmwareName = ""
    private(set) var requests = 0
    /// J5LS extended record id if the ECU answers one (`21 8C/0D/0F`).
    private(set) var extendedRecord: UInt8?
    private(set) var extended: J5LSLiveData?
    /// `21 03`: sensor A/D codes and port copies, read about once a second; nil until the
    /// first answer. `inputsSupported` turns false when the ECU rejects the identifier.
    // MARK: Manual control (service 30)

    struct ControlEvent: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
        let ok: Bool
    }

    /// The owner confirmed the risk for this session; reset on disconnect.
    var controlEnabled = false
    /// Identifiers currently under manual control (to be returned to the ECU).
    private(set) var controlled: Set<UInt8> = []
    /// nil — not tried yet; false — the ECU rejected service 30.
    private(set) var controlSupported: Bool?
    private(set) var controlEvents: [ControlEvent] = []
    /// Commands wait here and run in the poll loop between requests, so they never cut into
    /// a `21 01` exchange (the client actor is re-entrant across transport awaits).
    private var pendingControl: [ActuatorCommand] = []

    func control(_ command: ActuatorCommand) {
        guard controlEnabled, state == .connected else { return }
        pendingControl.append(command)
    }

    /// Returns every identifier taken during this session.
    func returnAllControl() {
        let ids = controlled.isEmpty ? ActuatorCommand.allIDs : controlled.sorted()
        for id in ids { control(.returnControl(id)) }
    }

    /// Safe first command: blink the Check Engine lamp for a second, then hand it back.
    func checkControlSupport() {
        control(.output(.checkEngine, on: true))
        Task {
            try? await idle(ms: 1500)
            control(.output(.checkEngine, on: false))
            control(.returnControl(ActuatorCommand.Output.checkEngine.rawValue))
        }
    }

    private func runPendingControl(client: KWPClient) async throws {
        while !pendingControl.isEmpty {
            let command = pendingControl.removeFirst()
            do {
                let response = try await client.control(command)
                requests += 1
                try log?.appendRaw(request: command.request, response: response)
                if case .returnControl(let id) = command { controlled.remove(id) } else { controlled.insert(command.id) }
                controlSupported = true
                record(command.title, ok: true)
            } catch KWPError.negativeResponse(service: 0x30, code: let code) {
                if code == 0x11 { controlSupported = false }
                record("\(command.title) — блок отклонил: \(KWPError.describe(code: code))", ok: false)
            }
        }
    }

    private func record(_ text: String, ok: Bool) {
        controlEvents.insert(ControlEvent(text: text, ok: ok), at: 0)
        if controlEvents.count > 30 { controlEvents.removeLast() }
        log?.mark("ручное управление: \(text)")
    }

    // MARK: Snapshot

    /// Set by the button; the poll loop takes the snapshot between requests.
    private var snapshotRequested = false
    private(set) var snapshotRunning = false
    /// Result of the last snapshot, shown under the toolbar.
    private(set) var snapshotReport: (ok: Bool, text: String)?
    private(set) var lastSnapshotFile: URL?
    /// Mixture learning from the last snapshot (nil if its RAM reads were incomplete).
    private(set) var adaptation: AdaptationMap?
    /// Identification text of the last snapshot (`1A 80`), to match the open firmware.
    private(set) var snapshotIdentification: String?

    /// Logs, snapshots and flash dumps: a folder in Documents named after the edition.
    static let dataDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Edition.dataFolder, isDirectory: true)

    static var snapshotsDirectory: URL {
        dataDirectory.appendingPathComponent("Snapshots", isDirectory: true)
    }

    func takeSnapshot() {
        guard state == .connected, !snapshotRunning else { return }
        snapshotRequested = true
        snapshotRunning = true
        snapshotReport = nil
    }

    private func runSnapshot(client: KWPClient) async throws {
        snapshotRequested = false
        defer { snapshotRunning = false }
        let pausedAt = ContinuousClock.now
        let snapshot = try await client.takeSnapshot(source: emulator != nil ? "эмулятор: \(firmwareName)" : "K-line: \(firmwareName)")
        requests += snapshot.entries.count
        adaptation = AdaptationMap(snapshot: snapshot)
        snapshotIdentification = snapshot.entries.first { $0.request == "1A 80" }?.note
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let file = Self.snapshotsDirectory.appendingPathComponent("snapshot_\(formatter.string(from: snapshot.taken)).json")
        do {
            try FileManager.default.createDirectory(at: Self.snapshotsDirectory, withIntermediateDirectories: true)
            let data = try snapshot.json()
            try data.write(to: file)
            // A copy next to the log, if one is being written: the folder then holds everything.
            if let folder = lastLogFolder, log != nil {
                try data.write(to: folder.appendingPathComponent("snapshot.json"))
            }
            lastSnapshotFile = file
            // The poll stands still meanwhile (≈4 s on the car): say so, or the gap looks like a dropout.
            let paused = (ContinuousClock.now - pausedAt).components.seconds
            log?.mark("снимок блока: \(snapshot.summary), опрос стоял \(paused) с")
            snapshotReport = (true, "Снимок сохранён: \(snapshot.summary) → \(file.lastPathComponent)")
        } catch {
            snapshotReport = (false, "Снимок не сохранён: \(error.localizedDescription)")
        }
    }

    /// Emulator only: the output image the firmware sent to the relay driver (`F999`).
    private(set) var driverImage: UInt8?

    private(set) var adcInputs: J5Inputs?
    private(set) var inputsSupported: Bool?
    /// What each poll cycle reads (fast values every cycle, the rest less often); reset per session.
    private(set) var pollPlan = PollPlan(hasExtended: false)
    /// Active log, if recording.
    private(set) var log: SensorLogWriter?
    private(set) var lastLogFolder: URL?
    private var rom: [UInt8]?
    var inputs = Inputs.fromLaunchArguments() {
        didSet { Task { await applyInputs() } }
    }

    private var client: KWPClient?
    private var emulator: EmulatorTransport?
    private var pollTask: Task<Void, Never>?

    /// The session runs on the emulator (whatever source the picker remembers).
    var usesEmulator: Bool { emulator != nil }

    var isActive: Bool {
        switch state {
        case .booting, .connecting, .connected, .reconnecting: true
        case .idle, .failed: false
        }
    }

    /// Opens a fresh link for a reconnect (serial: reopen the port, it may have been unplugged).
    private var reopen: (() throws -> KWPClient)?

    /// Connects through a KKL adapter on a serial port.
    func connectSerial(path: String) {
        disconnect()
        firmwareName = path
        state = .connecting
        pollTask = Task {
            do {
                let open = { KWPClient(transport: try SerialKLineTransport(path: path)) }
                reopen = open
                let client = try open()
                self.client = client
                keyBytes = try await client.connect()
                try await runSession(client: client, line: nil)
            } catch is CancellationError {
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Result of the last «Проверить кабель», shown under the toolbar.
    private(set) var cableReport: (ok: Bool, text: String)?

    /// Opens the port, checks the adapter echo and says in plain words what it means.
    func checkCable(path: String) {
        cableReport = nil
        Task {
            do {
                let line = try SerialKLineTransport(path: path)
                cableReport = switch try await line.checkEcho() {
                case .echoOK:
                    (true, "Кабель в порядке: эхо 4 из 4 байт, K-line запитана. Включите зажигание и нажмите «Подключить».")
                case .noEcho:
                    (false, "Нет эха: на кабель не подаётся питание. Если кабель не вставлен в колодку OBD — так и должно быть: порт открылся, кабель виден. В машине: проверьте, что разъём OBD вставлен до конца, на выводе 16 есть +12 В (предохранитель), масса на 4/5. Если питание есть, а эха нет — кабель неисправен.")
                case .badEcho(let sent, let received):
                    (false, "Эхо искажено: отправлено \(Self.hex(sent)), получено \(Self.hex(received)). Плохой контакт массы, помехи или на линии работает другое устройство (сигнализация, иммобилизатор).")
                }
            } catch {
                cableReport = (false, "Порт не открылся: \(error.localizedDescription). Переподключите кабель к USB и нажмите «Обновить порты».")
            }
        }
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

    /// Starts the emulator with `rom` and connects to it.
    func connectEmulator(rom: [UInt8], name: String) {
        disconnect()
        firmwareName = name
        self.rom = rom
        let line = EmulatorTransport(rom: rom)
        emulator = line
        let wiring = Sensors.Wiring.detect(rom: rom, softwareID: (try? Firmware(data: Data(rom)))?.softwareID)
        self.wiring = wiring
        // `--load map|maf` (development, tutorial screenshots): override the detected sensor.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--load"), i + 1 < args.count {
            inputs.usesMAP = args[i + 1] == "map"
        } else {
            inputs.usesMAP = wiring.usesMAP
        }
        let client = KWPClient(transport: line)
        self.client = client
        state = .booting
        pollTask = Task {
            do {
                await applyInputs()
                try await line.boot()
                state = .connecting
                keyBytes = try await client.connect()
                try await runSession(client: client, line: line)
            } catch is CancellationError {
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        if !controlled.isEmpty, let client {
            // Hand manual control back before the line goes quiet: stop polling, then return.
            let ids = controlled.sorted()
            let poll = pollTask
            poll?.cancel()
            Task {
                _ = await poll?.value
                try? await client.returnAllControl(ids: ids)
            }
        }
        controlled = []
        pendingControl = []
        controlEnabled = false
        controlSupported = nil
        controlEvents = []
        snapshotRequested = false
        snapshotRunning = false
        adaptation = nil
        snapshotIdentification = nil
        stopRecording()
        pollTask?.cancel()
        pollTask = nil
        client = nil
        reopen = nil
        emulator = nil
        live = nil
        lastBase = nil
        dtcs = nil
        lastDTCRead = nil
        dtcsReadAt = nil
        keyBytes = []
        requests = 0
        extendedRecord = nil
        extended = nil
        adcInputs = nil
        inputsSupported = nil
        pollPlan = PollPlan(hasExtended: false)
        rom = nil
        state = .idle
    }

    /// After startCommunication: diagnostic session, J5LS detection, DTCs, then polling.
    private func runSession(client: KWPClient, line: EmulatorTransport?) async throws {
        // Optional by the spec; some firmwares may reject it — not fatal.
        try? await client.startDiagnosticSession()
        extendedRecord = try await client.detectExtendedRecord()
        state = .connected
        await applyInputs() // the crank starts only now, see applyInputs
        try await refreshDTCs()
        // `--record` (development): start logging as soon as the session is up.
        if CommandLine.arguments.contains("--record") { startRecording() }
        // `--snapshot` (development, screenshots): take «Снимок блока» right away.
        if CommandLine.arguments.contains("--snapshot") { takeSnapshot() }
        if CommandLine.arguments.contains("--control"), line != nil {
            controlEnabled = true
            control(.idleRPM(1000))
        }
        // `--scenario` (development, tutorial log): replay lesson 1 in the emulator while recording.
        if CommandLine.arguments.contains("--scenario"), line != nil { Task { await runScenario() } }
        var client = client
        while !Task.isCancelled {
            do {
                try await pollLoop(client: client, line: line)
            } catch let error where Self.isLinkError(error) {
                // Loose connector, cranking voltage dip, USB unplugged: keep the log, mark it, retry.
                log?.mark("обрыв связи: \(error.localizedDescription)")
                client = try await reconnect(client: client, reason: error.localizedDescription)
                log?.mark("связь восстановлена")
                if !controlled.isEmpty {
                    // Whatever the ECU kept through the drop goes back to it before polling resumes.
                    pendingControl = []
                    try? await client.returnAllControl(ids: controlled.sorted())
                    controlled = []
                    record("связь прерывалась — управление возвращено ЭБУ", ok: true)
                }
            }
        }
    }

    /// Timeouts, broken echo, bad frame checksum and serial I/O errors mean the link dropped.
    /// `7F 21 10` to the poll that worked a moment ago means the ECU closed the session
    /// (no request for ~5 s, P3max). Anything else would not get better by reconnecting.
    static func isLinkError(_ error: Error) -> Bool {
        if case KWPError.negativeResponse(service: 0x21, code: 0x10) = error { return true }
        return error is KLineError || error is KWPFrameError || error is SerialKLineTransport.OpenError
    }

    /// Recovery learned on J5V05L19 in the emulator (docs/kwp2000-j5.md, «Обрыв связи»):
    /// while the session is alive the ECU ignores a new fast init, so first just ask again
    /// (testerPresent); if that fails, close the session (stopCommunication) and start over
    /// with fast init + startCommunication. Retries every 2 s until it works or the user stops.
    private func reconnect(client: KWPClient, reason: String) async throws -> KWPClient {
        var attempt = 0
        while true {
            attempt += 1
            state = .reconnecting(attempt: attempt, reason: reason)
            try await idle(ms: attempt == 1 ? 300 : 2000)
            do {
                if attempt == 1 {
                    try await client.testerPresent()
                    state = .connected
                    return client
                }
                try? await client.disconnect()
                try await idle(ms: 500)
                let fresh = try reopen?() ?? client
                self.client = fresh
                keyBytes = try await fresh.connect()
                try? await fresh.startDiagnosticSession()
                state = .connected
                return fresh
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
    }

    /// Waits; in the emulator the ECU's clock only runs while it is stepped, so step it instead.
    private func idle(ms: Int) async throws {
        if let emulator { try await emulator.run(ms: ms) } else { try await Task.sleep(for: .milliseconds(ms)) }
    }

    // MARK: - Tutorial scenario

    /// Lesson 1 of docs/tutorial as a script: engine start, throttle, load sweep, cold engine,
    /// TPS and coolant faults — each step marked. The O2 sensor toggles 0.2/0.7 V every second so
    /// the closed-loop correction moves as on a car.
    private func runScenario() async {
        if log == nil { startRecording() }
        let steps: [(String, Double, (inout Inputs) -> Void)] = [
            ("двигатель стоит", 4, { $0.rpm = 0 }),
            ("2500 об/мин, дроссель закрыт", 10, { $0.rpm = 2500; $0.mafVolts = 2.5 }),
            ("дроссель открыт, 3000", 10, { $0.rpm = 3000; $0.throttleVolts = 2.5 }),
            ("нагрузка 1,5 В", 8, { $0.mafVolts = 1.5 }),
            ("нагрузка 2,5 В", 8, { $0.mafVolts = 2.5 }),
            ("нагрузка 3,5 В", 8, { $0.mafVolts = 3.5 }),
            ("холодный, 1500", 10, { $0.mafVolts = 2.5; $0.throttleVolts = 0.5; $0.rpm = 1500; $0.coolant = -10 }),
            ("прогрет", 8, { $0.coolant = 90 }),
            // Part throttle: closed loop starts after ~20 s of ECU time (emulator, J5V05L19).
            ("езда 2000, ДПДЗ 1,0 В", 40, { $0.throttleVolts = 1.0; $0.rpm = 2000; $0.mafVolts = 1.8 }),
            ("езда 3000, ДПДЗ 1,2 В", 30, { $0.throttleVolts = 1.2; $0.rpm = 3000; $0.mafVolts = 2.2 }),
            ("ХХ", 6, { $0.throttleVolts = 0.5; $0.rpm = 1500; $0.mafVolts = 2.5 }),
            ("ДПДЗ отключён", 8, { $0.throttleVolts = 0 }),
            ("ДПДЗ подключён", 6, { $0.throttleVolts = 0.5 }),
            ("ДТОЖ обрыв", 8, { $0.coolant = -60 }),
            ("ДТОЖ восстановлен", 6, { $0.coolant = 90 }),
        ]
        for (text, seconds, change) in steps {
            guard log != nil else { return }
            change(&inputs)
            mark(text)
            let end = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < end, log != nil {
                try? await Task.sleep(for: .seconds(1))
                inputs.lambdaVolts = inputs.lambdaVolts > 0.45 ? 0.2 : 0.7
            }
        }
        stopRecording()
    }

    // MARK: - Agent

    /// Running `sample` calls; the poll loop feeds every frame to each of them.
    private var samplers: [UUID: SampleStats] = [:]

    /// Statistics over `seconds` of polling. Nothing is sent to the ECU beyond the usual poll.
    func sample(seconds: Double) async throws -> SampleStats {
        let id = UUID()
        samplers[id] = SampleStats(channels: LogSchema.channels(extended: extendedRecord != nil))
        defer { samplers[id] = nil }
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < end, state == .connected {
            try await Task.sleep(for: .milliseconds(100))
        }
        return samplers[id]!
    }

    /// «Снимок блока» for the agent: runs in the poll loop like the button, waits for the file.
    func takeSnapshotAndWait() async throws {
        takeSnapshot()
        let end = ContinuousClock.now + .seconds(60)
        while snapshotRunning, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(100)) }
    }

    // MARK: - Logging

    static var logsDirectory: URL {
        dataDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    func startRecording() {
        guard state == .connected, log == nil else { return }
        let started = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss" // local time, sorts by name
        let stamp = formatter.string(from: started)
        // Over the cable firmwareName is the port path; "K-line" reads better in a folder name.
        let source = emulator != nil ? (firmwareName.isEmpty ? "ecu" : firmwareName) : "K-line"
        let name = "\(stamp)_\(source)"
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "")
        let folder = Self.logsDirectory.appendingPathComponent(name, isDirectory: true)
        let session = LogSession(
            started: started,
            softwareID: emulator != nil ? firmwareName : nil, // over the cable the ECU's ID is not read
            romChecksum: live.flatMap { $0.romChecksum == 0xFFFF ? nil : String(format: "%04X", $0.romChecksum) }, // FFFF: not sent (J5LS)
            source: emulator != nil ? "эмулятор" : "K-line",
            extendedRecord: extendedRecord.map { String(format: "%02X", $0) },
            appVersion: AppVersion.current,
            notes: "",
            channels: LogSchema.channels(extended: extendedRecord != nil)
        )
        do {
            let writer = try SensorLogWriter(directory: folder, name: "log", session: session)
            // Keep the exact image next to the log so cells can be matched to its tables later.
            if let rom { try Data(rom).write(to: folder.appendingPathComponent("firmware.bin")) }
            log = writer
            writer.mark(pollPlan.description)
            lastLogFolder = folder
            // Codes read before the recording started belong to this log too.
            if let dtcs { writer.recordTroubleCodes(dtcs, at: started) }
        } catch {
            state = .failed("Не удалось начать запись: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        try? log?.finish()
        log = nil
    }

    func mark(_ text: String) {
        log?.mark(text.isEmpty ? "метка" : text)
    }

    func refreshDTCs() async throws {
        guard let client else { return }
        let read = try await client.readDTCs()
        // The log gets a code list only when it changes (the poll re-reads it every few seconds).
        if read != dtcs { log?.recordTroubleCodes(read) }
        dtcs = read
        lastDTCRead = .now
        dtcsReadAt = Date()
    }

    private func refreshInputs(client: KWPClient) async throws {
        let request: [UInt8] = [KWPClient.Service.readDataByLocalIdentifier.rawValue, 0x03]
        do {
            let raw = try await client.request(request)
            adcInputs = try J5Inputs(response: raw)
            inputsSupported = true
            requests += 1
            try log?.appendRaw(request: request, response: raw)
        } catch KWPError.negativeResponse(service: 0x21, code: _) {
            inputsSupported = false // J5LS and other non-stock builds may not have it
        }
    }

    func clearDTCs() {
        guard let client else { return }
        Task {
            do {
                log?.mark("сброс кодов")
                try await client.clearDTCs()
                try await refreshDTCs()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func readDTCs() {
        Task {
            do { try await refreshDTCs() } catch { state = .failed(error.localizedDescription) }
        }
    }

    /// Reads what `pollPlan` says is due, then writes one log row. With the emulator the ECU
    /// also runs between requests, so its main loop and filters keep going.
    /// Simulates a dropped link in the emulator demo (`--droptest`): every 20th request times out
    /// once; every 40th also lets 7 s of ECU time pass first, so the ECU closes the session.
    private var dropTestCounter = 0

    private func pollLoop(client: KWPClient, line: EmulatorTransport?) async throws {
        while !Task.isCancelled {
            if line != nil, CommandLine.arguments.contains("--droptest") {
                dropTestCounter += 1
                if dropTestCounter % 40 == 0, let line { try await line.run(ms: 7000) }
                if dropTestCounter % 20 == 0 { throw KLineError.timeout(expected: 1, received: 0) }
            }
            try await runPendingControl(client: client)
            if snapshotRequested { try await runSnapshot(client: client) }
            if pollPlan.hasExtended != (extendedRecord != nil) { pollPlan = PollPlan(hasExtended: extendedRecord != nil) }
            for request in pollPlan.due(at: .now) {
                switch request {
                case .base: try await readBase(client: client)
                case .extended: try await readExtended(client: client)
                case .inputs: if inputsSupported != false { try await refreshInputs(client: client) }
                }
                pollPlan.done(request, at: .now)
            }
            guard let frame = lastBase else { continue }
            // Flags and faults from the record when there is one: it is the fresher frame.
            let base = extended.map { frame.withStatus(from: $0) } ?? frame
            // The first frame of a session counts as "no emergency before" (no false "снят" mark).
            if base.emergencyModes != (live?.emergencyModes ?? []), let log {
                // Entering or leaving limp-home is exactly what the owner wants to see later.
                log.mark(base.emergencyModes.isEmpty ? "аварийный режим снят"
                                                     : "аварийный режим: " + base.emergencyModes.joined(separator: "; "))
            }
            live = base
            // The freshest RPM decides the mode: the record when there is one, it is read every cycle.
            if pollPlan.update(rpm: extended?.rpm ?? base.rpm, at: .now) != nil { log?.mark(pollPlan.description) }
            let row = LogSchema.values(base: base, extended: extended)
            try log?.append(row)
            for id in samplers.keys {
                samplers[id]?.add(row, activeFaults: base.activeFaults, emergencyModes: base.emergencyModes)
            }
            if let last = lastDTCRead, ContinuousClock.now - last >= PollPlan.troubleCodeInterval(mode: pollPlan.mode) {
                try await refreshDTCs()
            }
            if let line {
                try await line.run(ms: 150)
                driverImage = await line.outputDriverImage
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Raw requests so the log keeps the exact bytes (log.kwp.txt) next to the decoded values.
    private func readBase(client: KWPClient) async throws {
        let request: [UInt8] = [KWPClient.Service.readDataByLocalIdentifier.rawValue, 0x01]
        let raw = try await client.request(request)
        lastBase = try J5LiveData(response: raw)
        requests += 1
        try log?.appendRaw(request: request, response: raw)
    }

    private func readExtended(client: KWPClient) async throws {
        guard let id = extendedRecord else { return }
        let request = [KWPClient.Service.readDataByLocalIdentifier.rawValue, id]
        let raw = try await client.request(request)
        extended = try J5LSLiveData(response: raw)
        requests += 1
        try log?.appendRaw(request: request, response: raw)
    }

    private func applyInputs() async {
        guard let emulator else { return }
        let i = inputs
        await emulator.setADC(channel: Sensors.coolantChannel, value: Sensors.coolant(celsius: i.coolant))
        // Intake air on both possible inputs: pin 44 (1 kΩ pull-up) and pin 51 (4.7 kΩ).
        await emulator.setADC(channel: Sensors.airTempChannel, value: Sensors.airTemp(celsius: i.airTemp))
        await emulator.setADC(channel: Sensors.airTempAltChannel, value: Sensors.airTemp(celsius: i.airTemp, pullUp: 4700))
        await emulator.setADC(channel: Sensors.lambdaChannel, value: Sensors.voltage(i.lambdaVolts))
        await emulator.setADC(channel: Sensors.heaterCurrentChannel, value: Sensors.heaterCurrentOK)
        await emulator.setADC(channel: Sensors.throttleChannel, value: Sensors.voltage(i.throttleVolts))
        await emulator.setADC(channel: Sensors.voltageChannel, value: Sensors.supply(volts: i.supplyVolts))
        if i.usesMAP {
            // The MAP sensor takes pin 7 or pin 40; with it on pin 40 the MAF input stays empty.
            let mapChannel = wiring?.mapChannel ?? Sensors.mafChannel
            if mapChannel != Sensors.mafChannel { await emulator.setADC(channel: Sensors.mafChannel, value: 0) }
            await emulator.setADC(channel: mapChannel, value: Sensors.voltage(i.mapVolts))
        } else {
            await emulator.setADC(channel: Sensors.mafChannel, value: Sensors.voltage(i.mafVolts))
            await emulator.setADC(channel: Sensors.mapChannel, value: 0)
        }
        // Spin the crank only after the session is up: the engine is started after ignition-on,
        // as in tests and docs/emulator.md (cranking from power-on was not checked for every version).
        await emulator.setCrank(rpm: state == .connected ? i.rpm : nil)
    }
}

extension DiagnosticsModel.Inputs {
    /// `--rpm N` (development): start the demo engine at N rpm; `--tps V`: TPS signal volts.
    static func fromLaunchArguments() -> Self {
        var inputs = Self()
        let args = CommandLine.arguments
        func value(_ option: String) -> Double? {
            guard let i = args.firstIndex(of: option), i + 1 < args.count else { return nil }
            return Double(args[i + 1])
        }
        if let v = value("--tps") { inputs.throttleVolts = v }
        if let v = value("--maf") { inputs.mafVolts = v }
        if let v = value("--clt") { inputs.coolant = v }
        if let v = value("--volt") { inputs.supplyVolts = v }
        if let v = value("--mapv") { inputs.mapVolts = v }
        if let i = args.firstIndex(of: "--rpm"), i + 1 < args.count, let rpm = Double(args[i + 1]) {
            inputs.rpm = rpm
            inputs.mafVolts = 2.5
        }
        return inputs
    }
}
