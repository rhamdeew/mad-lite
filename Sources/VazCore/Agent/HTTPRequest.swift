import Foundation

/// Just enough HTTP/1.1 for the local MCP endpoint: one request per connection, body by Content-Length.
public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    /// Header names lowercased.
    public let headers: [String: String]
    public let body: Data

    /// nil while the request is incomplete (keep reading); throws on garbage.
    public static func parse(_ data: Data) throws -> HTTPRequest? {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw ParseError.headerTooLong }
            return nil
        }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { throw ParseError.badRequestLine }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.badHeader }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...maxBody).contains(length) else { throw ParseError.badLength }
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length)))
    }

    public static let maxBody = 1 << 20

    public enum ParseError: Error { case headerTooLong, badRequestLine, badHeader, badLength }

    /// DNS rebinding and browser pages: only loopback hosts and no foreign Origin.
    public func isLocal(port: UInt16) -> Bool {
        let allowed = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = headers["host"], allowed.contains(host.lowercased()) else { return false }
        if let origin = headers["origin"]?.lowercased() {
            return allowed.contains { origin == "http://" + $0 }
        }
        return true
    }

    public static func response(status: Int, reason: String, body: Data = Data(), contentType: String = "application/json",
                                extraHeaders: [String: String] = [:]) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in extraHeaders.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}
