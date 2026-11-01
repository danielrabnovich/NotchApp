import SwiftUI

/// Settings → Search → AI Commands: saved prompts for selected text, each replacing the selection
/// or showing its result. Used from "ai …" in the bar and from Ask About This with a selection.
struct AICommandsEditor: View {
    @ObservedObject private var store = AICommandStore.shared
    @State private var expanded: UUID?

    var body: some View {
        Section {
            ForEach($store.commands) { $command in
                VStack(alignment: .leading, spacing: 0) {
                    AICommandRow(command: command, expanded: expanded == command.id) {
                        withAnimation(.snappy(duration: 0.22)) { expanded = expanded == command.id ? nil : command.id }
                    }
                    if expanded == command.id {
                        AICommandEditor(command: $command) {
                            withAnimation(.snappy(duration: 0.22)) { store.remove(command.id) }
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .onMove { store.commands.move(fromOffsets: $0, toOffset: $1) }
            HStack {
                Button {
                    store.add()
                    withAnimation(.snappy(duration: 0.22)) { expanded = store.commands.last?.id }
                } label: { Label("Add Command", systemImage: "plus") }
                Spacer()
                Button("Restore Defaults") { store.resetToDefaults() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AI Commands")
        } footer: {
            FooterText("Select text anywhere, then type “ai” in the bar or press Ask About This (\(HotKeys.combo(for: .askScreen)?.display ?? "its shortcut")); the first four show as buttons. Replace commands put the result back where the text was (⌘Z undoes it). Drag to reorder.")
        }
    }
}

/// A command, folded: its icon, name, what it asks for, and what happens to the result. The whole
/// row opens it.
private struct AICommandRow: View {
    let command: AICommand
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: command.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(command.output == .replace ? Color.indigo.gradient : Color.teal.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.name)
                    Text(command.prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(command.output == .replace ? "Replaces" : "Shows")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .opacity(hovering && !expanded ? 0.85 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A command, open: its name and icon, where the result goes, and the instruction.
private struct AICommandEditor: View {
    @Binding var command: AICommand
    let delete: () -> Void

    /// Symbols that suit writing commands.
    private static let icons = ["sparkles", "checkmark.seal", "face.smiling", "briefcase", "text.alignleft", "lightbulb",
                                "character.bubble", "arrowshape.turn.up.left", "arrow.down.right.and.arrow.up.left",
                                "list.bullet", "quote.bubble", "envelope", "pencil", "wand.and.stars", "doc.text.magnifyingglass",
                                "number", "curlybraces", "megaphone", "heart", "graduationcap"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(Self.icons, id: \.self) { icon in
                        Button { command.icon = icon } label: { Label(icon, systemImage: icon) }
                    }
                } label: {
                    Image(systemName: command.icon)
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Icon")
                TextField("", text: $command.name, prompt: Text("Name"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("Result", selection: $command.output) {
                Text("Replace the selection").tag(AICommand.Output.replace)
                Text("Show in the notch").tag(AICommand.Output.show)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                Text("Instruction").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $command.prompt, prompt: Text("What to do with the selected text"), axis: .vertical)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
            }
            HStack {
                Spacer()
                Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
        }
    }
}
