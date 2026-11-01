import SwiftUI

/// Settings › Controls › Quick actions: the Controls grid as it appears in the notch. Drag tiles
/// to reorder them, drag new ones in from the palette, drag them back out (or ⌫) to remove.
struct ControlsPane: View {
    @EnvironmentObject private var s: AppSettings
    @StateObject private var editor = QuickActionsEditor()
    @State private var origin: CGPoint = .zero

    var body: some View {
        SettingsPage(pane: .controls) {
            Section {
            } footer: {
                FooterText("Dark Mode and Empty Trash ask once for permission to control System Events and Finder.")
            }
            QuickActionsSection(editor: editor)
            Section("Keep Awake") {
                ToggleRow("Let the display sleep", subtitle: "The screen turns off as usual while the Mac itself stays awake (agents, downloads, renders).",
                          isOn: Binding(get: { !s.keepAwakeDisplay }, set: { s.keepAwakeDisplay = !$0 }))
                ToggleRow("Stay awake with the lid closed", subtitle: "Closing the lid normally sleeps your Mac whatever is running. Asks for your password once.",
                          isOn: Binding(get: { s.keepAwakeLidClosed }, set: { KeepAwake.shared.setLidClosed($0) }))
                Picker(selection: $s.keepAwakeBatteryFloor) {
                    Text("Never").tag(0)
                    Text("10%").tag(10)
                    Text("20%").tag(20)
                    Text("30%").tag(30)
                    Text("50%").tag(50)
                } label: {
                    RowLabel(title: "Stop on battery below", subtitle: "So a forgotten session doesn't drain your battery.")
                }
            }
            Section("Camera") {
                ToggleRow("Camera mirror button", subtitle: "A camera button in the notch shows a mirrored preview. The camera only runs while it's open.",
                          isOn: $s.cameraMirrorEnabled)
            }
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
        // A gallery tile being dragged floats above everything, following the pointer.
        .overlay(alignment: .topLeading) {
            if let action = editor.incoming {
                QuickActionDragTile(action: action, landing: editor.incomingTarget != nil)
                    .position(x: editor.location.x - origin.x, y: editor.location.y - origin.y)
                    .allowsHitTesting(false)
            }
        }
    }
}
