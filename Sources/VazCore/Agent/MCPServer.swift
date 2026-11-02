import Foundation

/// A tool the agent may call: name, what it does, JSON Schema of its arguments.
public struct MCPTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, properties: [String: JSONValue] = [:], required: [String] = []) {
        self.name = name
        self.description = description
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        inputSchema = .object(schema)
    }
}

public struct MCPToolResult: Sendable {
    public var content: JSONValue
    public var isError: Bool

    public static func ok(_ content: JSONValue) -> Self { .init(content: content, isError: false) }
    /// A failure the agent should read and act on (no link, engine running…), not a protocol error.
    public static func failure(_ message: String) -> Self { .init(content: ["error": .string(message)], isError: true) }
}

/// Model Context Protocol over JSON-RPC 2.0: `initialize`, `ping`, `tools/list`, `tools/call`.
/// Transport-agnostic: the app feeds it HTTP request bodies (Streamable HTTP, JSON responses only).
public struct MCPServer: Sendable {
    public static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let name: String
    public let version: String
    public let instructions: String
    public let tools: [MCPTool]
    let call: @Sendable (String, [String: JSONValue]) async -> MCPToolResult

    public init(name: String, version: String, instructions: String, tools: [MCPTool],
                call: @escaping @Sendable (String, [String: JSONValue]) async -> MCPToolResult) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
        self.call = call
    }

    /// One JSON-RPC message in, the response out; nil for a notification (HTTP 202, no body).
    public func handle(_ body: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: body), case .object(let m) = message else {
            return Self.error(id: .null, code: -32700, message: "Parse error").encoded()
        }
        guard let method = m["method"]?.stringValue else {
            return Self.error(id: m["id"] ?? .null, code: -32600, message: "Invalid Request").encoded()
        }
        guard let id = m["id"] else { return nil } // notifications/initialized and the like
        let params = m["params"] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "version": .string(self.version)],
                "instructions": .string(instructions),
            ]).encoded()
        case "ping":
            return Self.result(id: id, [:]).encoded()
        case "tools/list":
            let list: [JSONValue] = tools.map {
                ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema]
            }
            return Self.result(id: id, ["tools": .array(list)]).encoded()
        case "tools/call":
            guard let tool = params["name"]?.stringValue, tools.contains(where: { $0.name == tool }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool").encoded()
            }
            var arguments: [String: JSONValue] = [:]
            if case .object(let a) = params["arguments"] ?? [:] { arguments = a }
            let r = await call(tool, arguments)
            var result: [String: JSONValue] = [
                "content": [["type": "text", "text": .string(r.content.text)]],
                "isError": .bool(r.isError),
            ]
            if case .object = r.content { result["structuredContent"] = r.content }
            return Self.result(id: id, .object(result)).encoded()
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)").encoded()
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}
