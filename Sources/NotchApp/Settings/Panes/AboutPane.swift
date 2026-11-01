import AppKit
import SwiftUI

struct AboutPane: View {
    @ObservedObject private var updater = AppUpdater.shared
    @State private var crashes = CrashReports.all().prefix(5).map { $0 }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                    .padding(.top, 48)
                Text("NotchApp")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.top, 14)
                Text("Your notch, but useful.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text(version)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                updateStatus.padding(.top, 18)

                VStack(alignment: .leading, spacing: 18) {
                    if !crashes.isEmpty { crashList }
                }
                .frame(maxWidth: 520)
                .padding(.top, 30)

                Button("Quit NotchApp") { NSApp.terminate(nil) }
                    .controlSize(.large)
                    .padding(.vertical, 28)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .idle, .upToDate, .failed:
            VStack(spacing: 6) {
                Button("Check for Updates") { updater.check() }
                    .controlSize(.large)
                Group {
                    if case .upToDate = updater.state {
                        Label("You're up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if case .failed(let message) = updater.state {
                        Text(message).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 420)
                    } else if let last = updater.lastChecked {
                        Text("Checked \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
            }
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
        case .available(let release):
            VStack(spacing: 8) {
                Text("NotchApp \(release.version) is available").font(.headline)
                if !release.notes.isEmpty {
                    Text(release.notes).font(.caption).foregroundStyle(.secondary).lineLimit(6).frame(maxWidth: 420)
                }
                Button("Install & Restart") { updater.install() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .installing(let stage):
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(stage).foregroundStyle(.secondary) }
        }
    }

    /// Recent crashes: a summary to copy (for a bug report), or the full report.
    private var crashList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Crash reports").font(.headline)
            Text("Kept on this Mac. Copy a summary to report a problem.").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(crashes.enumerated()), id: \.element.id) { i, report in
                    HStack {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(report.date.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Button("Copy Summary") { CrashReports.copySummary(report) }.buttonStyle(.borderless)
                        Button("Show") { CrashReports.reveal(report) }.buttonStyle(.borderless)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    if i < crashes.count - 1 { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }
}
