import SwiftUI

/// Briefs and nudges that the notch drops down with by itself.
struct OverlayView: View {
    let overlay: NotchOverlay

    var body: some View {
        switch overlay {
        case .brief(let brief): BriefView(brief: brief)
        case .nudge(let nudge): NudgeView(nudge: nudge)
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
