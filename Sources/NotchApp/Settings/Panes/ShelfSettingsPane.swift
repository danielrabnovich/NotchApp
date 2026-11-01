import SwiftUI

struct ShelfSettingsPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .shelf) {
            Section {
                if s.shelfEnabled {
                    ToggleRow("Catch new screenshots", subtitle: "New screenshots land on the shelf automatically.", isOn: $s.screenshotCatcher)
                    if s.screenshotCatcher {
                        ToggleRow("Throw screenshots away when done",
                                  subtitle: "15 minutes after you take one, or a minute after you paste it, it moves to the Trash. Pin a screenshot to keep it.",
                                  isOn: $s.screenshotCleanup)
                    }
                    ToggleRow("AirDrop drop zone", isOn: $s.airDropZone)
                    ToggleRow("Copy what you add", subtitle: "The latest thing added to the shelf is also copied, so you can paste it anywhere.", isOn: $s.copyShelfAdds)
                    ToggleRow("Random file names", subtitle: "Files on the shelf go by a made-up name (amber-harbor-27.png) and leave under it when dragged or copied out. The originals keep theirs.",
                              isOn: $s.shelfRandomNames)
                    Picker(selection: $s.shelfDragOut) {
                        ForEach(AppSettings.ShelfDragOut.allCases) { Text($0.label).tag($0) }
                    } label: {
                        RowLabel(title: "Dragging files out",
                                 subtitle: s.shelfRandomNames ? "Always a copy while files go by made-up names."
                                     : s.shelfDragOut == .copy ? "The original stays where it is. Hold ⌘ while dragging to move it instead."
                                     : "Moves the original on the same disk and copies to another, as Finder does. Hold ⌥ to copy.")
                    }
                    .pickerStyle(.segmented)
                    .disabled(s.shelfRandomNames)
                }
            }
            if s.shelfEnabled {
                Section("Quick drops") {
                    ToggleRow("Stack under the notch",
                              subtitle: "Dropped files wait under the notch: drag them straight into another app without opening it. Once dropped, they leave the shelf (hold ⌥ to keep them).",
                              isOn: $s.shelfStack)
                    ToggleRow("Shake to summon a tray while dragging",
                              subtitle: "Shake a file from side to side as you drag it, and a small Shelf appears right at the pointer to drop it in. Gather files from several places there, then drag them all out together.",
                              isOn: $s.shakeTray)
                    Picker(selection: $s.shelfExpiry) {
                        ForEach(AppSettings.ShelfExpiry.allCases) { Text($0.label).tag($0) }
                    } label: {
                        RowLabel(title: "Clear unpinned files",
                                 subtitle: "Pin a file (right-click it on the shelf) to keep it. Only the shelf entry goes; the file itself isn't touched.")
                    }
                }
            }
            if s.shelfEnabled {
                Section {
                    if TaildropService.cli == nil {
                        LabeledContent {
                            Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download/mac")!)
                        } label: {
                            RowLabel(title: "Tailscale isn't installed", subtitle: "Taildrop sends files between your own devices over Tailscale.")
                        }
                    } else {
                        ToggleRow("Taildrop zone", subtitle: "Drop files on it, or click it, to send them to one of your devices.", isOn: $s.taildropZone)
                        ToggleRow("Receive Taildrop files", subtitle: "Files sent to this Mac go to Downloads, with a heads-up in the notch.",
                                  isOn: $s.taildropReceive)
                        if s.taildropReceive {
                            ToggleRow("Put received files on the shelf", isOn: $s.taildropToShelf)
                        }
                    }
                } header: {
                    Text("Taildrop")
                }
                Section {
                    ToggleRow("Clipboard history", subtitle: "Text, links, images and files you copy, next to the shelf. Click one to copy it again.",
                              isOn: $s.clipboardHistory)
                    ToggleRow("Clean copied links", subtitle: "Tracking (utm_…, fbclid, gclid, si…) comes off links as you copy them, and redirect links become where they lead.",
                              isOn: $s.cleanLinks)
                } header: {
                    Text("Clipboard")
                } footer: {
                    FooterText("Kept on this Mac only. Copies from password managers, or marked private by the app they came from, are never saved.")
                }
                Section {
                    if VideoDownloader.isAvailable {
                        LabeledContent {
                            Button("Update yt-dlp") { VideoDownloader.shared.upgrade() }
                        } label: {
                            RowLabel(title: "yt-dlp found", subtitle: (VideoDownloader.binary?.path ?? "") + (VideoDownloader.ffmpeg == nil ? " · install ffmpeg for best quality" : " · with ffmpeg"))
                        }
                        Picker(selection: $s.videoQuality) {
                            Text("Best available").tag(0)
                            Text("4K").tag(2160)
                            Text("1440p").tag(1440)
                            Text("1080p").tag(1080)
                            Text("720p").tag(720)
                            Text("480p").tag(480)
                        } label: {
                            RowLabel(title: "Default quality", subtitle: "For drops and quick downloads; Search and the Save Video menu list every size. Above 1080p is usually AV1 or VP9 (IINA plays both).")
                        }
                        ToggleRow("Put finished videos on the shelf", isOn: $s.videoDownloadsToShelf)
                        ToggleRow("Show progress beside the notch", subtitle: "A ring and percentage while a download runs.",
                                  isOn: $s.downloadLiveActivity)
                    } else {
                        RowLabel(title: "yt-dlp isn't installed", subtitle: "Run “brew install yt-dlp ffmpeg” in Terminal, then reopen Settings.")
                    }
                } header: {
                    Text("Video downloads")
                } footer: {
                    FooterText("Paste a link into Search, drag one onto the notch (hold ⌥ for audio only), or right-click a copied link on the Clipboard shelf. Files go to Downloads.")
                }
                Section {
                    ToggleRow("Put converted files on the shelf", subtitle: "Conversions are saved next to the original either way.",
                              isOn: $s.convertToShelf)
                } header: {
                    Text("Convert")
                } footer: {
                    FooterText(VideoDownloader.ffmpeg == nil
                         ? "Images convert with macOS's own tools. Install ffmpeg (brew install ffmpeg) to convert video and audio."
                         : "Drop files on the Convert bin, or right-click a shelf item. Video and audio use ffmpeg from Homebrew.")
                }
                Section("Downloads") {
                    ToggleRow("Recent downloads", subtitle: "Your latest finished downloads, next to the shelf.", isOn: $s.downloadsEnabled)
                    if s.downloadsEnabled {
                        ToggleRow("Alert when a download finishes", isOn: $s.downloadAlerts)
                    }
                }
            }
        }
    }
}
