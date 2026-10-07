# NotchApp

A Boring Notch–style app that turns the MacBook notch into a live, interactive hub.

## Build & run

No Xcode needed — Command Line Tools are enough.

```bash
./build.sh            # builds build/NotchApp.app
./build.sh install    # also copies to /Applications and launches it
```

## Features

- **Notch shell**: black shape that blends into the notch, spring open/close, hover (adjustable delay) or click to open, Home / Shelf tabs, fake notch on displays without one
- **Music**: album art, title/artist, play/pause/next/previous, scrubbable progress, visualizer tinted to the artwork, live activity beside the notch, audio output switcher. Works with Music, Spotify, Podcasts, and browsers
- **HUD**: volume and brightness shown in the notch instead of the system overlay (needs Accessibility access)
- **Battery**: charging animation and percentage when you plug in
- **Shelf**: drag files onto the notch, drag them back out, AirDrop drop zone, automatic screenshot catching
- **Calendar**: today's events plus a heads-up a few minutes before each meeting
- **Search (default tab)**: one search bar that routes automatically: finds files on your Mac from vague descriptions, answers questions from the web (with sources), or shows the weather. Runs in the background and drops down when done
- **Tasks**: drag text, links, emails or files onto the notch to add tasks, natural due dates ("by Friday 3pm"), count badge beside the notch, swipe between tabs
- **Morning brief & nudges**: a short AI-written brief on the first unlock of the day, and "due soon" reminders with Start / Snooze / Done
- **Settings**: per-feature toggles, accent colour, animation style, launch at login

## Local AI (Ollama)

Search, briefs and nudges use a local model through [Ollama](https://ollama.com); nothing is sent to a cloud model.

```bash
brew install ollama
brew services start ollama
ollama pull qwen3:8b
```

Web search sends only the query to Brave Search (falling back to DuckDuckGo, then Bing) and fetches the top pages.
Weather comes from Open-Meteo.

## How "Now Playing" works on macOS 15.4+

Apple restricted the private MediaRemote framework to entitled processes. `MediaAdapter/` holds a
tiny Objective-C dylib that `/usr/bin/perl` (still entitled) loads and uses to stream now-playing JSON
back to the app. This is the same approach Boring Notch uses.

## Layout

```
Sources/NotchApp/
  App/        entry point, app delegate, debug hooks
  Notch/      panel window, geometry, mouse tracking, per-screen view model
  Views/      SwiftUI views (collapsed activities, open panel, music, calendar, shelf)
  Services/   media, audio devices, HUD/media keys, battery, shelf, screenshots, calendar
  Settings/   preferences model + settings window
MediaAdapter/ MediaRemote bridge (ObjC + perl loader)
scripts/      icon generator, debug command sender
```

## Debugging

```bash
defaults write com.notchapp.NotchApp debugHooks -bool YES   # then relaunch
swiftc scripts/debug.swift -o build/notchdebug
build/notchdebug pin; build/notchdebug open home; build/notchdebug snapshot /tmp/notch.png
build/notchdebug volume 0.5 | brightness 0.3 | charging | meeting | screenshot | fakeplay | close
```

## Notes

- The app is ad-hoc signed. Every rebuild changes its signature, so macOS may ask for Accessibility
  access again (remove the old NotchApp entry in System Settings → Privacy & Security → Accessibility,
  then re-add it).
- Builds are Apple-silicon only; universal builds need full Xcode.
