#if os(macOS)
import Foundation
import Testing
@testable import XTermXKit
@testable import XTermXHost

@Suite struct PaneSharingPolicyTests {
    @Test func defaultsAndPrivateHistoryPersistAfterThePaneCloses() throws {
        var policy = PaneSharingPolicy()
        #expect(policy.access("new") == .control)
        policy.set("p", to: .none)
        var pane = PaneInfo(id: "p", title: "Private", kind: .agent, cwd: "/tmp")
        pane.agentSession = AgentSessionInfo(tool: .claude, sessionID: "private-session", account: "test")
        policy.remember(pane)
        let history = AgentSessionRecord(id: "private-session", tool: .claude, account: "test", startedAt: .now)
        let publicHistory = AgentSessionRecord(id: "public-session", tool: .codex, account: "test", startedAt: .now)
        let overview = AgentOverview(elsewhere: [pane.agentSession!], history: [history, publicHistory])
        #expect(policy.visibleOverview(overview).history.map(\.id) == ["public-session"])
        #expect(policy.visibleOverview(overview).elsewhere.isEmpty)
        let restored = try JSONDecoder().decode(PaneSharingPolicy.self, from: JSONEncoder().encode(policy))
        #expect(restored == policy)
        #expect(restored.visibleOverview(overview).history.map(\.id) == ["public-session"])
        policy.set("p", to: .view)
        #expect(policy.access("p").canView && !policy.access("p").canControl)
        #expect(policy.visibleApprovals([ApprovalRequest(paneID: "p", title: "Approve", detail: "hidden")]).isEmpty)
    }
}

@MainActor @Suite(.serialized) struct PaneSharingIntegrationTests {
    func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(7)
        while Date.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return predicate()
    }
    @Test func privatePanesDisappearAndReadOnlyIsEnforcedOnBothTransports() async throws {
        let manager = PaneManager(detectAgents: false)
        let server = RemoteServer(manager: manager, port: 0, httpPort: 0, secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        server.start()
        defer { server.stop(); for pane in manager.panes { manager.close(pane.id) } }
        let privatePane = manager.spawn(.init(kind: .shell, cwd: NSTemporaryDirectory(), title: "Private"))
        let view = manager.spawn(.init(kind: .shell, cwd: NSTemporaryDirectory(), title: "Watch"))
        let control = manager.spawn(.init(kind: .shell, cwd: NSTemporaryDirectory(), title: "Control"))
        manager.setHomeSize(view.id, cols: view.cols, rows: view.rows)
        server.setPaneAccess(privatePane.id, to: .none)
        server.setPaneAccess(view.id, to: .view)
        let pairing = server.pairing(address: "127.0.0.1")
        let client = HostConnection(pairing: pairing, deviceName: "test", platform: .iOS)
        client.connect()
        defer { client.disconnect() }
        #expect(await client.waitUntilReady())
        #expect(Set(client.panes.map(\.id)) == [view.id, control.id])
        #expect(client.canView(view.id) && !client.canControl(view.id))
        #expect(client.canControl(control.id))
        #expect(!client.canView(privatePane.id))
        let token = client.attach(paneID: view.id) { _ in }
        #expect(await wait { server.watchedPaneIDs().contains(view.id) })
        client.send(.input(paneID: view.id, data: Data("echo SHOULD_NOT_RUN\r".utf8)))
        #expect(await wait { client.lastError?.contains("PANE_ACCESS") == true })

        func rpc(_ message: ClientMessage) async throws -> [HostMessage] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(pairing.httpPort)/rpc")!)
            request.httpMethod = "POST"
            request.httpBody = try RPCSealing.seal(RPCRequest(message: message), secret: pairing.secret, .clientToHost)
            let (data, _) = try await URLSession.shared.data(for: request)
            return try RPCSealing.open(RPCResponse.self, from: data, secret: pairing.secret, .hostToClient).messages
        }
        for message in [ClientMessage.subscribe(paneID: privatePane.id), .screen(paneID: privatePane.id, lines: 2),
                        .input(paneID: privatePane.id, data: Data("x".utf8)), .resize(paneID: view.id, cols: 50, rows: 20),
                        .send(paneID: view.id, text: "echo SHOULD_NOT_RUN"), .close(paneID: view.id)] {
            let replies = try await rpc(message)
            #expect(replies.contains { if case .error(let code, _) = $0 { code == "PANE_ACCESS" } else { false } })
        }
        #expect(manager.panes.count == 3)
        #expect(manager.session(view.id)?.info.cols == view.cols)
        let screens = try await rpc(.screen(paneID: view.id, lines: 2))
        #expect(screens.contains { if case .screen(let id, _) = $0 { id == view.id } else { false } })

        // Revocation removes an existing subscriber and pushes a filtered snapshot immediately.
        server.setPaneAccess(view.id, to: .none)
        #expect(await wait { !client.panes.contains { $0.id == view.id } })
        #expect(!server.watchedPaneIDs().contains(view.id))
        client.detach(paneID: view.id, token: token)
        server.setPaneAccess(view.id, to: .control)
        #expect(await wait { client.canControl(view.id) })
        client.resize(paneID: view.id, cols: 80, rows: 24)
        #expect(await wait { manager.session(view.id)?.info.cols == 80 })
        server.setPaneAccess(view.id, to: .view)
        #expect(await wait { !client.canControl(view.id) })
        #expect(manager.session(view.id)?.info.cols == view.cols)
    }

    @Test func viewOnlyCannotAnswerAnAgentOrSendThroughARoom() async throws {
        let manager = PaneManager(detectAgents: false)
        let server = RemoteServer(manager: manager, port: 0, httpPort: 0, secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        let pane = manager.spawn(.init(kind: .shell, cwd: NSTemporaryDirectory()))
        server.setPaneAccess(pane.id, to: .view)
        server.permissions.manageRooms = true
        server.roomList = { [RemoteRoom(id: "room", name: "Test", paneIDs: [pane.id])] }
        var roomChanged = false
        server.roomAction = { _ in roomChanged = true }
        server.start()
        defer { server.stop(); manager.close(pane.id) }
        let pairing = server.pairing(address: "127.0.0.1")
        let client = HostConnection(pairing: pairing, deviceName: "test", platform: .iOS)
        client.connect()
        defer { client.disconnect() }
        #expect(await client.waitUntilReady())
        let request = ApprovalRequest(paneID: pane.id, title: "Approve", detail: "Private agent detail")
        let pending = Task { await manager.requestDecision(request) }
        #expect(await wait { !manager.approvals.isEmpty })
        client.refresh()
        client.send(.answer(requestID: request.id, allow: true))
        #expect(await wait { client.lastError?.contains("PANE_ACCESS") == true })
        #expect(client.approvals.isEmpty)
        #expect(manager.approvals.count == 1)
        client.updateRoom(.message(id: "room", text: "echo SHOULD_NOT_RUN", paneIDs: [pane.id], execute: true))
        #expect(await wait { client.lastError?.contains("ROOM_INVALID") == true })
        #expect(!roomChanged)
        manager.answer(request.id, allow: false)
        #expect(await pending.value?.optionID == "deny")
    }
}
#endif
