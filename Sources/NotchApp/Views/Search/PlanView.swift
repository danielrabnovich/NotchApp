import SwiftUI

/// AI-proposed actions to review: untick any you don't want, then run the rest.
struct PlanView: View {
    let plan: CommandPlanner.Plan
    @Binding var excluded: Set<UUID>
    let apply: (CommandPlanner.Plan) -> Void
    /// Cancel; by default it clears the Search tab's result.
    var cancel: (() -> Void)?
    @EnvironmentObject private var assistant: AssistantStore

    private var included: [Command] { plan.commands.filter { !excluded.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(plan.summary)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            // Hugs a short plan; scrolls a long one.
            ViewThatFits(in: .vertical) {
                rows
                ScrollView(.vertical, showsIndicators: false) { rows }
            }
            .notchSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text("Untick anything you don't want")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.32))
                Spacer()
                Button("Cancel") { if let cancel { cancel() } else { assistant.clear() } }
                    .buttonStyle(NotchPillButtonStyle())
                Button { apply(plan) } label: {
                    HStack(spacing: 6) {
                        Text(applyTitle)
                        Text("↩").opacity(0.45)
                    }
                }
                .buttonStyle(NotchPillButtonStyle(primary: true))
                .disabled(included.isEmpty)
                .opacity(included.isEmpty ? 0.4 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(plan.commands) { command in row(command) }
        }
        .padding(4)
    }

    private var applyTitle: String {
        let tasks = included.reduce(0) { n, c in if case .addTasks(let items) = c.action { n + items.count } else { n } }
        if tasks == included.count { return tasks == 1 ? "Add task" : "Add \(tasks) tasks" }
        return included.count == 1 ? "Do it" : "Do all \(included.count)"
    }

    private func row(_ command: Command) -> some View {
        let on = !excluded.contains(command.id)
        let (title, detail) = display(command)
        return Button {
            if on { excluded.insert(command.id) } else { excluded.remove(command.id) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(on ? Color.accentColor : .white.opacity(0.3))
                    .contentTransition(.symbolEffect(.replace))
                Image(systemName: command.icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(on ? 0.92 : 0.4))
                    .strikethrough(!on, color: .white.opacity(0.3))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Tasks read as the task itself ("Call mom", "tomorrow 3 PM"), not "Add task “Call mom”".
    private func display(_ command: Command) -> (String, String?) {
        if case .addTasks(let items) = command.action, items.count == 1 {
            let (title, due) = DueDateParser.extract(from: items[0])
            return (title, due.map(CommandParser.dueText))
        }
        if case .appendNote(let text) = command.action { return (text, "note") }
        return (command.title, command.subtitle)
    }
}

/// What the last command did, with a way to go and see it.
struct ConfirmationLine: View {
    let confirmation: CommandCenter.Confirmation

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: confirmation.icon)
                .foregroundStyle(confirmation.failed ? .orange : .green)
            Text(confirmation.text)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            if let undo = confirmation.undo {
                Text("·").foregroundStyle(.white.opacity(0.3))
                Button("Undo") { CommandCenter.shared.undo(undo) }
                    .buttonStyle(NotchLinkButtonStyle())
            }
            if let destination = confirmation.destination, case .show(let tab, let pane) = destination {
                Text("·").foregroundStyle(.white.opacity(0.3))
                Button("Show") { CommandCenter.shared.show(tab, pane: pane) }
                    .buttonStyle(NotchLinkButtonStyle())
            } else if let destination = confirmation.destination, case .settingsPane(let pane) = destination {
                Text("·").foregroundStyle(.white.opacity(0.3))
                Button("Settings") { CommandCenter.shared.run([Command(action: .settingsPane(pane), title: pane.title, icon: pane.icon)]) }
                    .buttonStyle(NotchLinkButtonStyle())
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .frame(height: 18)
    }
}
