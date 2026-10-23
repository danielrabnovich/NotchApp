import SwiftUI

/// Settings › Home: what's on Home and in what order, with a live preview, then the settings of
/// what's on it (music, the calendar and meetings, the world clock's city).
struct HomeSettingsPane: View {
    @EnvironmentObject private var s: AppSettings
    @EnvironmentObject private var calendar: CalendarManager
    @ObservedObject private var mixer = AudioMixer.shared

    var body: some View {
        SettingsPage(pane: .home) {
            Section {
                HomePreview()
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                ForEach(s.homeCards, id: \.card) { entry in
                    CardRow(entry: entry)
                }
                .onMove { from, to in withAnimation(.snappy) { s.homeCards.move(fromOffsets: from, toOffset: to) } }
                let missing = HomeCard.allCases.filter { card in !s.homeCards.contains { $0.card == card } }
                if !missing.isEmpty {
                    Menu {
                        ForEach(missing, id: \.self) { card in
                            Button { withAnimation(.snappy) { s.homeCards.append(HomeEntry(card: card)) } } label: {
                                Label(card.isOn(s) ? card.title : "\(card.title) (off)", systemImage: card.icon)
                            }
                        }
                    } label: {
                        Label("Add Card", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button("Edit in the Notch…") {
                    NotchPresenter.shared.primary?.open(tab: .home)
                    HomeEditing.shared.begin()
                }
                .help("Drag cards along Home itself, size them and add more, right where they'll be. Right-click Home for the same.")
            } header: {
                Text("Cards")
            } footer: {
                FooterText("Left to right, in this order; drag to rearrange. Cards size themselves to fit: when there isn't room, the extras shrink, then wait for space (music playing big, a call bar).")
            }
            Section {
                ToggleRow("Music player", subtitle: "Apple Music, Spotify, Podcasts and browsers. Click the artwork to jump to the app.",
                          isOn: Binding(get: { s.musicEnabled }, set: { s.musicEnabled = $0; s.musicLiveActivity = $0 }))
                if s.musicEnabled {
                    ToggleRow("Bigger while playing", subtitle: "The player takes half of Home while music plays; otherwise it stays a small card.",
                              isOn: $s.homeMusicTakesOver)
                    ToggleRow("Live activity while playing", subtitle: "Artwork and a visualizer beside the closed notch.",
                              isOn: $s.musicLiveActivity)
                    ToggleRow("Audio visualizer", subtitle: "Moves with what's actually playing, bass to treble.", isOn: $s.showVisualizer)
                    if s.showVisualizer {
                        PermissionRow(title: "System audio recording",
                                      subtitle: "Lets the visualizer hear the music. It only listens while it's on screen; nothing is recorded or changed. Without it, the bars just animate.",
                                      state: mixer.permission == .granted ? .granted : mixer.permission == .denied ? .denied : .unknown,
                                      request: { mixer.requestPermission() },
                                      openSettings: { AudioCapturePermission.openSettings() })
                    }
                }
            } header: {
                Text("Music")
            }
            Section {
                ToggleRow("Calendar", subtitle: "Today's events on Home, with a countdown, or Join just before a call.", isOn: $s.calendarEnabled)
                if s.calendarEnabled {
                    ToggleRow("Meeting alerts", subtitle: "A heads-up from the notch before each meeting.", isOn: $s.meetingAlerts)
                    if s.meetingAlerts {
                        Stepper(value: $s.meetingAlertMinutes, in: 1...30) {
                            LabeledContent("Alert before") {
                                Text("\(s.meetingAlertMinutes) min").monospacedDigit()
                            }
                        }
                    }
                    ToggleRow("Meeting mode", subtitle: "During a call (Zoom, Teams, FaceTime, Meet in a browser…), its time and a mute button beside the notch; after it, jot notes or a follow-up.",
                              isOn: $s.meetingMode)
                    if s.meetingMode, LiveCaptions.isSupported {
                        ToggleRow("Record calls",
                                  subtitle: "When a call starts, asks whether to record it: both sides kept and turned into text on this Mac, never sent anywhere. Ask “catch me up” during it, hear when someone says your name, and get notes and action items after, with the call to play back from any line. Some places need everyone's consent: tell the people on the call. “Record meeting” in the search bar records one in the room.",
                                  isOn: $s.transcribeCalls)
                    }
                    Picker("Add new events to", selection: $s.defaultCalendarID) {
                        Text("System default").tag("")
                        ForEach(calendar.hasAccess ? calendar.writableCalendars : [], id: \.calendarIdentifier) { cal in
                            Text(cal.title + (cal.source.map { " · \($0.title)" } ?? "")).tag(cal.calendarIdentifier)
                        }
                    }
                    PermissionRow(title: "Calendar", state: calendar.hasAccess ? .granted : .unknown) { calendar.requestAccess() }
                }
            } header: {
                Text("Calendar & meetings")
            } footer: {
                FooterText("In the search bar, type things like “lunch with Sam friday at 1”, “push my 3pm to 4” or “am I free tomorrow afternoon”. Google, Outlook and other calendars work once they're added in System Settings → Internet Accounts.")
            }
        }
    }
}

/// A card on Home: what it is, its size, and a button to take it off.
private struct CardRow: View {
    let entry: HomeEntry
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to rearrange")
            Image(systemName: entry.card.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.gradient))
            RowLabel(title: entry.card.title, subtitle: note ?? entry.card.summary)
            Spacer(minLength: 8)
            if entry.card == .clock {
                Picker("City", selection: Binding(get: { WorldClock.city.id }, set: { s.worldClockCity = $0 })) {
                    ForEach(WorldClock.cities) { city in
                        Text("\(city.name)  \(WorldClock.offset(TimeZone(identifier: city.zone) ?? .current))").tag(city.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if !entry.card.sizes.isEmpty {
                Picker("Size", selection: size) {
                    Text("Auto").tag(HomeCardSize?.none)
                    ForEach(entry.card.sizes, id: \.self) { size in
                        Text(entry.card.name(size)).tag(HomeCardSize?.some(size))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("\(entry.card.title) size")
                .help("Auto fits it to the room; a size set here is kept, and other cards make room for it.")
            }
            Button {
                withAnimation(.snappy) { s.homeCards.removeAll { $0.card == entry.card } }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Take it off Home")
            .accessibilityLabel("Remove \(entry.card.title) from Home")
        }
        .contextMenu {
            Button("Move Left") { move(by: -1) }.disabled(index == 0)
            Button("Move Right") { move(by: 1) }.disabled(index == s.homeCards.count - 1)
            Divider()
            Button("Remove from Home") { s.homeCards.removeAll { $0.card == entry.card } }
        }
    }

    /// Why it might not show, when it's something the user can fix.
    private var note: String? {
        entry.card.isOn(s) ? nil : "Off: \(entry.card.featureHint.prefix(1).lowercased() + entry.card.featureHint.dropFirst()) to show it."
    }

    private var index: Int { s.homeCards.firstIndex(of: entry) ?? 0 }

    private func move(by offset: Int) {
        let to = index + offset
        guard s.homeCards.indices.contains(to) else { return }
        withAnimation(.snappy) { s.homeCards.swapAt(index, to) }
    }

    private var size: Binding<HomeCardSize?> {
        Binding(get: { entry.size }, set: { size in
            guard let i = s.homeCards.firstIndex(where: { $0.card == entry.card }) else { return }
            s.homeCards[i].size = size
        })
    }
}

/// Home as it is right now, drawn like the open notch and scaled to fit the page. Changes to the
/// cards show here as they're made.
private struct HomePreview: View {
    /// The open notch's Home: 680 points wide, less its insets.
    private let size = CGSize(width: 644, height: 144)
    private let inset: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let scale = min(1, geo.size.width / (size.width + 2 * inset))
            HomeView()
                .frame(width: size.width, height: size.height)
                .foregroundStyle(.white)
                .padding(inset)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black))
                .environment(\.colorScheme, .dark)
                .notchEnvironment()
                .allowsHitTesting(false)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, alignment: .leading)
        }
        .aspectRatio((size.width + 2 * inset) / (size.height + 2 * inset), contentMode: .fit)
    }
}
