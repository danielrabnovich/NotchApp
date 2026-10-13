import SwiftUI

/// Briefs and nudges that the notch drops down with by itself.
struct OverlayView: View {
    let overlay: NotchOverlay

    var body: some View {
        switch overlay {
        case .brief(let brief): BriefView(brief: brief)
        case .nudge(let nudge): NudgeView(nudge: nudge)
        case .prompt(let prompt): PromptView(prompt: prompt)
        case .message(let item): MessageReplyView(item: item)
        case .teleprompter: TeleprompterView().onDisappear { Teleprompter.shared.ended() }
        }
    }
}

private struct BriefView: View {
    let brief: Brief
    @State private var appeared = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .symbolRenderingMode(.multicolor)
                    Text(brief.greeting)
                }
                .font(.system(size: 17, weight: .bold))

                HStack(alignment: .top, spacing: 5) {
                    if brief.aiWritten {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.top, 3)
                    }
                    Text(brief.summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    if let focus = brief.focusTaskID {
                        Button {
                            NotchPresenter.shared.open(tab: .tasks)
                            TaskStore.shared.justAddedID = focus
                        } label: {
                            Label("Let's start", systemImage: "play.fill")
                        }
                        .buttonStyle(NotchPillButtonStyle(primary: true))
                    }
                    Button {
                        NotchPresenter.shared.dismissOverlay(close: true)
                    } label: {
                        Text("Dismiss")
                    }
                    .buttonStyle(NotchPillButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !brief.items.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(brief.items.enumerated()), id: \.element.id) { i, item in
                            HStack(spacing: 8) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color(nsColor: item.color))
                                    .frame(width: 16)
                                Text(item.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(item.detail)
                                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                    .foregroundStyle(Color(nsColor: item.color).opacity(0.9))
                            }
                            .frame(height: 24)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 6)
                            .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.08 * Double(i) + 0.15), value: appeared)
                        }
                    }
                }
                .frame(width: 270)
            }
        }
        .onAppear { appeared = true }
    }

    private var icon: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "sun.horizon.fill" : h < 17 ? "sun.max.fill" : "moon.stars.fill"
    }
}

private struct NudgeView: View {
    let nudge: Nudge
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill((nudge.overdue ? Color.red : Color.orange).opacity(0.18))
                Image(systemName: nudge.overdue ? "exclamationmark" : "clock.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(nudge.overdue ? Color.red : Color.orange)
                    .symbolEffect(.bounce, value: nudge.taskID)
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 5) {
                Text(nudge.dueText)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(nudge.overdue ? Color.red : Color.orange)
                Text(nudge.title)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                Text(nudge.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .contentTransition(.opacity)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    pill(nudge.hasLink ? "Start now" : "Start", icon: "play.fill", primary: true) {
                        BriefingService.shared.start(nudge)
                    }
                    pill("Snooze 30m", icon: "moon.zzz.fill") { BriefingService.shared.snooze(nudge) }
                    pill("Done", icon: "checkmark") { BriefingService.shared.complete(nudge) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pill(_ title: String, icon: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .buttonStyle(NotchPillButtonStyle(primary: primary))
    }
}

/// A heads-up with its buttons, filling the notch until acted on or dismissed.
private struct PromptView: View {
    let prompt: Prompt

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: prompt.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(nsColor: prompt.tint))
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color(nsColor: prompt.tint).opacity(0.16)))
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                Text(prompt.detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            }
            Spacer(minLength: 10)
            HStack(spacing: 8) {
                Button("Dismiss") { NotchPresenter.shared.dismissOverlay(close: false) }
                    .buttonStyle(NotchPillButtonStyle())
                ForEach(Array(prompt.actions.enumerated()), id: \.offset) { _, action in
                    Button(action.title) {
                        action.run()
                        NotchPresenter.shared.dismissOverlay(close: true)
                    }
                    .buttonStyle(NotchPillButtonStyle(primary: action.primary))
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A notification opened from its Banner: the whole message, and a reply box ready to type into.
private struct MessageReplyView: View {
    let item: NotificationMirror.Item
    @State private var reply = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let id = item.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    AppIcon(bundlePath: url.path, size: 40)
                } else {
                    Image(systemName: "bell.fill").font(.system(size: 20)).frame(width: 40, height: 40)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(item.sender)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text("\(item.app) · \(item.date.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    Text(item.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 66)
                .fixedSize(horizontal: false, vertical: true)
                if item.replyable {
                    HStack(spacing: 6) {
                        TextField("", text: $reply, prompt: Text("Reply to \(item.sender)…").foregroundStyle(.white.opacity(0.35)), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .lineLimit(1...3)
                            .focused($focused)
                            .onSubmit(send)
                        Button(action: send) {
                            Image(systemName: sending ? "ellipsis" : "arrow.up").font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(NotchIconButtonStyle(size: 22))
                        .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                        .help("Send without leaving what you're doing")
                    }
                    .padding(.leading, 11)
                    .padding(.trailing, 3)
                    .padding(.vertical, 3)
                    .frame(minHeight: 30)
                    .notchSurface(RoundedRectangle(cornerRadius: 15, style: .continuous), active: focused)
                }
                HStack(spacing: 8) {
                    Button("Open \(item.app)") {
                        NotificationMirror.shared.open(item)
                        NotchPresenter.shared.dismissOverlay(close: true)
                    }
                    .buttonStyle(NotchPillButtonStyle(primary: !item.replyable))
                    Button("Dismiss") {
                        NotificationMirror.shared.dismiss(item)
                        NotchPresenter.shared.dismissOverlay(close: true)
                    }
                    .buttonStyle(NotchPillButtonStyle())
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 6)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focused = true } }
    }

    private func send() {
        let text = reply
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sending else { return }
        sending = true
        Task {
            let outcome = await NotificationMirror.shared.reply(item, text: text)
            sending = false
            NotchPresenter.shared.dismissOverlay(close: true)
            switch outcome {
            case .sent:
                ActivityCenter.shared.show(.notice(title: "Sent to \(item.sender)", detail: text, icon: "arrowshape.turn.up.left.fill", tone: .success), for: 2.5)
            case .opened:
                ActivityCenter.shared.show(.notice(title: "Reply copied", detail: "Paste it into \(item.app)", icon: "doc.on.clipboard", tone: .info), for: 3)
            }
        }
    }
}
