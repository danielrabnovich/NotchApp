import AppKit
import Combine
import SwiftUI

struct MousePane: View {
    @EnvironmentObject private var s: AppSettings
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsPage(pane: .mouse) {
            Section {
                ToggleRow("Reverse mouse wheel scrolling",
                          subtitle: "Scroll a mouse wheel the traditional way while the trackpad keeps natural scrolling. Magic Mouse counts as a trackpad.",
                          isOn: $s.reverseMouseScroll)
                ToggleRow("Three-finger click for middle click",
                          subtitle: "Click the trackpad with three fingers to open links in new tabs, close tabs, paste in Terminal…",
                          isOn: $s.threeFingerMiddleClick)
            }
            Section("Permission") {
                PermissionRow(title: "Accessibility", subtitle: trusted ? nil : "Needed to adjust scroll and click events.",
                              state: trusted ? .granted : .unknown) {
                    HUDController.shared.requestAccessibility()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
    }
}
