import SwiftUI
import XTermXKit

/// Settings › Agents: which agents are installed, and the tools panes get from XTermX.
struct AgentsSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsPage(section: .agents) {
            SettingsCard("Installed agents", "Coding agents XTermX found on this Mac.") {
                ForEach(model.manager.agents) { agent in
                    HStack {
                        AgentIcon(agent, size: 18)
                        Text(agent.name)
                        Spacer()
                        Text(agent.installed ? agent.command : "Not installed")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                    }
                }
                Button("Check again") { Task { await model.manager.refreshAgents() } }
            }

            WorktreeSettings()
            SettingsCard("Gemini sessions", "Gemini CLI can join a room and coordinate peers through the pane tools.") {
                Text("With agent hooks enabled, Gemini reports session start/end, working, idle and tool-permission waits. Its permission prompts stay in its terminal.").font(.caption)
                Text("Gemini token totals, plan limits and chat transcripts are not read yet.").font(.caption)
            }
            SettingsCard("Agents opening panes",
                         "Agents in panes can open other agents beside them; you approve each one on the Mac, iPhone or Watch, and no answer in 120 s means no.") {
                Toggle("Let agents open panes", isOn: Binding(get: { model.agentPanesAllowed }, set: { model.agentPanesAllowed = $0 }))
                    .toggleStyle(.switch)
            }

            SettingsCard("Tool server",
                         "Claude Code and Codex panes connect on their own; other agents use XTERMX_MCP_URL with the bearer token in XTERMX_SESSION.") {
                Text(model.tools.url?.absoluteString ?? "starting…")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}
