import SwiftUI

/// A settings page: a header with the pane's icon, title and summary, then grouped sections.
struct SettingsPage<Content: View>: View {
    let pane: SettingsPane
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            PaneHeader(pane: pane)
                .padding(.horizontal, 30)
                .padding(.top, 18)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

struct PaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(pane: pane, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(pane.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }

    }
}

/// The rounded, tinted icon tile used in the sidebar and page headers.
struct SettingsIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: pane.icon)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [pane.tint.opacity(0.95), pane.tint.opacity(0.75)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: pane.tint.opacity(0.25), radius: size * 0.08, y: size * 0.04)
    }
}

/// A toggle with a one-line explanation under its title.
struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            RowLabel(title: title, subtitle: subtitle)
        }
    }
}

struct RowLabel: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A macOS permission with its state: an "Allowed" pill, or a button to grant it.
struct PermissionRow: View {
    enum State { case granted, denied, unknown }

    let title: String
    var subtitle: String? = nil
    let state: State
    let request: () -> Void
    var openSettings: (() -> Void)? = nil

    var body: some View {
        LabeledContent {
            switch state {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.green.opacity(0.14)))
            case .denied:
                Button("Open System Settings…") { (openSettings ?? request)() }
            case .unknown:
                Button("Allow…", action: request)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: state == .granted ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(state == .granted ? Color.secondary : Color.orange)
                    .frame(width: 16)
                RowLabel(title: title, subtitle: subtitle)
            }
        }
    }
}
