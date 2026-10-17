#if os(macOS) || os(Linux)
import Foundation
import Observation
import XTermXKit
import XTermXNIO

/// One tool call, for the activity list in the Mac UI.
public struct ToolCallRecord: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let at = Date()
    public var paneID: String
    public var tool: String
    public var ok: Bool
    public var detail: String
}

/// The agent tool server: MCP over Streamable HTTP (JSON responses, no SSE) on 127.0.0.1.
///
/// Every request carries `Authorization: Bearer <pane token>`; the token tells which pane is
/// calling. Requests from browsers (an `Origin` header) or for another host name are refused,
/// so a web page cannot reach the server through DNS rebinding.
@MainActor
@Observable
public final class MCPServer {
    public private(set) var url: URL?
    public private(set) var recentCalls: [ToolCallRecord] = []
    public let tools: AgentTools
    /// Claude Code / Codex sessions in panes, fed by their hooks (POST /hook).
    @ObservationIgnored public let sessions: AgentSessionTracker
    @ObservationIgnored public let hooks: AgentHooks

    @ObservationIgnored private let manager: PaneManager
    @ObservationIgnored private var http: RawHTTPServer?

    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// `agentHistory`: where agent time and sessions in panes are kept (nil: memory only).
    /// `watchMachine`: also follow agent sessions running outside the panes.
    public init(manager: PaneManager, agentHistory: URL? = nil, watchMachine: Bool = false) {
        self.manager = manager
        self.tools = AgentTools(manager: manager)
        self.sessions = AgentSessionTracker(manager: manager, historyURL: agentHistory, watchMachine: watchMachine)
        self.hooks = AgentHooks(manager: manager, sessions: sessions)
    }

    /// Starts listening on a free loopback port and tells the pane manager the endpoint.
    @discardableResult
    public func start() async throws -> URL {
        if let url { return url }
        let server = RawHTTPServer { [weak self] request in
            await self?.respond(to: request) ?? Data()
        }
        let port = try server.start(host: "127.0.0.1", port: 0)
        http = server
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        self.url = url
        manager.toolServerURL = url
        sessions.start()
        return url
    }

    public func stop() {
        sessions.stop()
        http?.stop()
        http = nil
        url = nil
        manager.toolServerURL = nil
    }

    private func respond(to request: HTTPRequest) async -> Data {
        let hostName = (request.headers["host"] ?? "").split(separator: ":").first.map(String.init) ?? ""
        guard ["127.0.0.1", "localhost"].contains(hostName) else { return Self.http(403, text: "Wrong host.") }
        if let origin = request.headers["origin"], origin != "null" { return Self.http(403, text: "Browsers may not call this server.") }
        if request.path == "/hook" { return await hook(request) }
        guard request.path == "/mcp" else { return Self.http(404, text: "Not found.") }

        switch request.method {
        case "GET":
            // No server-initiated stream: every answer comes back on the POST.
            return Self.http(405, text: "Use POST.", extra: ["Allow": "POST, DELETE"])
        case "DELETE":
            return Self.http(200, text: "")
        case "POST":
            break
        default:
            return Self.http(405, text: "Use POST.", extra: ["Allow": "POST, DELETE"])
        }

        let auth = request.headers["authorization"] ?? ""
        guard auth.lowercased().hasPrefix("bearer "),
              let caller = manager.paneID(forToken: String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)) else {
            return Self.http(401, json: Self.error(id: .null, code: -32001,
                message: "XTermX's tool server is not reachable from this pane: no valid XTERMX_SESSION token."))
        }
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: request.body) else {
            return Self.http(400, json: Self.error(id: .null, code: -32700, message: "Parse error"))
        }

        var sessionHeader: [String: String] = [:]
        if case .array(let batch) = body {
            var replies: [JSONValue] = []
            for message in batch {
                if let r = await handle(message, caller: caller, sessionHeader: &sessionHeader) { replies.append(r) }
            }
            return replies.isEmpty ? Self.http(202, text: "") : Self.http(200, json: .array(replies), extra: sessionHeader)
        }
        guard let reply = await handle(body, caller: caller, sessionHeader: &sessionHeader) else { return Self.http(202, text: "") }
        return Self.http(200, json: reply, extra: sessionHeader)
    }

    /// A Claude Code / Codex hook from a pane (`xtermx hook`): same token rule as the tools.
    /// 200 with the JSON the hook prints, or an empty 200 for "no decision".
    private func hook(_ request: HTTPRequest) async -> Data {
        guard request.method == "POST" else { return Self.http(405, text: "Use POST.", extra: ["Allow": "POST"]) }
        let auth = request.headers["authorization"] ?? ""
        guard auth.lowercased().hasPrefix("bearer "),
              let caller = manager.paneID(forToken: String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)) else {
            return Self.http(401, text: "No valid XTERMX_SESSION token.")
        }
        guard let payload = try? JSONDecoder().decode(JSONValue.self, from: request.body) else { return Self.http(400, text: "Bad JSON.") }
        guard let reply = await hooks.handle(event: request.headers["x-xtermx-hook"], payload: payload, caller: caller) else {
            return Self.http(200, text: "")
        }
        return Self.http(200, json: reply)
    }

    // MARK: JSON-RPC

    /// Answers one JSON-RPC message; nil for notifications and responses.
    private func handle(_ message: JSONValue, caller: String, sessionHeader: inout [String: String]) async -> JSONValue? {
        guard let method = message["method"]?.string else { return nil }
        guard let id = message["id"], id != .null else { return nil } // notification
        let params = message["params"] ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? Self.supportedVersions[1]
            let version = Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[1]
            sessionHeader["Mcp-Session-Id"] = SecureRandom.bytes(16).base64URLEncoded
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "xtermx", "title": "XTermX", "version": "1.0.0"],
                "instructions": .string(AgentTools.instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(tools.definitions())])
        case "tools/call":
            guard let name = params["name"]?.string else { return Self.error(id: id, code: -32602, message: "Missing tool name") }
            let outcome = await tools.call(name, arguments: params["arguments"] ?? [:], caller: caller)
            switch outcome {
            case .success(let value):
                log(caller, name, ok: true, detail: "")
                let text = value.string ?? value.prettyText
                return Self.result(id: id, ["content": [["type": "text", "text": .string(text)]], "isError": false])
            case .failure(let f):
                log(caller, name, ok: false, detail: f.code)
                return Self.result(id: id, ["content": [["type": "text", "text": .string("\(f.code): \(f.message)")]], "isError": true])
            }
        case "resources/list":
            return Self.result(id: id, ["resources": []])
        case "prompts/list":
            return Self.result(id: id, ["prompts": []])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func log(_ pane: String, _ tool: String, ok: Bool, detail: String) {
        recentCalls.insert(ToolCallRecord(paneID: pane, tool: tool, ok: ok, detail: detail), at: 0)
        if recentCalls.count > 50 { recentCalls.removeLast(recentCalls.count - 50) }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    static func http(_ status: Int, json: JSONValue, extra: [String: String] = [:]) -> Data {
        let body = (try? WireJSON.encoder.encode(json)) ?? Data()
        return http(status, body: body, type: "application/json", extra: extra)
    }

    static func http(_ status: Int, text: String, extra: [String: String] = [:]) -> Data {
        http(status, body: Data(text.utf8), type: "text/plain; charset=utf-8", extra: extra)
    }

    static func http(_ status: Int, body: Data, type: String, extra: [String: String]) -> Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}
#endif
