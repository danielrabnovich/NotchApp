import SwiftUI

struct CalendarResult: View {
    let answer: CalendarAnswer

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(answer.headline)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                if let detail = answer.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Button("Open Calendar") { CalendarManager.shared.openCalendar() }
                        .buttonStyle(NotchPillButtonStyle())
                    if !answer.tasks.isEmpty {
                        Button("Open Tasks") { CommandCenter.shared.show(.tasks, pane: TasksPane.tasks.rawValue) }
                            .buttonStyle(NotchPillButtonStyle())
                    }
                }
            }
            .frame(width: 220, alignment: .leading)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(answer.events) { event in
                        HStack(spacing: 10) {
                            // The calendar's own colour, as Calendar shows it.
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(event.color.map { Color(red: $0[0], green: $0[1], blue: $0[2]) } ?? .white.opacity(0.35))
                                .frame(width: 3, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text(CommandParser.eventText(event.start, event.end, allDay: event.allDay)
                                     + (event.location.map { " · \($0)" } ?? ""))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                    if !answer.free.isEmpty {
                        let t = Date.FormatStyle(date: .omitted, time: .shortened)
                        ForEach(answer.free, id: \.start) { slot in
                            HStack(spacing: 10) {
                                Image(systemName: "circle.dashed").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                                Text("\(slot.start.formatted(.dateTime.weekday(.abbreviated))) \(slot.start.formatted(t)) – \(slot.end.formatted(t))")
                                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                                Text(BriefingService.duration(slot.duration))
                                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                    if !answer.tasks.isEmpty {
                        if !answer.events.isEmpty || !answer.free.isEmpty {
                            Text("Tasks")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.35))
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                        }
                        ForEach(answer.tasks) { task in TaskCheckRow(task: task) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A task in an answer, ticked off right there.
private struct TaskCheckRow: View {
    let task: CalendarAnswer.TaskBrief
    @EnvironmentObject private var tasks: TaskStore

    var body: some View {
        let done = tasks.tasks.first { $0.id == task.id }?.isDone ?? false
        HStack(spacing: 10) {
            Button {
                withAnimation(Motion.small.animation) { tasks.setDone(task.id, !done) }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(done ? .green : .white.opacity(0.45))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(done ? "Mark as not done" : "Mark as done")
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .strikethrough(done, color: .white.opacity(0.5))
                    .foregroundStyle(.white.opacity(done ? 0.45 : 1))
                    .lineLimit(1)
                if let due = task.due {
                    Text(task.overdue ? "Overdue · \(due.formatted(date: .abbreviated, time: .shortened))"
                         : "Due \(due.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(task.overdue && !done ? Color.orange.opacity(0.85) : .white.opacity(0.45))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// An answer from the app's notes and tasks, with the lines it came from.
struct NotesResult: View {
    let answer: NotesAnswer
    @EnvironmentObject private var tasks: TaskStore

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                // Long answers get smaller rather than cut off, and can be copied.
                Text(answer.headline)
                    .font(.system(size: answer.headline.count > 140 ? 12.5 : answer.headline.count > 70 ? 14 : 17, weight: .semibold))
                    .lineLimit(7)
                    .minimumScaleFactor(0.85)
                    .textSelection(.enabled)
                if let detail = answer.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Button("Open Notes") { CommandCenter.shared.show(.tasks, pane: TasksPane.notes.rawValue) }
                        .buttonStyle(NotchPillButtonStyle(primary: true))
                    if answer.lines.contains(where: { $0.task != nil }) {
                        Button("Tasks") { CommandCenter.shared.show(.tasks, pane: TasksPane.tasks.rawValue) }
                            .buttonStyle(NotchPillButtonStyle())
                    }
                }
            }
            .frame(width: 250, alignment: .leading)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(answer.lines) { line in
                        if let id = line.task {
                            TaskCheckRow(task: .init(id: id, title: line.text, due: line.due,
                                                     overdue: line.due.map { $0 < Date() } ?? false))
                        } else {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "text.alignleft")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.35))
                                    .frame(width: 14)
                                    .padding(.top, 2)
                                Text(line.text)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.white.opacity(0.88))
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct WeatherCard: View {
    let report: WeatherReport
    let accent: Color
    /// The days under the summary rather than beside it, for a narrow place (a chat).
    var stacked = false

    var body: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 22))
        let shown = Array(report.days.prefix(stacked ? 7 : 5))
        // The week's range, so each day's bar sits where its temperatures fall within it.
        let coldest = shown.map(\.low).min() ?? 0, warmest = shown.map(\.high).max() ?? 1
        layout {
            let focus = report.days.indices.contains(report.focusDay) ? report.days[report.focusDay] : nil
            HStack(spacing: 14) {
                Image(systemName: WeatherReport.symbol(report.focusDay == 0 ? report.currentCode : focus?.code ?? report.currentCode))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 46))
                    .shadow(color: glow(report.focusDay == 0 ? report.currentCode : focus?.code ?? report.currentCode).opacity(0.45), radius: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.place)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    if report.focusDay == 0 {
                        Text("\(Int(report.currentTemp.rounded()))°")
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .foregroundStyle(tint(report.currentTemp))
                        Text("\(WeatherReport.describe(report.currentCode)) · feels \(Int(report.feelsLike.rounded()))°")
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    } else if let focus {
                        Text(report.focusDay == 1 ? "Tomorrow" : focus.date.formatted(.dateTime.weekday(.wide)))
                            .font(.system(size: 13, weight: .medium))
                        (Text("\(Int(focus.high.rounded()))°").foregroundColor(tint(focus.high))
                         + Text(" / ").foregroundColor(.white.opacity(0.35))
                         + Text("\(Int(focus.low.rounded()))°").foregroundColor(tint(focus.low)))
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                        Text("\(WeatherReport.describe(focus.code)) · \(focus.rainChance)% rain")
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, day in
                    VStack(spacing: 6) {
                        Text(i == 0 ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(i == report.focusDay ? 0.95 : 0.5))
                        Image(systemName: WeatherReport.symbol(day.code))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 17))
                            .frame(height: 22)
                        Text("\(Int(day.high.rounded()))°")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(tint(day.high))
                        range(day, coldest: coldest, warmest: warmest)
                        Text("\(Int(day.low.rounded()))°")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(tint(day.low).opacity(0.75))
                        if day.rainChance >= 20 {
                            Text("\(day.rainChance)%")
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1))
                        } else {
                            Text(" ").font(.system(size: 9.5))
                        }
                    }
                    .frame(width: stacked ? nil : 46)
                    .frame(maxWidth: stacked ? .infinity : nil)
                    .padding(.vertical, 8)
                    .background {
                        if i == report.focusDay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(LinearGradient(colors: [glow(day.code).opacity(0.22), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func tint(_ temp: Double) -> Color { report.tint(temp) }
    private func glow(_ code: Int) -> Color { WeatherReport.glow(code) }

    private func range(_ day: WeatherReport.Day, coldest: Double, warmest: Double) -> some View {
        TempRange(report: report, low: day.low, high: day.high, coldest: coldest, warmest: warmest)
    }
}

/// A kept call's notes, and beside them its transcript: click a line to hear the call from there.
/// While the call is being transcribed again or written up, that shows here as it goes.
struct MeetingResults: View {
    let job: AssistantStore.Job
    let id: UUID
    let accent: Color
    @ObservedObject private var meetings = MeetingAssistant.shared
    @ObservedObject private var player = MeetingPlayer.shared
    /// The voice being named by hand, and the name so far.
    @State private var renaming: Int?
    @State private var draft = ""
    @FocusState private var naming: Bool

    var body: some View {
        let stage = meetings.stage[id]
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                notes(stage)
                if job.state == .done { RouteFooter(job: job) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let meeting = meetings.meeting(id) {
                transcript(meeting, stage: stage).frame(width: 280)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private func notes(_ stage: MeetingAssistant.Stage?) -> some View {
        let text: String = {
            if let answer = job.answer, !answer.isEmpty { return answer }
            if case .writing(let soFar)? = stage { return soFar }
            return ""
        }()
        if case .failed(let message) = job.state {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 18))
                Text(message).font(.system(size: 12)).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if text.isEmpty {
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                SearchingCapsule(icon: "waveform")
                ShimmerText(text: label(stage))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                AnswerText(text: text, accent: accent).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func label(_ stage: MeetingAssistant.Stage?) -> String {
        switch stage {
        case .transcribing?: "Listening to the call again"
        case .downloadingVoices?: "Getting the voice model"
        case .voices?: "Telling voices apart"
        case .writing?: "Writing notes"
        case nil: if case .running(let s) = job.state { s } else { "Writing notes" }
        }
    }

    private func transcript(_ meeting: MeetingAssistant.Meeting, stage: MeetingAssistant.Stage?) -> some View {
        let audio = !meetings.tracks(id).isEmpty
        let here = player.meeting == id
        let current = here ? meeting.lines.last(where: { ($0.offset ?? .infinity) <= player.position + 0.3 })?.id : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if audio {
                    Button { player.toggle(id) } label: {
                        Image(systemName: here && player.playing ? "pause.fill" : "play.fill").font(.system(size: 10, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(NotchIconButtonStyle(size: 22))
                    .help(here && player.playing ? "Pause" : "Play the call")
                }
                if let renaming {
                    renameField(renaming, in: meeting)
                } else {
                    Text(here ? clock(player.position) : "Transcript")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    if let (title, p) = progress(stage) {
                        Text("\(title) \(Int(p * 100))%")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.4))
                        ProgressView(value: p).progressViewStyle(.linear).frame(width: 46).tint(accent)
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(meeting.lines) { line in
                            row(line, in: meeting, current: line.id == current, playable: audio && line.offset != nil)
                                .id(line.id)
                        }
                    }
                }
                .onChange(of: current) { _, new in
                    guard let new, player.playing else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    /// What the transcript's header shows as the call's worked on after it ends.
    private func progress(_ stage: MeetingAssistant.Stage?) -> (String, Double)? {
        switch stage {
        case .transcribing(let p)?: ("Improving", p)
        case .downloadingVoices(let p)?: ("Voice model", p)
        case .voices(let p)?: ("Voices", p)
        default: nil
        }
    }

    private func row(_ line: LiveCaptions.Line, in meeting: MeetingAssistant.Meeting, current: Bool, playable: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if meeting.inPerson != true {
                speaker(line, in: meeting)
                    // Room for names once voices are told apart.
                    .frame(width: meeting.voices?.isEmpty == false ? 52 : 30, alignment: .leading)
            }
            Text(line.text)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(current ? 0.95 : 0.72))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(current ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { if playable, let offset = line.offset { player.play(id, from: max(0, offset - 0.4)) } }
        .help(playable ? "Play from here" : "")
    }

    /// Who said it. Once voices are told apart, a voice's label is a menu to name it: the people
    /// invited, someone heard before, another name, or not sure. Its lines all follow.
    @ViewBuilder private func speaker(_ line: LiveCaptions.Line, in meeting: MeetingAssistant.Meeting) -> some View {
        let label = Text(meeting.label(line))
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(line.speaker == .you ? accent.opacity(0.9) : .white.opacity(0.4))
            .lineLimit(1)
        if let n = line.voice, let voice = meeting.voices?.first(where: { $0.number == n }) {
            Menu {
                let names = names(for: meeting)
                ForEach(names, id: \.self) { name in
                    MenuItem(name, name == voice.name ? "checkmark" : "person") { meetings.nameVoice(n, in: id, as: name) }
                }
                if !names.isEmpty { Divider() }
                MenuItem("Other Name…", "pencil") { beginRename(n, from: voice.name) }
                if voice.name != nil {
                    MenuItem("Not Sure", "questionmark.circle") { meetings.nameVoice(n, in: id, as: nil) }
                }
            } label: { label }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.white.opacity(0.4))
            .help("Who's this?")
        } else {
            label
        }
    }

    /// Who a voice could be: the people invited (by first name, as they're spoken to), then
    /// people named in earlier calls.
    private func names(for meeting: MeetingAssistant.Meeting) -> [String] {
        let you = NSFullUserName().split(separator: " ").first.map { $0.lowercased() }
        var seen = Set<String>()
        let invited = (meeting.attendees ?? []).compactMap { $0.split(separator: " ").first.map(String.init) }
        let known = VoicePrints.shared.people.map(\.name)
        return (invited + known).filter { $0.lowercased() != you && seen.insert($0.lowercased()).inserted }.prefix(12).map { $0 }
    }

    private func beginRename(_ number: Int, from name: String?) {
        draft = name ?? ""
        renaming = number
        NotchPresenter.shared.primary?.isEditing = true
        NotchPresenter.shared.primary?.takeKeyFocus()
        // The panel has to be key before the field can take focus.
        DispatchQueue.main.async { naming = true }
    }

    private func endRename(saving: Bool) {
        guard let number = renaming else { return }
        if saving { meetings.nameVoice(number, in: id, as: draft) }
        renaming = nil
        NotchPresenter.shared.primary?.isEditing = false
    }

    /// Naming a voice by hand, in the transcript's header.
    private func renameField(_ number: Int, in meeting: MeetingAssistant.Meeting) -> some View {
        HStack(spacing: 6) {
            Text("Speaker \(number):")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .focused($naming)
                .onSubmit { endRename(saving: true) }
                .onExitCommand { endRename(saving: false) }
                .onChange(of: naming) { _, focused in if !focused { endRename(saving: !draft.isEmpty) } }
            Button { endRename(saving: true) } label: {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(NotchIconButtonStyle(size: 20))
            .help("Name this voice")
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
