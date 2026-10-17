#if os(macOS)
import Foundation
import Testing
@testable import XTermXKit
@testable import XTermXHost

@MainActor @Suite struct RoomCoordinatorTests {
    @Test func coordinatorOnlyGetsThePeersTheOwnerAssigned() async throws {
        let manager = PaneManager(detectAgents: false)
        manager.agents = [.init(id: "test-agent", name: "Test", command: "true", symbol: "sparkle", tint: 0xFFFFFF)]
        let head = manager.spawn(.init(kind: .agent, agentID: "test-agent", cwd: NSTemporaryDirectory()))
        let peer = manager.spawn(.init(kind: .agent, agentID: "test-agent", cwd: NSTemporaryDirectory()))
        let outside = manager.spawn(.init(kind: .agent, agentID: "test-agent", cwd: NSTemporaryDirectory()))
        let shell = manager.spawn(.init(kind: .shell, cwd: NSTemporaryDirectory()))
        defer { for pane in manager.panes { manager.close(pane.id) } }
        manager.setRoomCoordinator("room", coordinator: head.id, members: [head.id, peer.id, shell.id])
        #expect(manager.roomPeers(for: head.id).map(\.id) == [peer.id])
        #expect(manager.roomPeers(for: peer.id).isEmpty)
        let tools = AgentTools(manager: manager)
        let listed = await tools.call("room_members", arguments: [:], caller: head.id)
        guard case .success(let value) = listed else { Issue.record("Coordinator could not list its peers"); return }
        #expect(value["agents"]?.array?.count == 1)
        let handle = String(peer.id.prefix(8)).lowercased()
        var messages = 0
        manager.onPaneMessage = { _, _ in messages += 1 }
        let sent = await tools.call("room_send", arguments: ["pane": .string(handle), "text": "A task for this agent"], caller: head.id)
        guard case .success = sent else { Issue.record("Assigned peer was refused"); return }
        #expect(messages == 1)
        let report = await tools.call("room_reply", arguments: ["text": "Finished"], caller: peer.id)
        guard case .success = report else { Issue.record("Assigned peer could not report back"); return }
        let read = await tools.call("room_read", arguments: ["pane": .string(handle)], caller: head.id)
        guard case .success(let screen) = read else { Issue.record("Coordinator could not read assigned peer"); return }
        #expect(screen.string?.contains("<untrusted-data") == true)
        #expect(messages == 2)
        for (caller, target) in [(peer.id, head.id), (head.id, outside.id), (head.id, shell.id)] {
            let reply = await tools.call("room_send", arguments: ["pane": .string(String(target.prefix(8))), "text": "outside scope"], caller: caller)
            guard case .failure(let error) = reply else { Issue.record("Room boundary was bypassed"); continue }
            #expect(error.code == "ROOM_SCOPE")
        }
        manager.setRoomCoordinator("room", coordinator: nil, members: [])
        #expect(manager.roomPeers(for: head.id).isEmpty)
        #expect(messages == 2)
    }
}
#endif
