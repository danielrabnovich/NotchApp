import SwiftUI
import UniformTypeIdentifiers

// MARK: - Cables

/// The cable test: for each USB-C port with something on it, what the cable's chip says it's rated
/// for beside what's really happening (the device, the power, the link), and a line on whether the
/// two agree.
struct CablesPane: View {
    @EnvironmentObject private var cables: CableMonitor

    var body: some View {
        Group {
            if cables.ports.isEmpty {
                Card {
                    VStack(spacing: 6) {
                        Image(systemName: "cable.connector").font(.system(size: 20))
                        Text("Plug a USB-C cable into the Mac with a charger, phone or drive on the other end")
                            .font(.system(size: 11)).multilineTextAlignment(.center)
                        Text("Its chip says what it's rated for; the link shows what it really does.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if cables.ports.count == 1, let port = cables.ports.first {
                CablePortView(port: port, showsName: false)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(Array(cables.ports.enumerated()), id: \.element.id) { i, port in
                            if i > 0 { SectionDivider() }
                            CablePortView(port: port, showsName: cables.ports.count > 1)
                        }
                    }
                }
                .scrollEdgeFade()
            }
        }
        .padding(.top, 4)
        .onAppear { cables.refresh() }
    }
}

private struct CablePortView: View {
    let port: CableMonitor.Port
    let showsName: Bool

    private let warn = Color(red: 1, green: 0.62, blue: 0.3)

    // Three short columns, as the pane is wide and only a few rows tall: the cable and the
    // verdict, what its chip says in full, and what's happening over it now.
    var body: some View {
        HStack(spacing: 18) {
            summary.frame(width: 200)
            SectionDivider()
            rated.frame(width: 172)
            SectionDivider()
            // Alone it takes the rest of the pane; beside other ports, a column like theirs.
            if showsName { now.frame(width: 180) } else { now.frame(maxWidth: .infinity) }
        }
    }

    private var summary: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                CardTitle(title: showsName ? "\(port.name) · Cable" : "Cable", icon: "cable.connector", tint: .white.opacity(0.8))
                if let cable = port.cable {
                    Text(cable.headline).font(.system(size: 18, weight: .semibold).monospacedDigit())
                    Text([cable.kind, cable.lengthLabel, cable.maker].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                } else if port.talkedPD {
                    Text("Basic cable").font(.system(size: 18, weight: .semibold))
                    Text("No chip: 3 A (60 W) at most, USB 2 speed")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                } else {
                    Text("Reading…").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    Text("Read once the far end talks to the Mac")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 2)
                if port.partner != nil { verdict }
            }
            .lineLimit(1)
        }
    }

    /// Everything the cable's chip claims.
    private var rated: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                CardTitle(title: "Rated for", icon: "checkmark.seal", tint: .white.opacity(0.8))
                if let cable = port.cable {
                    InfoRow(label: "Power", value: "\(cable.amps) A · \(cable.maxVolts) V" + (cable.epr ? " · EPR" : ""),
                            help: cable.epr ? "Extended Power Range: it can carry 48 V, for 140–240 W chargers" : "Up to 20 V: 100 W at most")
                    InfoRow(label: "Data", value: CableMonitor.speedDetail(cable.speed).components(separatedBy: " · ").last ?? "",
                            help: CableMonitor.speedDetail(cable.speed))
                    InfoRow(label: "Certified", value: cable.certified ? "USB-IF #\(cable.xid)" : "No",
                            copyable: String(format: "%04X:%04X", cable.vendorID, cable.productID),
                            help: (cable.certified ? "Tested and listed by the USB Implementers Forum" : "Never certified: its claims are the maker's word")
                                + String(format: "\nUSB vendor 0x%04X, product 0x%04X · click to copy", cable.vendorID, cable.productID),
                            tint: cable.certified ? ToolsPalette.good : warn)
                } else {
                    Text(port.talkedPD ? "A cable without a chip can't say what it's rated for." : "Nothing read yet.")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What's actually happening over it.
    private var now: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                CardTitle(title: "Right now", icon: port.partner?.isCharger == true ? "bolt.fill" : "arrow.left.arrow.right",
                          tint: .white.opacity(0.8))
                InfoRow(label: "Connected to", value: port.partner?.name ?? "Nothing yet")
                if let link = port.link {
                    InfoRow(label: "Data", value: "\(link.kind) · \(link.label)", tint: port.slowLink ? warn : .white.opacity(0.85))
                }
                if let power = port.power {
                    InfoRow(label: "Power in", value: power.label, help: power.detail)
                }
            }
        }
    }

    private var verdict: some View {
        let bad = port.slowLink
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(bad ? warn : ToolsPalette.good)
            Text(CableMonitor.verdict(port))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
