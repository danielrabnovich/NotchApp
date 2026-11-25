import EventKit
import SwiftUI
import UniformTypeIdentifiers

// The small readings and glyphs each Glance draws beside the closed notch.

/// An action Glance: its glyph, lit in its colour while its switch is on (Dark Mode, a muted mic…).
struct ActionGlyph: View {
    let item: LiveItem
    @ObservedObject private var controls = ControlsService.shared
    @ObservedObject private var tweaks = SystemTweaks.shared
    @ObservedObject private var assistant = AssistantStore.shared

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(on ? item.tint : .white.opacity(0.78))
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, options: .repeating, isActive: busy)
            .onAppear { if item == .quickDarkMode || item == .quickMic || item == .quickWiFi { controls.refresh() } }
    }

    private var on: Bool {
        switch item {
        case .quickDarkMode: controls.darkMode
        case .quickMic: controls.micMuted
        case .quickWiFi: !controls.wifiOn
        case .quickNightShift: tweaks.nightShiftOn
        case .quickCopyText: tweaks.recognizing
        default: false
        }
    }

    private var busy: Bool {
        if case .capturing? = assistant.context, item == .askScreen { return true }
        return item == .quickCopyText && tweaks.recognizing
    }

    private var icon: String {
        switch item {
        case .quickMic: controls.micMuted ? "mic.slash.fill" : "mic.fill"
        case .quickWiFi: controls.wifiOn ? "wifi" : "wifi.slash"
        case .quickNightShift: tweaks.nightShiftOn ? "moon.circle.fill" : "moon.circle"
        default: item.icon
        }
    }
}

/// The starred actions for the app in front, one glyph each. With more than one, each glyph is its
/// own button (with one, the whole Glance is).
struct AppActionGlyphs: View {
    @ObservedObject private var actions = AppActions.shared

    var body: some View {
        HStack(spacing: 0) {
            ForEach(actions.glanceActions, id: \.stableKey) { command in
                if actions.glanceActions.count > 1 {
                    Image(systemName: command.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let vm = NotchPresenter.shared.primary { actions.runGlance(command, in: vm) }
                        }
                        .help(command.title)
                } else {
                    Image(systemName: command.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 24)
                }
            }
        }
    }
}

/// Beside Duo: the battery's percent, red when low, as the Battery Glance shows it; on a Mac
/// without a battery, the processor's load (what its ring shows there).
struct DuoReading: View {
    @ObservedObject private var battery = BatteryMonitor.shared
    @ObservedObject private var stats = SystemMonitor.shared

    var body: some View {
        let onPower = battery.isCharging || battery.isPluggedIn
        let text = battery.hasBattery ? "\(battery.level)%" : "\(Int((stats.snapshot.cpuTotal * 100).rounded()))%"
        Text(text)
            .font(LiveItemView.valueFont)
            .foregroundStyle(battery.hasBattery && battery.level <= 20 && !onPower ? .red : .white.opacity(0.92))
            .fixedSize()
            .rollingDigits(battery.level)
    }
}

/// Beside Stats Rings: the temperature over the power, small, as the rings say how busy and
/// these say how hot and how hungry. One of them alone when the Mac doesn't report the other.
struct RingsReading: View {
    let alignment: HorizontalAlignment
    @ObservedObject private var stats = SystemMonitor.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let s = stats.snapshot
        let temp = s.cpuTemp.map { settings.useFahrenheit ? "\(Int(($0 * 9 / 5 + 32).rounded()))°" : "\(Int($0.rounded()))°" }
        let power = s.systemPower.map { "\(formatSmall($0))W" }
        VStack(alignment: alignment, spacing: -1) {
            ForEach([temp, power].compactMap { $0 }, id: \.self) { line in
                Text(line)
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(.white.opacity(0.88))
        .fixedSize()
    }
}

/// The Focus that's on: its own symbol in its color, and its name. With none on (pinned to show
/// always), a dim moon; without Full Disk Access, the moon with a lock, to say what it needs.
struct FocusReading: View {
    var compact = false
    @ObservedObject private var focus = FocusMonitor.shared

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if !focus.readable {
                    Image(systemName: "moon.fill")
                        .foregroundStyle(.white.opacity(0.4))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "lock.fill").font(.system(size: 6.5, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                                .offset(x: 3, y: 2)
                        }
                } else if let f = focus.current {
                    Image(systemName: f.symbol).foregroundStyle(Color(nsColor: f.color))
                } else {
                    Image(systemName: "moon").foregroundStyle(.white.opacity(0.4))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            if !compact {
                Text(focus.readable ? focus.current?.shortName ?? "Off" : "Focus")
                    .font(LiveItemView.valueFont)
                    .foregroundStyle(.white.opacity(focus.current == nil ? 0.5 : 0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 52, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: focus.current)
    }
}

/// The Shortcuts kept beside the notch: each its initial on a colored tile, pulsing while it runs.
/// With several, each runs its own; with one, the Glance's click does.
struct ShortcutGlyphs: View {
    @ObservedObject private var shortcuts = ShortcutsApp.shared

    var body: some View {
        let picked = shortcuts.glanceShortcuts
        HStack(spacing: 0) {
            if picked.isEmpty {
                Image(systemName: "square.2.layers.3d.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 24)
            }
            ForEach(picked) { s in
                let tile = ShortcutTile(shortcut: s, running: shortcuts.running.contains(s.id), finished: shortcuts.finished[s.id])
                    .frame(width: 24, height: 22)
                if picked.count > 1 {
                    tile.contentShape(Rectangle())
                        .onTapGesture { Haptics.tap(); shortcuts.run(s) }
                        .help(s.name)
                } else {
                    tile
                }
            }
        }
        .onAppear { shortcuts.refreshIfStale() }
    }
}

/// A Shortcut's glyph: its initial on a rounded tile in its color.
struct ShortcutTile: View {
    let shortcut: ShortcutsApp.Shortcut
    var running = false
    /// Just finished: true worked (✓), false failed (!).
    var finished: Bool? = nil
    var size: CGFloat = 15

    var body: some View {
        // Symbols sized as images, not set as text: text sits on its baseline, below the tile's middle.
        ZStack {
            if let finished {
                Image(systemName: finished ? "checkmark" : "exclamationmark")
                    .resizable()
                    .fontWeight(.heavy)
                    .scaledToFit()
                    .frame(width: size * 0.5, height: size * 0.5)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            } else if let symbol = shortcut.symbol {
                Image(systemName: symbol)
                    .resizable()
                    .fontWeight(.semibold)
                    .scaledToFit()
                    .frame(width: size * 0.6, height: size * 0.6)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Text(shortcut.initial)
                    .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(finished == false ? Color(red: 1, green: 0.27, blue: 0.23).gradient : shortcut.color.gradient))
        .pixelSnapped()
        .opacity(running ? 0.55 : 1)
        .animation(running ? .easeInOut(duration: 0.6).repeatForever() : .default, value: running)
    }
}

/// The world clock, golden hour, unread counts and countdown: a glyph and a reading
/// (compact: the reading alone).
struct ExtraReading: View {
    let item: LiveItem
    var compact = false
    @ObservedObject private var unread = UnreadBadges.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 5) {
                glyph(at: context.date)
                Text(value(at: context.date))
                    .font(LiveItemView.valueFont)
                    .rollingDigits(value(at: context.date))
                    .foregroundStyle(tint(at: context.date))
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private func glyph(at date: Date) -> some View {
        switch item {
        case .worldClock:
            if !compact {
                Text(WorldClock.city.short)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
        case .goldenHour:
            if !compact {
                Image(systemName: GoldenHour.now(date)?.icon ?? "sun.horizon")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GoldenHour.now(date)?.golden == true ? Color.orange : .white.opacity(0.6))
            }
        case .unread:
            if compact || unread.badges.isEmpty {
                Image(systemName: "bubble.left.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            } else {
                HStack(spacing: -5) {
                    ForEach(unread.badges.prefix(2)) { badge in
                        AppIcon(bundlePath: badge.appURL.path, size: 15)
                    }
                }
            }
        case .countdown:
            if !compact {
                Image(systemName: "flag.checkered").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            }
        default:
            EmptyView()
        }
    }

    private func value(at date: Date) -> String {
        switch item {
        case .worldClock:
            var style = Date.FormatStyle(date: .omitted, time: .shortened)
            style.timeZone = TimeZone(identifier: WorldClock.city.zone) ?? .current
            return date.formatted(style).replacingOccurrences(of: " AM", with: "a").replacingOccurrences(of: " PM", with: "p")
        case .goldenHour:
            return GoldenHour.now(date)?.text ?? "–"
        case .unread:
            return "\(unread.total)"
        case .countdown:
            return Countdown.text(at: date)
        default:
            return ""
        }
    }

    private func tint(at date: Date) -> Color {
        switch item {
        case .goldenHour where GoldenHour.now(date)?.golden == true: Color(red: 1, green: 0.75, blue: 0.35)
        case .unread where unread.total > 0: .white
        default: .white.opacity(0.92)
        }
    }
}

/// The weather as the Apple Watch's temperature complication: an open ring across today's low to
/// high, in the colours of the temperatures along it, a dot where it is now, and the temperature
/// inside.
struct WeatherGauge: View {
    let diameter: CGFloat
    @ObservedObject private var weather = TodayWeather.shared

    var body: some View {
        let line = max(2, (diameter / 9 * 2).rounded() / 2)
        let radius = (diameter - line) / 2
        ZStack {
            if let report = weather.report {
                let low = min(report.days.first?.low ?? report.currentTemp, report.currentTemp)
                let high = max(report.days.first?.high ?? report.currentTemp, report.currentTemp)
                let at = high > low ? (report.currentTemp - low) / (high - low) : 0.5
                // The ring opens at the bottom: from 135° round to 405°, clockwise.
                let colors = (0...6).map { report.tint(low + (high - low) * Double($0) / 6) }
                Circle()
                    .inset(by: line / 2)
                    .trim(from: 0.125, to: 0.875)
                    .rotation(.degrees(90))
                    .stroke(AngularGradient(colors: colors, center: .center, startAngle: .degrees(135), endAngle: .degrees(405)),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                let angle = Angle.degrees(135 + 270 * at).radians
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.black, lineWidth: 1))
                    .frame(width: line + 1.5, height: line + 1.5)
                    .offset(x: radius * cos(angle), y: radius * sin(angle))
                Text("\(Int(report.currentTemp.rounded()))°")
                    .font(.system(size: diameter * 0.36, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    // The degree sign hangs off to the right, as on the watch: the number sits centred.
                    .offset(x: diameter * 0.05)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .frame(width: diameter - 2 * line)
                    .rollingDigits(Int(report.currentTemp.rounded()))
            } else {
                Circle()
                    .inset(by: line / 2)
                    .trim(from: 0.125, to: 0.875)
                    .rotation(.degrees(90))
                    .stroke(.white.opacity(0.2), style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
        }
        .frame(width: diameter, height: diameter)
        .pixelSnapped()
        .animation(.easeInOut(duration: 0.6), value: weather.report?.currentTemp)
    }
}

/// What's furthest along of everything in progress: a ring (its app's icon inside, when it's an
/// app exporting) and the percent, or how many files of a batch are done. Anything else running
/// is on the hover card: there's no room for it here.
struct ProgressReading: View {
    var compact = false
    @ObservedObject private var progress = ProgressCenter.shared

    var body: some View {
        let lead = progress.lead
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 2)
                if let f = lead?.fraction {
                    Circle().trim(from: 0, to: max(0.03, f))
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: f)
                } else {
                    ProgressView().controlSize(.mini).tint(.white).scaleEffect(0.6)
                }
                if let path = lead?.bundlePath {
                    AppIcon(bundlePath: path, size: 11)
                }
            }
            .frame(width: 17, height: 17)
            if !compact {
                if let label = lead?.label {
                    Text(label)
                        .font(LiveItemView.valueFont)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.25), value: label)
                        .foregroundStyle(.white.opacity(0.92))
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                } else {
                    Text(lead?.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "…")
                        .font(LiveItemView.valueFont)
                        .rollingDigits(lead?.fraction)
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize()
                }
            }
        }
    }
}

/// A call in progress: a blue dot (a red waveform while it's transcribed), how long it's been
/// going, and the microphone (red while muted).
struct MeetingReading: View {
    static let callBlue = Color(red: 0.25, green: 0.6, blue: 1)
    var compact = false
    @ObservedObject private var meetings = MeetingMonitor.shared
    @ObservedObject private var controls = ControlsService.shared
    @ObservedObject private var captions = LiveCaptions.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: compact ? 4 : 5) {
                // Red means it's being kept: a pulsing red waveform while the call is transcribed.
                // Otherwise a steady blue dot, just "you're on a call".
                if captions.recording {
                    Image(systemName: "waveform").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.red)
                        .opacity(Int(context.date.timeIntervalSinceReferenceDate) % 2 == 0 ? 1 : 0.45)
                        .animation(.easeInOut(duration: 0.6), value: Int(context.date.timeIntervalSinceReferenceDate))
                } else {
                    Circle().fill(MeetingReading.callBlue).frame(width: 6, height: 6)
                }
                Text(elapsed(at: context.date))
                    .font(LiveItemView.valueFont)
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize()
                if !compact {
                    Image(systemName: controls.micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(controls.micMuted ? .red : .white.opacity(0.6))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .help(meetings.call.map { "\($0.title) · \($0.app)" + (captions.recording ? " · transcribing" : "") } ?? "")
    }

    private func elapsed(at now: Date) -> String {
        guard let call = meetings.call else { return "0:00" }
        let s = max(0, Int(now.timeIntervalSince(call.started)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Download speed, with an arrow that lights up for whichever way is busier.
struct NetworkReading: View {
    var compact = false
    @ObservedObject private var network = NetworkMonitor.shared

    var body: some View {
        let uploading = network.upRate > network.downRate * 1.5 && network.upRate > 50_000
        let r = formatRate(uploading ? network.upRate : network.downRate)
        HStack(spacing: compact ? 2 : 4) {
            Image(systemName: uploading ? "arrow.up" : "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(uploading ? ToolsPalette.up : ToolsPalette.down)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(r.value).font(LiveItemView.valueFont).foregroundStyle(.white.opacity(0.92))
                Text(compact ? String(r.unit.prefix(1)) : r.unit.replacingOccurrences(of: "/s", with: ""))
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .fixedSize()
        }
    }
}

/// The emptiest Bluetooth device's glyph and level.
struct DeviceReading: View {
    var compact = false
    @ObservedObject private var devices = DeviceBatteries.shared

    var body: some View {
        if let device = devices.lowest, let level = device.level {
            let low = level <= 20
            HStack(spacing: 4) {
                Image(systemName: device.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(compact && low ? Color(red: 1, green: 0.38, blue: 0.35) : .white.opacity(0.7))
                if !compact {
                    Text("\(level)%")
                        .font(LiveItemView.valueFont)
                        .foregroundStyle(low ? Color(red: 1, green: 0.38, blue: 0.35) : .white.opacity(0.92))
                        .fixedSize()
                }
            }
            .help("\(device.name): \(level)%")
        }
    }
}

/// Agents at work: a spinner and how many; a raised hand when one is waiting for you.
struct AgentsReading: View {
    var compact = false
    @ObservedObject private var agents = AgentMonitor.shared

    var body: some View {
        let waiting = agents.waiting.count, working = agents.working.count
        HStack(spacing: 4) {
            if waiting > 0 {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating)
            } else if working > 0 {
                Image(systemName: "sparkle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(KeepAwakeReading.agentPurple)
            } else {
                Image(systemName: "sparkle").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            }
            if !compact {
                Text("\(waiting > 0 ? waiting : working)")
                    .font(LiveItemView.valueFont)
                    .foregroundStyle(waiting > 0 ? .orange : .white.opacity(0.92))
            }
        }
        .help(agents.sessions.filter { $0.state != .idle }.map { session in
            "\(session.tool.name) · \(session.project)" + (AgentHooks.shared.live(for: session)?.activity.map { ": \($0)" } ?? "")
        }.joined(separator: "\n"))
    }
}

/// A cup while the Mac is kept awake: time left for a timed session, "On" otherwise.
struct KeepAwakeReading: View {
    var compact = false
    @ObservedObject private var keepAwake = KeepAwake.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(keepAwake.forAgents ? Self.agentPurple : Color(red: 0.92, green: 0.75, blue: 0.55))
                .fixedSize()
            if !compact {
                Text(keepAwake.endsAt == nil ? "On" : keepAwake.remainingText ?? "On")
                    .font(LiveItemView.valueFont)
                    .rollingDigits(keepAwake.remainingText)
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize()
            }
        }
        .help(keepAwake.forAgents ? "Awake while your agents work" : "Keep Awake")
    }
}

extension KeepAwakeReading {
    static let agentPurple = Color(red: 0.78, green: 0.6, blue: 1)
}

/// Free space on the startup disk; red under 10 GB.
struct DiskReading: View {
    var compact = false
    @ObservedObject private var cleaner = Cleaner.shared

    var body: some View {
        let free = cleaner.disk?.available ?? 0
        HStack(spacing: 4) {
            if !compact {
                Image(systemName: "internaldrive.fill").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            }
            Text(free >= 1_000_000_000_000 ? String(format: "%.1fT", Double(free) / 1e12) : "\(free / 1_000_000_000)G")
                .font(LiveItemView.valueFont)
                .rollingDigits(free / 1_000_000_000)
                .foregroundStyle(free < 10_000_000_000 ? Color(red: 1, green: 0.38, blue: 0.35) : .white.opacity(0.92))
                .fixedSize()
        }
        .help("\(formatBytes(free)) free")
    }
}

/// A shield (green when all traffic is protected) and the exit country.
struct VPNReading: View {
    var compact = false
    @ObservedObject private var vpn = VPNMonitor.shared

    var body: some View {
        let protected = vpn.connections.contains { $0.isUp && $0.fullTunnel }
        HStack(spacing: 4) {
            Image(systemName: protected ? "lock.shield.fill" : vpn.anyUp ? "shield.lefthalf.filled" : "shield.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(protected ? Color.green : vpn.anyUp ? .white.opacity(0.7) : .orange)
            if !compact {
                Text(protected ? (vpn.exit?.countryCode?.uppercased() ?? "On") : vpn.anyUp ? "Split" : "Off")
                    .font(LiveItemView.valueFont)
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .help(vpn.active.map { "\($0.name)" + (vpn.exit.map { " · \($0.place)" } ?? "") } ?? "No VPN")
    }
}

/// An orange mic or green camera dot, like the menu bar's privacy indicator.
struct PrivacyReading: View {
    @ObservedObject private var privacy = PrivacyMonitor.shared

    var body: some View {
        HStack(spacing: 3) {
            if privacy.cameraInUse {
                Image(systemName: "video.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
            }
            if privacy.micInUse {
                Image(systemName: "mic.fill").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.orange)
            }
        }
        .help(privacy.micApps.map(\.name).joined(separator: ", "))
    }
}

/// The next meeting: its calendar's color, then "in 12m" or its start time.
struct NextEventReading: View {
    var compact = false
    @EnvironmentObject private var calendar: CalendarManager
    @ObservedObject private var leaveBy = LeaveBy.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            if let event = LiveActivities.nextEvent(now: context.date) {
                // With a place to drive to, the count is to leaving, not to the start.
                let leave = leaveBy.minutesToLeave(for: event, now: context.date)
                let minutes = leave ?? Int(event.startDate.timeIntervalSince(context.date) / 60)
                HStack(spacing: 5) {
                    if leave != nil {
                        Image(systemName: "car.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color(cgColor: event.calendar.cgColor))
                    } else {
                        Circle()
                            .fill(Color(cgColor: event.calendar.cgColor))
                            .frame(width: 7, height: 7)
                    }
                    Text(leave.map { $0 <= 0 ? "Leave now" : compact ? "\($0)m" : "leave \($0)m" }
                         ?? (minutes < 60 ? (compact ? "\(max(minutes, 1))m" : "in \(max(minutes, 1))m")
                             : compact ? "\(minutes / 60)h" : event.startDate.formatted(date: .omitted, time: .shortened)))
                        .font(LiveItemView.valueFont)
                        .rollingDigits(minutes)
                        .foregroundStyle(minutes < 10 ? Color(cgColor: event.calendar.cgColor) : .white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .help(event.title ?? "")
            }
        }
    }
}
