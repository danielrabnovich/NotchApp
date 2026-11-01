import AppKit
import SwiftUI

struct AgentsSettingsPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var agents = AgentMonitor.shared
    @ObservedObject private var hooks = AgentHooks.shared
    @State private var hookError: String?
    @State private var link = CommandBridge.installedLink
    @State private var linkError: String?
    @State private var copiedMCP = false

    var body: some View {
        SettingsPage(pane: .agents) {
            Section {
                if s.agentsEnabled {
                    ToggleRow("Alerts", subtitle: "A heads-up when an agent finishes, or stops to ask you something.", isOn: $s.agentAlerts)
                    ToggleRow("Keep the Mac awake while agents work", subtitle: "Turns on Keep Awake while any session is working, and off two minutes after the last one stops.",
                              isOn: $s.agentsKeepAwake)
                    ToggleRow("Live activity from Claude Code",
                              subtitle: hookError ?? "Adds read-only hooks to Claude Code's settings, so the notch shows what each session is doing right now and how many subagents it has out, and says what it changed when it's done. They never answer anything for you.",
                              isOn: Binding(get: { hooks.installed }, set: { on in
                                  do { try hooks.setInstalled(on); hookError = nil } catch { hookError = error.localizedDescription }
                              }))
                }
            } footer: {
                FooterText("Pin “Agents” in Glances to keep a working count beside the notch. Click a session to jump to its terminal.")
            }
            .onAppear { hooks.refreshInstalled() }
            Section {
                LabeledContent {
                    Button(link == nil ? "Install" : "Installed") {
                        do { link = try CommandBridge.installLink(); linkError = nil } catch { linkError = error.localizedDescription }
                    }
                    .disabled(link != nil)
                } label: {
                    RowLabel(title: "The notch command",
                             subtitle: linkError ?? "notch run make shows a ring beside the notch while it runs and a Banner when it ends (click it to go back to the terminal). notch banner, progress, shelf and ask work from any script. \(link.map { "Linked at \($0.path)." } ?? "Adds a link to it on your PATH.")")
                }
                LabeledContent {
                    Button(copiedMCP ? "Copied" : "Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CommandBridge.mcpSetupCommand, forType: .string)
                        ClipboardHistory.shared.ignoreCurrent()
                        copiedMCP = true
                    }
                } label: {
                    RowLabel(title: "MCP server for agents",
                             subtitle: "Lets coding agents show progress and Banners in the notch, put files they made on the Shelf, and ask you quick choices (never permissions). Paste the copied command in a terminal to add it to Claude Code; other agents run “notch mcp”.")
                }
            } header: {
                Text("Command line")
            }
            Section {
                // One form row holding all four: as separate rows, the form drew the last one
                // (with its menu) outside the section's card.
                VStack(spacing: 0) {
                    ForEach(Array(AgentMonitor.Tool.allCases.enumerated()), id: \.element) { i, tool in
                        if i > 0 { Divider().padding(.vertical, 8) }
                        AgentPlanRow(tool: tool, installed: agents.installed.contains(tool), note: planNote(tool))
                    }
                }
                .padding(.vertical, 2)
            } header: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plans")
                    // Here rather than in a footer: a long footer pulls the last picker row out of the card.
                    Text("Read from each agent's own settings where they record one (Claude Code, Codex). ZCode only says a coding plan is connected, so pick your tier. Usage compares the API value of what you used with what the plan costs.")
                        .font(.caption).fontWeight(.regular).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                LabeledContent {
                    Button("Clear History") { AgentUsageStore.shared.clearHistory() }
                } label: {
                    RowLabel(title: "Usage history",
                             subtitle: "Kept on this Mac by the hour, so it outlives the agents' own logs. API values use published per-token prices as of \(AgentPricing.updated); local models aren't priced.")
                }
            } header: {
                Text("History")
            }
            Section {
                ForEach(AgentMonitor.Tool.allCases) { tool in
                    HStack(spacing: 10) {
                        AgentGlyph(tool: tool, size: 22)
                        RowLabel(title: tool.name, subtitle: source(tool))
                        Spacer()
                        Text(agents.installed.contains(tool) ? "Found" : "Not found")
                            .font(.caption).foregroundStyle(agents.installed.contains(tool) ? Color.green : Color.secondary)
                    }
                }
            } header: {
                Text("Sources")
            } footer: {
                FooterText("Read-only, from files these tools already keep on your Mac. Nothing is sent anywhere.")
            }
        }
        .onAppear { agents.refreshSessions() }
    }

    private func planNote(_ tool: AgentMonitor.Tool) -> String {
        guard let plan = AgentUsageStore.shared.plan(for: tool) else { return "No plan recorded: pick one to compare value" }
        let price = plan.monthly.map { " · $\(Int($0))/mo" } ?? ""
        return plan.name + price + (plan.detected ? " · detected" : "")
    }

    private func source(_ tool: AgentMonitor.Tool) -> String {
        switch tool {
        case .claude: "~/.claude: live session status and transcript usage"
        case .codex: "~/.codex/sessions: rollouts and token counts"
        case .opencode: "~/.local/share/opencode/opencode.db"
        case .zcode: "~/.zcode/cli/db: turns and per-model usage"
        }
    }
}

private struct AgentPlanRow: View {
    let tool: AgentMonitor.Tool
    let installed: Bool
    let note: String
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            AgentGlyph(tool: tool, size: 22)
            RowLabel(title: tool.name, subtitle: installed ? note : "Not found on this Mac")
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { s.agentPlans[tool.rawValue] ?? "" },
                set: { s.agentPlans[tool.rawValue] = $0.isEmpty ? nil : $0 })) {
                Text("Automatic").tag("")
                Divider()
                ForEach(AgentPlan.choices(for: tool)) { plan in
                    Text(plan.monthly.map { "\(plan.name) · $\(Int($0))/mo" } ?? plan.name).tag(plan.id)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}
