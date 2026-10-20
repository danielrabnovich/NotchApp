# NotchApp guide

This is what Search reads when someone asks about NotchApp itself ("what can you do", "how do I…",
"where's the setting for…"). Each `## Heading {pane}` is one topic; `{pane}` links it to that page of
Settings (the SettingsPane case name). Settings pages and the changelog are added automatically at
build time, so this file only needs what they can't say: how things fit together and how to use them.

## What NotchApp is
NotchApp turns the MacBook notch into a small control centre. Hover over the notch (or click it, or press the open shortcut) and it opens into a panel with tabs. Out of the box there are three: Search, Shelf and Tasks. Everything else (Home with music and calendar, Timer, Mixer, Controls, Stats, Tools, Agents) is an add-on you switch on in Settings → Add-ons. On displays without a notch, NotchApp draws one.

## What it can do (overview)
- Search: one bar that finds files on your Mac (by name, by what's in them, even by what a picture shows), answers questions from the web, gives the weather, reads your calendar, notes and tasks, carries out actions ("timer 10m", "add lunch with Sam friday 1pm", "dark mode on"), answers questions about what's on your screen, and does things in the app in front of you.
- Shelf: drag files onto the notch to park them, then drag them out into any app. Screenshots and downloads land there too; AirDrop and Taildrop zones send files on.
- Tasks & Notes: a to-do list with reminders and a scratchpad. Drop text, links or emails on the notch to make tasks.
- Glances: small live readouts beside the closed notch (music, timer, battery, clocks, stats…).
- Volume, brightness and charging shown in the notch instead of macOS's overlays.
- Add-ons: music player with visualizer, calendar with meeting alerts, timer and Pomodoro, per-app volume mixer, quick controls and camera mirror, system stats, network tools and a cleaner, coding-agent monitor.
- Clipboard history, live captions, Ramble (talk it out, get tasks back), meeting mode, Shortcuts and Siri actions.

## Opening the notch {general}
Hover the pointer over the notch: it opens after a short delay (set the delay, or switch to opening on click, in Settings → General → Opening). The keyboard shortcut ⌃⌥Space opens or closes it from anywhere (change it in Settings → Keyboard Shortcuts). With "Ready to type when it opens" on, the cursor is already in the search bar, so you can hover and start typing. Move the pointer away, or press Esc, to close it.

## Switching tabs {addOns}
Click a tab icon along the top of the open notch, swipe left or right with two fingers on the trackpad, or use the tab's shortcut (⌃⌥ plus a letter: G Search, M Home, F Shelf, T Tasks, R Timer, V Mixer, C Controls, I Stats, O Tools, A Agents). Which tabs appear is set in Settings → Add-ons.

## Search basics {assistant}
Type in the search bar and press Return. Search works out what you mean and goes to the right place: your files, the web, the weather, your calendar, your notes and tasks, an action, or your screen. Results as you type show apps, files and quick answers (math, unit and currency conversion, dates). Use ↑↓ to move through results, Return to open, ⌘Y to preview a file. "Search the web instead" / "Search my files instead" under a result switches. The glow around the search bar can be Apple Intelligence's colours, a white shimmer along its edge, or nothing: Settings → Appearance → Search bar. Without an AI model, Search still finds files by name, shows web links and the weather; a model adds written answers, smarter file finding and actions.

## Setting up AI (models) {assistant}
Settings → Search → Intelligence chooses the model. "On this Mac" uses Ollama: install it (brew install ollama), and NotchApp can start it and download a model for you; everything stays on your Mac. You can instead add your own key for a cloud model (Anthropic, OpenAI-compatible, DeepSeek, Z.ai…), which is smarter but sends what you ask to that provider. On macOS 26 with Apple Intelligence, Apple's on-device model needs no setup. If answers fail with "Couldn't reach Ollama", start it from Settings → Search, or run `ollama serve`.

## Finding files {assistant}
Describe the file the way you remember it: "my resume", "the marketing slides from last week", "the pdf Sarah sent", "screenshot of the receipt", "a photo of a dog on a beach". Search looks through your home folder, ranks what it finds and explains why. Long searches keep going in the background and tell you when they're done. For picture contents, turn on "Search inside pictures" and "Search the text in screenshots" in Settings → Search → Files & folders. If it can't see Desktop, Documents or Downloads, allow folder access there too.

## Web answers {assistant}
Ask a question ("who won the game last night", "best ramen near UNC", "how to undo a git commit"): Search looks it up, reads the top pages and writes a short answer with numbered sources. Click a source to open it, or save the answer or a link to the Shelf with the tray button.

## Actions from the search bar {assistant}
Type what you want done: "timer 10 minutes", "pomodoro", "remind me to call mom tomorrow at 5", "add lunch with Sam friday 1pm", "move my 3pm to 4", "cancel tomorrow's standup", "volume 40", "dark mode on", "lock screen", "open Spotify", "skip this song", "jot down the door code is 4471". One safe action just happens with Undo; several, or moving and deleting events, are shown for you to confirm first. Type "/" to see every command.

## Command bar {assistant}
The search bar doubles as a command bar: type a setting's name to flip it ("haptics", "shadow off") or open its page, "translate … to Spanish", "define serendipity", web shortcuts ("yt lofi", "gh notchapp"), power commands (sleep, restart, lock), and window layouts ("left half", "maximize"). Menu items of the app in front show up too.

## Calendar questions {calendar}
Ask "what's on today", "am I free friday at 3", "when is my dentist appointment" or "next meeting": answers come from your real calendars (iCloud, Google, Exchange and others added in System Settings → Internet Accounts). Adding, moving and cancelling events works from the search bar too. Pick which calendar new events go to in Settings → Calendar & Meetings → Search bar.

## Questions about your screen {assistant}
Ask "what's the right answer to this question", "explain this error", "summarize this page" or "what am I looking at": NotchApp captures the screen behind the notch (in memory only, never saved), reads its text and answers, searching the web when it needs facts. Press ⌃⌥S ("Ask about this") to capture the window in front first and then ask about it. Needs Screen Recording permission (System Settings → Privacy & Security → Screen & System Audio Recording; it's a different list from Accessibility). Turn it off in Settings → Search → Your screen.

## Doing things in the app in front {assistant}
Type an instruction for the app you're using ("export as pdf", "new private window", "zoom in", "bold"): NotchApp looks through that app's own menus and runs the best match, or shows a few to choose from. It needs Accessibility permission. If nothing in the app's menus matches, Search treats it as a normal search.

## AI Commands {assistant}
Saved prompts you run on selected or copied text ("Fix grammar", "Summarize", "Make it shorter"), from the search bar or their own shortcuts. Add and edit them in Settings → Search → AI Commands; right-click one, or ⌥-click it, to add instructions for that run.

## The Shelf {shelf}
Drag any file onto the notch and drop it on Shelf to park it; drag it out again into any app (mail, chat, Finder). Files you drop wait in a stack under the closed notch so you can drag them straight on; pin a file (right-click it) to keep it on the Shelf. Whatever you add is also copied, so you can paste it right away ("Copy what you add"). Drop on AirDrop to send to a nearby device, or on Taildrop to send to your own devices over Tailscale. Unpinned files clear after an hour by default (Settings → Shelf → Quick drops).

## Screenshots {shelf}
New screenshots land on the Shelf and on the clipboard automatically, so you can take one and paste it straight away. Turn this off with "Catch new screenshots" in Settings → Shelf. "Throw screenshots away when done" moves them to the Trash 15 minutes after you take them or a minute after you paste them, unless pinned. Search can also find old screenshots by the text in them.

## Clipboard history {shelf}
Text, links, images and files you copy are kept next to the Shelf (Settings → Shelf → Clipboard). Click one to copy it again; copied colours show as swatches. Copies from password managers, or marked private, are never saved. "Clean copied links" strips tracking from links as you copy them.

## Tasks and notes {tasks}
The Tasks tab is a to-do list: add a task by typing, by dropping text, a link or an email on the notch, or from the search bar ("remind me to…"). Due dates in plain words work ("friday", "tomorrow 3pm"). Swipe or click to complete. A morning brief and due-soon nudges drop down from the notch when tasks are due (Settings → Tasks & Notes → Reminders). Notes is a scratchpad for quick text.

## Ramble {tasks}
Press ⌃⌥J and talk (or type) everything on your mind; Ramble turns it into tasks, calendar events and a note for you to review. Dictation runs on this Mac.

## Glances {live}
Glances are small live readouts beside the closed notch: now playing, a timer or countdown, battery, a world clock, weather, CPU and memory rings, Focus, downloads in progress, unread counts and more. Rest the pointer on one for details. Choose which ones show, and which pop up by themselves, in Settings → Glances.

## Music and sound {media}
With the Music add-on on, Home shows what's playing in Music, Spotify or a browser, with album art, controls, a scrubbable progress bar and a visualizer, and you can switch the audio output. The Mixer tab sets each app's volume separately. Settings → Media & Sound.

## Volume, brightness and charging {hud}
Volume and brightness changes show in the notch instead of macOS's overlay (Settings → Volume & Brightness; needs Accessibility so the keys can be caught). Plugging in shows a charging animation (Settings → Battery).

## Timer and Pomodoro {timer}
The Timer tab has countdowns, Pomodoro and a stopwatch: drag or scroll the ruler, use ← → to set it and Space to start and pause, or type "timer 25m" in Search. A running timer shows beside the notch.

## Meetings {calendar}
A heads-up drops down before meetings, with a Join button for Zoom, Meet and Teams links. Meeting mode adds a call timer and mute button beside the notch during calls, and can transcribe the call on this Mac for notes and action items afterwards. Settings → Calendar & Meetings.

## Controls, Keep Awake and camera {controls}
The Controls tab holds the quick actions you pick: toggles (dark mode, Wi-Fi, mic, Night Shift), a port viewer, speed test, copy text from the screen, colour picker. Keep Awake stops the Mac sleeping, optionally with the display off or the lid closed. The camera mirror shows a preview of yourself before a call. Settings → Controls & Camera.

## Stats, tools and agents {stats}
Stats shows CPU, GPU, memory, temperatures and where the power goes. Tools has network info and a speed test, a cleaner, an app uninstaller and Bluetooth device batteries (Settings → Tools). Agents follows Claude Code, Codex and other coding-agent sessions, tells you when one is waiting, and lets you reply from the notch (Settings → Agents).

## Keyboard shortcuts {shortcuts}
Every tab and many actions have a shortcut, by default ⌃⌥ (Control-Option) plus a key. Change the shared modifier keys, rebind any shortcut or turn one off in Settings → Keyboard Shortcuts. If a shortcut doesn't work, another app may already use it: Settings shows which ones couldn't be registered.

## Permissions {permissions}
Settings → Permissions lists what NotchApp can use and what each permission unlocks: Accessibility (media keys, menus, in-app actions), Screen Recording (questions about your screen), Calendars, Contacts (birthdays), Microphone (captions, Ramble), Location (when to leave), and Files & Folders. Each one is asked for the first time its feature needs it. Builds signed without a developer certificate are seen by macOS as a new app after every rebuild, so permissions may need switching on again; remove the old NotchApp entry with − and add the app again if a switch looks on but doesn't work.

## Shortcuts and Siri
NotchApp's actions are in the Shortcuts app and Siri: start timers, add tasks, put files on the Shelf, show banners, captions and Glances. Your own shortcuts can run from the search bar and as Glance tiles.

## Privacy
Everything runs on your Mac unless you choose a cloud model. Web searches send only the search words. Screen questions capture the screen in memory and never save it; with a local model the picture never leaves the Mac. Clipboard history and transcripts are kept on this Mac only.

## Troubleshooting
- "Couldn't reach Ollama": start Ollama from Settings → Search, or run `ollama serve`, and check a model is downloaded.
- "Structured output is unavailable": that model can't use JSON mode; NotchApp now asks for JSON in the prompt instead, so it should work after an update.
- A permission is on but the feature says it isn't: macOS may be holding the switch for an older build. Remove NotchApp from that list in System Settings and add it again, then reopen NotchApp.
- Search can't see a folder: allow Desktop, Documents and Downloads in Settings → Search → Files & folders.
- The notch doesn't open on an external display: turn on the fake notch in Settings → General → Displays.
- Something crashed: Settings → About shows recent crash reports you can read and share.
