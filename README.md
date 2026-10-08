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
- **Timer**: countdown, Pomodoro (focus/short/long breaks, session tracking, auto-advance) and stopwatch with laps; pick a length on a scrollable ruler; live countdown beside the notch and a chime when a phase ends
- **Sound mixer**: per-app volume and mute, system volume and output device. Apps left at 100% are untouched; others are rerouted through a Core Audio process tap (macOS 14.2+, needs the System Audio Recording permission)
- **Notes**: a scratchpad next to Tasks, saved automatically
- **Taildrop**: send files to your Tailscale devices from a Shelf drop zone (or the drag bins), with a device picker and progress; files sent to this Mac are pulled into Downloads and onto the shelf. Uses the CLI bundled with Tailscale.app
- **Controls**: volume and brightness sliders, Wi-Fi, Keep Awake, Dark Mode, mic mute, screenshot, color picker, lock screen, Empty Trash
- **Updates**: Homebrew formulae and casks plus Sparkle apps, checked every six hours; update from the Controls tab
- **Keep Awake**: Amphetamine-style timed sessions, optional display sleep, stops at a battery floor
- **Mouse & trackpad**: reverse mouse-wheel scrolling (trackpad stays natural) and three-finger click as middle click
- **Camera mirror**: a mirrored camera preview from the notch header; the camera only runs while it's open
- **Keyboard shortcuts**: ⌃⌥ (or ⌥⌘ / ⌃⌘) + a letter opens any tab from anywhere; ⌃⌥Space toggles the notch
- **Downloads**: recent finished downloads next to the Shelf, draggable, with a heads-up when one lands
- **Stats**: Stats-style cards for CPU (per-core bars, user/system graph), GPU, memory (app/wired/compressed, pressure) and power, with CPU/GPU temperatures, fan speed and battery time. Reads the SMC, IOReport and IOKit directly; no helper or root needed
- **Search (default tab)**: one search bar that routes automatically: finds files on your Mac from vague descriptions, answers questions from the web (with sources), or shows the weather. Runs in the background and drops down when done
- **Tasks**: drag text, links, emails or files onto the notch to add tasks, natural due dates ("by Friday 3pm"), count badge beside the notch, swipe between tabs
- **Morning brief & nudges**: a short AI-written brief on the first unlock of the day, and "due soon" reminders with Start / Snooze / Done
- **Settings**: per-feature toggles, accent colour, animation style, launch at login

## Local AI (Ollama)

Search, briefs and nudges use a local model through [Ollama](https://ollama.com); nothing is sent to a cloud model. Without a model, search still works: files by name, web results as links, and weather. Results appear as you type, with instant answers for maths, percentages, unit conversions, time zones and day counts, and apps open by name ("open spotify").

```bash
brew install ollama
brew services start ollama
ollama pull qwen3.5:9b   # or gemma4:e4b, llama3.2:3b, or pick one in Settings → Assistant
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
  Services/   media, audio devices, HUD/media keys, battery, shelf, screenshots, calendar, system sensors
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
build/notchdebug expand cpu | timer start|pause|skip|reset | pane notes|downloads | peek timer|download
```

## Notes

- The app is ad-hoc signed. Every rebuild changes its signature, so macOS may ask for Accessibility
  access again (remove the old NotchApp entry in System Settings → Privacy & Security → Accessibility,
  then re-add it).
- Builds are Apple-silicon only; universal builds need full Xcode.
