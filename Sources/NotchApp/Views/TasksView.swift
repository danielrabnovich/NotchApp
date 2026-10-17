import SwiftUI

/// The Tasks tab: the task list, plus the Notes scratchpad when it's turned on.
struct TasksTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("tasks.pane") private var pane: TasksPane = .tasks

    var body: some View {
        // Each pane draws its own header (the switcher and what goes with it), so they cross-fade
        // rather than slide, which would carry the switcher along.
        ZStack(alignment: .topLeading) {
            Group {
                if settings.notesEnabled && pane == .notes {
                    NotesView(viewModel: viewModel, pane: $pane)
                } else if pane == .prompter {
                    PrompterSetupView(viewModel: viewModel, pane: $pane)
                } else {
                    TasksView(viewModel: viewModel, pane: $pane)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(pane)
            .transition(.opacity)
        }
    }
}

struct TasksView: View {
    @ObservedObject var viewModel: NotchViewModel
    /// Shows the Tasks · Notes switcher in place of the title when set.
    var pane: Binding<TasksPane>?
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var media: MediaController

    @State private var draft = ""
    @State private var showDone = false
    @FocusState private var addFocused: Bool

    var body: some View {
        let accent = settings.accentMode == .custom ? settings.customAccent : Color.green

        VStack(alignment: .leading, spacing: 8) {
            header
            if store.tasks.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.open) { task in
                            TaskRow(task: task, accent: accent, viewModel: viewModel)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .move(edge: .trailing).combined(with: .opacity)))
                        }
                        if !store.doneToday.isEmpty {
                            doneHeader
                            if showDone {
                                ForEach(store.doneToday) { task in
                                    TaskRow(task: task, accent: accent, viewModel: viewModel)
                                        .transition(.opacity)
                                }
                            }
                        }
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.82), value: store.tasks)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let pane {
                PaneSwitcher(selection: pane, options: TasksPane.options)
            } else {
                Text("Today")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(store.openCount == 0 ? "all clear" : "\(store.openCount) open")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3), value: store.openCount)
            Spacer(minLength: 12)
            addField
                .frame(maxWidth: 260)
        }
        .notchHeaderRow()
    }

    private var addField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(addFocused ? 0.9 : 0.45))
            TextField("", text: $draft, prompt: Text("Add a task").foregroundStyle(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($addFocused)
                .onSubmit {
                    store.add(title: draft)
                    draft = ""
                    addFocused = true
                }
                .onExitCommand {
                    // A second Escape (nothing left to discard) backs out of the notch.
                    if draft.isEmpty { viewModel.backOut() }
                    draft = ""
                    addFocused = false
                }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 26)
        .notchSurface(Capsule(), active: addFocused)
        .overlay(alignment: .trailing) {
            if !draft.isEmpty { KeyCap(text: "↩").padding(.trailing, 4).transition(.opacity) }
        }
        .shadow(color: .white.opacity(addFocused ? 0.05 : 0), radius: 10)
        .animation(.easeOut(duration: 0.15), value: addFocused)
        .animation(.easeOut(duration: 0.15), value: draft.isEmpty)
        .onChange(of: addFocused) { _, focused in viewModel.isEditing = focused }
    }

    private var doneHeader: some View {
        Button {
            withAnimation(Motion.pane.animation) { showDone.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(showDone ? 90 : 0))
                Text("Done today · \(store.doneToday.count)")
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                if showDone {
                    Text("Clear")
                        .font(.system(size: 10, weight: .medium))
                        .onTapGesture { store.clearCompleted() }
                }
            }
            .foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 22, weight: .medium))
            Text("Nothing on your plate")
                .font(.system(size: 12, weight: .medium))
            Text("Drag text, links, emails or files onto the notch to add them here")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct TaskRow: View {
    let task: TaskItem
    let accent: Color
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var store: TaskStore

    @State private var checked = false
    @State private var dragX: CGFloat = 0
    @State private var hovering = false
    @State private var editing = false
    @State private var editText = ""
    @FocusState private var editFocused: Bool

    private let threshold: CGFloat = 70

    var body: some View {
        ZStack {
            swipeBackground
            content
                .offset(x: dragX)
        }
        .frame(height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onAppear { checked = task.isDone }
        .onChange(of: task.isDone) { _, done in checked = done }
    }

    private var content: some View {
        HStack(spacing: 9) {
            CheckCircle(checked: checked, color: accent) { toggle() }

            if editing {
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($editFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { editing = false }
                    .onChange(of: editFocused) { _, f in
                        viewModel.isEditing = f
                        if !f { commitEdit() }
                    }
            } else {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .strikethrough(checked, color: .white.opacity(0.5))
                    .foregroundStyle(.white.opacity(checked ? 0.4 : 0.92))
                    .animation(.easeOut(duration: 0.25), value: checked)
                    .onTapGesture(count: 2) { beginEdit() }
                    .help(task.note ?? task.title)
            }

            Spacer(minLength: 4)

            if let due = task.due, !checked {
                DueChip(due: due)
            }

            if let icon = task.linkIcon {
                Button { store.openLink(of: task) } label: {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(NotchIconButtonStyle(size: 22))
                .help(task.link?.isFileURL == true ? task.link!.lastPathComponent : task.link?.absoluteString ?? "")
            }

            if hovering && !editing {
                Button { store.delete(task.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(NotchIconButtonStyle(size: 20))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(store.justAddedID == task.id ? accent.opacity(0.22) : .white.opacity(hovering ? 0.07 : 0))
        )
        .background(Color.black.opacity(dragX == 0 ? 0 : 1))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height), !editing else { return }
                    let x = v.translation.width
                    // Resist a little past the threshold.
                    dragX = abs(x) < threshold ? x : (x < 0 ? -1 : 1) * (threshold + (abs(x) - threshold) * 0.35)
                }
                .onEnded { _ in
                    let x = dragX
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = 0 }
                    if x >= threshold { toggle() }
                    else if x <= -threshold { store.delete(task.id) }
                }
        )
        .contextMenu {
            MenuItem(checked ? "Mark as Not Done" : "Mark as Done", checked ? "circle" : "checkmark.circle") { toggle() }
            MenuItem("Rename", "pencil") { beginEdit() }
            Menu {
                MenuItem("Today, 5 PM", "sun.max") { store.setDue(task.id, Self.at(17, daysFromNow: 0)) }
                MenuItem("Tomorrow, 9 AM", "sunrise") { store.setDue(task.id, Self.at(9, daysFromNow: 1)) }
                MenuItem("Tomorrow, 5 PM", "sunset") { store.setDue(task.id, Self.at(17, daysFromNow: 1)) }
                MenuItem("Next Week", "calendar") { store.setDue(task.id, Self.at(9, daysFromNow: 7)) }
                if task.due != nil {
                    Divider()
                    MenuItem("Remove Due Date", "calendar.badge.minus") { store.setDue(task.id, nil) }
                }
            } label: {
                Label("Due", systemImage: "clock")
            }
            if task.link != nil { MenuItem("Open Link", "link") { store.openLink(of: task) } }
            MenuItem("Copy", "doc.on.doc") { ShelfStore.copyText(task.title) }
            Divider()
            MenuItem("Delete", "trash", role: .destructive) { store.delete(task.id) }
        }
    }

    /// Green "done" reveal on the left, red "delete" on the right.
    private var swipeBackground: some View {
        let progress = min(1, abs(dragX) / threshold)
        return HStack {
            if dragX > 0 {
                Image(systemName: checked ? "arrow.uturn.backward" : "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .scaleEffect(0.6 + 0.4 * progress)
                    .padding(.leading, 12)
                Spacer()
            } else if dragX < 0 {
                Spacer()
                Image(systemName: "trash.fill")
                    .font(.system(size: 11, weight: .bold))
                    .scaleEffect(0.6 + 0.4 * progress)
                    .padding(.trailing, 12)
            }
        }
        .foregroundStyle(.white.opacity(0.4 + 0.6 * progress))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((dragX > 0 ? accent : Color.red).opacity(dragX == 0 ? 0 : 0.15 + 0.5 * progress))
    }

    static func at(_ hour: Int, daysFromNow days: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: days, to: Date())!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    private func toggle() {
        let done = !checked
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { checked = done }
        if done {
            Haptics.level()
            // Let the check animation play before the row slides into "Done".
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { store.setDone(task.id, true) }
            }
        } else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { store.setDone(task.id, false) }
        }
    }

    private func beginEdit() {
        editText = task.title
        editing = true
        DispatchQueue.main.async { editFocused = true }
    }

    private func commitEdit() {
        guard editing else { return }
        store.rename(task.id, to: editText)
        editing = false
        viewModel.isEditing = false
    }
}

// MARK: - Due chip

/// "3 PM", "Tomorrow", "Fri" – orange when due within a day, red when overdue.
private struct DueChip: View {
    let due: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let remaining = due.timeIntervalSince(context.date)
            let color: Color = remaining < 0 ? .red : remaining < 86_400 ? .orange : .white.opacity(0.55)
            HStack(spacing: 3) {
                Image(systemName: remaining < 0 ? "exclamationmark.circle.fill" : "clock")
                    .font(.system(size: 8.5, weight: .bold))
                Text(label(now: context.date))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(color.opacity(0.14)))
        }
        .help(due.formatted(date: .complete, time: .shortened))
    }

    private func label(now: Date) -> String {
        let cal = Calendar.current
        let time = due.formatted(date: .omitted, time: .shortened)
        let isFivePM = cal.component(.hour, from: due) == 17 && cal.component(.minute, from: due) == 0
        if due < now { return "Overdue" }
        if cal.isDateInToday(due) { return time }
        if cal.isDateInTomorrow(due) { return isFivePM ? "Tomorrow" : "Tmrw \(time)" }
        if due.timeIntervalSince(now) < 6 * 86_400 {
            let day = due.formatted(.dateTime.weekday(.abbreviated))
            return isFivePM ? day : "\(day) \(time)"
        }
        return due.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Checkbox

/// Circle that fills, draws a checkmark and throws a little burst of sparks.
struct CheckCircle: View {
    let checked: Bool
    let color: Color
    let action: () -> Void

    @State private var burst = false
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(checked ? 0 : (hovering ? 0.7 : 0.35)), lineWidth: 1.5)
                Circle()
                    .fill(color)
                    .scaleEffect(checked ? 1 : 0.2)
                    .opacity(checked ? 1 : 0)
                CheckmarkShape()
                    .trim(from: 0, to: checked ? 1 : 0)
                    .stroke(.black, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .padding(4.5)
                    .animation(.easeOut(duration: 0.22).delay(checked ? 0.08 : 0), value: checked)

                // Sparks
                ForEach(0..<8, id: \.self) { i in
                    Circle()
                        .fill(color)
                        .frame(width: 3, height: 3)
                        .offset(y: burst ? -15 : -6)
                        .rotationEffect(.degrees(Double(i) * 45))
                        .opacity(burst ? 0 : (checked ? 1 : 0))
                        .scaleEffect(burst ? 0.4 : 1)
                }
                .allowsHitTesting(false)
            }
            .frame(width: 17, height: 17)
            .scaleEffect(checked ? 1 : (hovering ? 1.08 : 1))
            .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onChange(of: checked) { _, now in
            guard now else { burst = false; return }
            burst = false
            withAnimation(.easeOut(duration: 0.5)) { burst = true }
        }
        .keyframeAnimator(initialValue: 1.0, trigger: checked) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(1.28, duration: 0.14)
                SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
            }
        }
    }
}

struct CheckmarkShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY - r.height * 0.08))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.12))
        return p
    }
}
