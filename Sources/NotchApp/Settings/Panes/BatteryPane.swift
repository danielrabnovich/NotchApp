import SwiftUI

struct BatteryPane: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        SettingsPage(pane: .battery) {
            Section {
                HStack(spacing: 14) {
                    NotchPreviewCard(title: "Charging animation", subtitle: "The level beside the notch when you plug in",
                                     isOn: s.chargingAnimation, notchWidth: 190, action: { s.chargingAnimation.toggle() }) {
                        HStack {
                            Label("Charging", systemImage: "bolt.fill").labelStyle(.titleAndIcon)
                                .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.green)
                            Spacer()
                            Text("64%").font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                        }
                    }
                    Spacer(minLength: 0).frame(maxWidth: .infinity)
                }
                .padding(.vertical, 4)
            }
        }
    }
}
