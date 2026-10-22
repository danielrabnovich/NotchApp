import SwiftUI

/// On Home during a call: what it is, how long it's been, and its controls in one row — the mic,
/// the call app's camera and hand, captions, and leaving.
struct CallBar: View {
    @ObservedObject private var meetings = MeetingMonitor.shared
    @ObservedObject private var controls = ControlsService.shared
    @ObservedObject private var captions = LiveCaptions.shared
    @State private var actions: [MeetingControls.Action] = []
    /// Debug (`homeshot`): a made-up call to show instead.
    var preview: MeetingMonitor.Call?

    var body: some View {
        if let call = preview ?? meetings.call {
            HStack(spacing: 8) {
                if let id = call.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    AppIcon(bundlePath: url.path, size: 16)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(call.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 4) {
                            // Red only when the call is being kept.
                            Circle().fill(captions.recording ? Color.red : MeetingReading.callBlue).frame(width: 5, height: 5)
                            Text(elapsed(since: call.started, at: context.date) + (captions.recording ? " · Recording" : ""))
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .onTapGesture { MeetingControls.showCall() }
                .help("Show \(call.app)")
                Spacer(minLength: 4)
                control(controls.micMuted ? "mic.slash.fill" : "mic.fill", on: controls.micMuted, tint: .red,
                        help: controls.micMuted ? "Unmute" : "Mute") { controls.toggleMic() }
                if actions.contains(.camera) {
                    control("video.fill", help: "Camera on or off in \(call.app)") { MeetingControls.perform(.camera) }
                }
                if actions.contains(.hand) {
                    control("hand.raised.fill", help: "Raise or lower your hand") { MeetingControls.perform(.hand) }
                }
                if LiveCaptions.isSupported {
                    control("captions.bubble.fill", on: captions.showing, tint: .blue,
                            help: captions.showing ? "Hide captions" : "Show captions") { captions.toggleCaptions() }
                    control(captions.recording ? "stop.circle.fill" : "record.circle", on: captions.recording, tint: .red,
                            help: captions.recording ? "Stop recording and write the notes" : "Record this call") {
                        if captions.recording { MeetingAssistant.shared.stopRecording() } else { MeetingAssistant.shared.record() }
                    }
                }
                if actions.contains(.leave) {
                    Button { MeetingControls.perform(.leave) } label: {
                        Image(systemName: "phone.down.fill").font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 24)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .help("Leave the call")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .notchSurface(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .task(id: call.bundleID) { actions = MeetingControls.available() }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func control(_ symbol: String, on: Bool = false, tint: Color = .white, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(on ? tint : .white.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(NotchIconButtonStyle(size: 24))
        .help(help)
    }

    private func elapsed(since start: Date, at now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
