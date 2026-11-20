import SwiftUI

struct StatsPane: View {
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var live = LiveActivities.shared

    var body: some View {
        SettingsPage(pane: .stats) {
            Section {
                ChoiceRow("Temperature", selection: $s.useFahrenheit, options: [false, true], title: { $0 ? "Fahrenheit" : "Celsius" })
            }
            Section {
                ForEach([LiveItem.cpu, .memory, .gpu, .temperature, .power], id: \.self) { item in
                    Toggle(isOn: Binding(get: { live.slot(for: item) != nil },
                                         set: { $0 ? live.pin(item) : live.unpin(item) })) {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(item.tint.gradient))
                            RowLabel(title: item.title, subtitle: item.detail, shown: true)
                        }
                    }
                    .disabled(live.slot(for: item) == nil && live.isFull(.left) && live.isFull(.right))
                }
            } header: {
                Text("Beside the notch")
            } footer: {
                HStack(spacing: 4) {
                    FooterText("Readings stay in view while the notch is closed; click one for its card.")
                    Button("Arrange Glances…") { SettingsRouter.shared.pane = .live }
                        .buttonStyle(.link)
                        .font(.caption)
                        .fixedSize()
                }
            }
        }
    }
}
