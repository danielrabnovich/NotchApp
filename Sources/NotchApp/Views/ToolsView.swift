import SwiftUI
import UniformTypeIdentifiers

enum ToolsPane: String {
    case network, vpn, cleaner, devices, cables
    static let options: [(value: ToolsPane, title: String)] = [(.network, "Network"), (.vpn, "VPN"), (.cleaner, "Cleaner"), (.devices, "Devices"), (.cables, "Cables")]
}

/// Tools tab: network (live traffic, connection details, speed test), a cleaner with an app
/// uninstaller, and Bluetooth battery levels.
struct ToolsView: View {
    @ObservedObject var viewModel: NotchViewModel
    @AppStorage("tools.pane") private var pane: ToolsPane = .network

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PaneSwitcher(selection: $pane, options: ToolsPane.options)
                Spacer()
                PaneAccessory(pane: pane)
            }
            .notchHeaderRow()
            // Exactly the room under the switcher, whatever the pane: a pane a few points too tall
            // used to push the whole page up, so the switcher jumped between panes.
            PaneArea {
                PaneSlide(selection: pane, order: ToolsPane.options.map(\.value)) {
                    switch pane {
                    case .network: NetworkPane()
                    case .vpn: VPNPane()
                    case .cleaner: CleanerPane()
                    case .devices: DevicesPane()
                    case .cables: CablesPane()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Takes the size it's offered and puts its content at the top, so content that runs taller is cut
/// off at the bottom rather than growing the page (which centres it, moving everything up).
private struct PaneArea: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// The small actions at the right of the pane switcher.
private struct PaneAccessory: View {
    let pane: ToolsPane
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var cleaner: Cleaner
    @EnvironmentObject private var uninstaller: AppUninstaller
    @EnvironmentObject private var devices: DeviceBatteries
    @EnvironmentObject private var vpn: VPNMonitor

    var body: some View {
        switch pane {
        case .vpn:
            TextButton(vpn.loading ? "Checking…" : "Refresh") { vpn.refresh(exitInfo: true) }
        case .network:
            TextButton(network.pinging ? "Checking…" : "Refresh") { network.refreshDetails(force: true) }
                .disabled(network.pinging)
        case .cleaner:
            if uninstaller.target == nil {
                HStack(spacing: 12) {
                    if let scanned = cleaner.scanned, !cleaner.scanning {
                        Text("Scanned " + scanned.formatted(.relative(presentation: .named)))
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    }
                    TextButton(cleaner.scanning ? "Scanning…" : "Rescan") { cleaner.scan() }
                        .disabled(cleaner.scanning || cleaner.cleaning)
                }
            }
        case .devices:
            TextButton("Refresh") { devices.refresh() }
        case .cables:
            TextButton("Refresh") { CableMonitor.shared.refresh() }
        }
    }
}

private struct TextButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
    }
}

enum ToolsPalette {
    static let down = Color(red: 0.32, green: 0.72, blue: 1)
    static let up = Color(red: 0.98, green: 0.55, blue: 0.3)
    static let good = Color(red: 0.4, green: 0.88, blue: 0.55)
}
