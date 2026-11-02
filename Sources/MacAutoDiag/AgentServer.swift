import Foundation
import Network
import Observation
import VazCore

/// Local MCP endpoint (Streamable HTTP, JSON responses): `http://127.0.0.1:<port>/mcp`.
/// Listens on loopback only and refuses foreign Host/Origin headers, so neither the network
/// nor a web page can reach it. Every call is shown in the diagnostics tab.
@MainActor @Observable
final class AgentServer {
    struct Event: Identifiable {
        let id = UUID()
        let time = Date()
        let tool: String
        let ok: Bool
    }

    static let defaultPort: UInt16 = 8723
    let port: UInt16
    private(set) var running = false
    private(set) var problem: String?
    private(set) var events: [Event] = []
    var url: String { "http://127.0.0.1:\(port)/mcp" }

    private var listener: NWListener?
    private var server: MCPServer?

    init(port: UInt16 = AgentServer.defaultPort) {
        self.port = port
    }

    func start(tools: AgentTools) {
        guard listener == nil else { return }
        server = MCPServer(name: "macautodiag", version: AppVersion.current, instructions: AgentTools.instructions,
                           tools: AgentTools.tools) { [weak self] name, arguments in
            let result = await tools.call(name, arguments)
            await self?.record(name, ok: !result.isError)
            return result
        }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.running = true; self?.problem = nil
                    case .failed(let error): self?.running = false; self?.problem = "Порт \(self?.port ?? 0) занят или недоступен: \(error)"
                    case .cancelled: self?.running = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            problem = "Не удалось открыть порт \(port): \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    private func record(_ tool: String, ok: Bool) {
        events.insert(Event(tool: tool, ok: ok), at: 0)
        if events.count > 50 { events.removeLast() }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                do {
                    if let request = try HTTPRequest.parse(buffer) {
                        Task { await self.respond(connection, to: request) }
                    } else if complete || error != nil {
                        connection.cancel()
                    } else {
                        self.receive(connection, buffer: buffer)
                    }
                } catch {
                    self.send(connection, HTTPRequest.response(status: 400, reason: "Bad Request"))
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, to request: HTTPRequest) async {
        guard request.isLocal(port: port) else {
            return send(connection, HTTPRequest.response(status: 403, reason: "Forbidden"))
        }
        guard request.path == "/mcp" || request.path.hasPrefix("/mcp?") else {
            return send(connection, HTTPRequest.response(status: 404, reason: "Not Found"))
        }
        // No server-initiated stream and no sessions: GET and DELETE are not offered.
        guard request.method == "POST", let server else {
            return send(connection, HTTPRequest.response(status: 405, reason: "Method Not Allowed", extraHeaders: ["Allow": "POST"]))
        }
        if let body = await server.handle(request.body) {
            send(connection, HTTPRequest.response(status: 200, reason: "OK", body: body))
        } else {
            send(connection, HTTPRequest.response(status: 202, reason: "Accepted"))
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
