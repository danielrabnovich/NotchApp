import AppKit
import SwiftUI

/// Scratchpad pane inside the Tasks tab.
struct NotesView: View {
    @ObservedObject var viewModel: NotchViewModel
    @Binding var pane: TasksPane
    @EnvironmentObject private var store: ScratchpadStore
    @FocusState private var focused: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PaneSwitcher(selection: $pane, options: TasksPane.options)
                Text(wordCount)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(NotchIconButtonStyle(size: 24))
                .help("Copy all")
                .disabled(store.text.isEmpty)
                Button { store.text = "" } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(NotchIconButtonStyle(size: 24))
                .help("Clear")
                .disabled(store.text.isEmpty)
            }
            .notchHeaderRow()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.text)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focused)
                    // A text view treats Escape as "complete word"; here it means "done editing".
                    .onKeyPress(.escape) { focused = false; return .handled }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                if store.text.isEmpty {
                    Text("Jot something down…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .notchSurface(RoundedRectangle(cornerRadius: 14, style: .continuous), active: focused)
            .animation(.easeOut(duration: 0.15), value: focused)
            .onChange(of: focused) { _, f in viewModel.isEditing = f }
        }
    }

    private var wordCount: String {
        let words = store.text.split { $0.isWhitespace || $0.isNewline }.count
        return words == 1 ? "1 word" : "\(words) words"
    }
}

enum TasksPane: String {
    case tasks, notes, prompter
    @MainActor static var options: [(value: TasksPane, title: String)] {
        [(.tasks, "Tasks")] + (AppSettings.shared.notesEnabled ? [(.notes, "Notes")] : []) + [(.prompter, "Prompter")]
    }
}
