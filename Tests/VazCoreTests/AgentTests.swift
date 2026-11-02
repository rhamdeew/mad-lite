import Foundation
import Testing
@testable import VazCore

@Suite struct MCPServerTests {
    let server = MCPServer(name: "test", version: "1", instructions: "hi",
                           tools: [MCPTool(name: "echo", description: "returns its arguments",
                                           properties: ["x": ["type": "number"]], required: ["x"])]) { name, args in
        args["x"]?.doubleValue == 0 ? .failure("zero") : .ok(.object(args))
    }

    func send(_ message: JSONValue) async throws -> JSONValue? {
        guard let data = await server.handle(message.encoded()) else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test func initializeNegotiatesTheVersion() async throws {
        let r = try #require(try await send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                             "params": ["protocolVersion": "2025-03-26"]]))
        #expect(r["id"] == 1)
        #expect(r["result"]?["protocolVersion"] == "2025-03-26")
        #expect(r["result"]?["capabilities"]?["tools"] != nil)
        let unknown = try #require(try await send(["jsonrpc": "2.0", "id": 2, "method": "initialize",
                                                   "params": ["protocolVersion": "1999-01-01"]]))
        #expect(unknown["result"]?["protocolVersion"] == .string(MCPServer.protocolVersions[0]))
    }

    @Test func notificationsGetNoAnswer() async throws {
        #expect(try await send(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    }

    @Test func toolsListAndCall() async throws {
        let list = try #require(try await send(["jsonrpc": "2.0", "id": "a", "method": "tools/list"]))
        #expect(list["result"]?["tools"] == [["name": "echo", "description": "returns its arguments",
                                              "inputSchema": ["type": "object", "properties": ["x": ["type": "number"]], "required": ["x"]]]])
        let call = try #require(try await send(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                                "params": ["name": "echo", "arguments": ["x": 5]]]))
        #expect(call["result"]?["isError"] == false)
        #expect(call["result"]?["structuredContent"] == ["x": 5])
        #expect(call["result"]?["content"] == [["type": "text", "text": "{\"x\":5}"]])
        let failed = try #require(try await send(["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                                  "params": ["name": "echo", "arguments": ["x": 0]]]))
        #expect(failed["result"]?["isError"] == true)
    }

    @Test func errors() async throws {
        let unknownTool = try #require(try await send(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "nope"]]))
        #expect(unknownTool["error"]?["code"] == -32602)
        let unknownMethod = try #require(try await send(["jsonrpc": "2.0", "id": 6, "method": "resources/list"]))
        #expect(unknownMethod["error"]?["code"] == -32601)
        let garbage = try JSONDecoder().decode(JSONValue.self, from: try #require(await server.handle(Data("{oops".utf8))))
        #expect(garbage["error"]?["code"] == -32700)
    }
}

@Suite struct ParkedCheckTests {
    /// One frame of an engine at rest with the given extended values (by channel id).
    func stats(_ values: [String: Double], rpm: Double = 0, faults: [String] = []) -> SampleStats {
        let channels = LogSchema.channels(extended: true)
        var s = SampleStats(channels: channels)
        var row = channels.map { _ in Double.nan }
        let defaults: [String: Double] = ["rpm": rpm, "voltage": 12.4, "coolant": 20, "air_temp": 18, "throttle": 0, "tps_v": 0.55]
        for (id, v) in defaults.merging(values, uniquingKeysWith: { $1 }) {
            row[channels.firstIndex { $0.id == id }!] = v
        }
        for _ in 0..<3 { s.add(row, activeFaults: faults) }
        return s
    }

    func verdict(_ findings: [CheckFinding], _ check: String) -> CheckFinding.Verdict? {
        findings.first { $0.check == check }?.verdict
    }

    @Test func healthyCarPasses() {
        let f = ParkedCheck.run(stats(["map_kpa": 99, "map_v": 1.61]), map: .range20to300kPa)
        #expect(f.allSatisfy { $0.verdict == .ok }, "\(f)")
    }

    /// The owner's case if the firmware still holds the old sensor: 1.61 V read with GAZ numbers.
    @Test func wrongMAPCharacteristicIsCaught() {
        let wrong = MAPCharacteristic.gaz453829.pressure(volts: 1.61) // ≈ 40 kPa
        let f = ParkedCheck.run(stats(["map_kpa": wrong, "map_v": 1.61]), map: .range20to300kPa)
        #expect(verdict(f, "ДАД — давление (атмосфера)") == .deviation)
        #expect(verdict(f, "ДАД — характеристика в прошивке") == .deviation)
    }

    @Test func sensorFaults() {
        let f = ParkedCheck.run(stats(["coolant": -40, "tps_v": 0.1, "voltage": 11.2], faults: ["ДТОЖ: низкий уровень"]))
        #expect(verdict(f, "ДТОЖ") == .deviation)
        #expect(verdict(f, "ДПДЗ, педаль отпущена") == .deviation)
        #expect(verdict(f, "Бортсеть") == .deviation)
        #expect(verdict(f, "Текущие неисправности") == .deviation)
    }

    @Test func runningEngineIsRefused() {
        let f = ParkedCheck.run(stats([:], rpm: 850))
        #expect(f.count == 1 && f[0].verdict == .deviation)
    }

    @Test func statsSkipMissingValues() {
        var s = SampleStats(channels: Array(LogSchema.base.prefix(2)))
        s.add([800, .nan])
        s.add([900, 90])
        #expect(s.mean("rpm") == 850)
        #expect(s.mean("coolant") == 90)
        #expect(s.json()["channels"]?["rpm"]?["max"] == 900)
        #expect(s.json()["frames"] == 2)
    }

    @Test func range20to300kPaCharacteristic() {
        #expect(abs(MAPCharacteristic.range20to300kPa.pressure(volts: 0.4) - 20) < 0.5)
        #expect(abs(MAPCharacteristic.range20to300kPa.pressure(volts: 4.65) - 300) < 1)
    }
}

@Suite struct HTTPRequestTests {
    @Test func parsesInPieces() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let raw = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8723\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        #expect(try HTTPRequest.parse(raw.prefix(20)) == nil)
        #expect(try HTTPRequest.parse(raw.dropLast(3)) == nil)
        let r = try #require(try HTTPRequest.parse(raw))
        #expect(r.method == "POST" && r.path == "/mcp" && r.body == Data(body.utf8))
        #expect(r.isLocal(port: 8723))
    }

    @Test func rejectsForeignHostsAndOrigins() throws {
        func req(_ headers: String) throws -> HTTPRequest {
            try #require(try HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\n\(headers)\r\nContent-Length: 0\r\n\r\n".utf8)))
        }
        #expect(try !req("Host: evil.example:8723").isLocal(port: 8723))
        #expect(try !req("Host: 127.0.0.1:8723\r\nOrigin: https://evil.example").isLocal(port: 8723))
        #expect(try req("Host: localhost:8723\r\nOrigin: http://localhost:8723").isLocal(port: 8723))
        #expect(throws: HTTPRequest.ParseError.self) { try HTTPRequest.parse(Data("garbage\r\n\r\n".utf8)) }
    }
}
