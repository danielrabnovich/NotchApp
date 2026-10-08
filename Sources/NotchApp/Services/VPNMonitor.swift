import AppKit
import Network
import SystemConfiguration
import SwiftUI

/// Every VPN on this Mac and how it's connected: status, server, tunnel address, protocol, DNS,
/// full or split tunnel, and where your traffic exits. Works with any VPN app that installs a
/// system VPN profile (Proton VPN, Tailscale, NordVPN, WireGuard…), plus the command-line tools
/// of PIA (`piactl`) and Mullvad (`mullvad`) for their extra details.
@MainActor
final class VPNMonitor: ObservableObject {
    static let shared = VPNMonitor()

    struct Connection: Identifiable, Equatable {
        enum Status: Equatable {
            case connected, connecting, disconnecting, disconnected, invalid
            var label: String {
                switch self {
                case .connected: "Connected"
                case .connecting: "Connecting…"
                case .disconnecting: "Disconnecting…"
                case .disconnected: "Off"
                case .invalid: "Unavailable"
                }
            }
        }

        let id: String
        var name: String
        var status: Status
        var since: Date?
        var interface: String?
        var tunnelAddresses: [String] = []
        var server: String?
        var dns: [String] = []
        /// All traffic goes through it (not just some networks).
        var fullTunnel = false
        var protocolName: String?
        /// The VPN app, for Open and its icon.
        var appURL: URL?
        /// Where the details came from: a system profile, or the PIA / Mullvad tools.
        var source: Source = .system

        enum Source: Equatable { case system, pia, mullvad, tunnel }

        var isUp: Bool { status == .connected }
    }

    struct Exit: Equatable {
        let ip: String
        var city: String?
        var region: String?
        var country: String?
        var countryCode: String?
        /// ISP or hosting company ("Proton AG", "M247").
        var org: String?

        var place: String { [city, country].compactMap { $0 }.joined(separator: ", ") }

        var flag: String {
            guard let code = countryCode?.uppercased(), code.count == 2 else { return "" }
            return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
        }
    }

    struct Extra: Equatable {
        var region: String?
        var portForward: String?
        var publicIP: String?
    }

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var exit: Exit?
    @Published private(set) var extras: [String: Extra] = [:]
    @Published private(set) var loading = false

    private var exitFetched: Date?
    private var exitKey = ""

    private init() {}

    /// The VPN carrying traffic right now, if any (full tunnel first).
    var active: Connection? {
        connections.filter(\.isUp).sorted { ($0.fullTunnel ? 0 : 1) < ($1.fullTunnel ? 0 : 1) }.first
    }

    var anyUp: Bool { connections.contains { $0.isUp } }

    // MARK: - Refresh

    func refresh(exitInfo: Bool = false) {
        loading = true
        Task {
            var found = await Task.detached { Self.systemConnections() }.value
            let tools = await Self.toolConnections()
            for c in tools where !found.contains(where: { $0.interface != nil && $0.interface == c.interface }) { found.append(c) }
            // A tunnel carrying the default route that no profile or tool claims (OpenVPN, wg-quick…).
            if let orphan = Self.unclaimedTunnel(claimed: Set(found.compactMap(\.interface))) { found.append(orphan) }
            let sorted = found.sorted { ($0.isUp ? 0 : 1, $0.name) < ($1.isUp ? 0 : 1, $1.name) }
            if sorted != connections { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { connections = sorted } }
            loading = false
            // Where traffic exits changes with the VPN; ask again when it does (or when asked to).
            let key = sorted.filter(\.isUp).map { $0.id + ($0.server ?? "") }.joined()
            let stale = exitFetched.map { Date().timeIntervalSince($0) > 300 } ?? true
            if exitInfo || key != exitKey || (stale && exit != nil) {
                exitKey = key
                await refreshExit()
            }
        }
    }

    /// Re-asks where traffic exits, unless that was just checked.
    func refreshExit(ifOlderThan seconds: TimeInterval = 0) async {
        if let fetched = exitFetched, Date().timeIntervalSince(fetched) < seconds { return }
        exitFetched = Date()
        exit = await Self.fetchExit()
    }

    // MARK: - System VPN profiles

    nonisolated private static func systemConnections() -> [Connection] {
        guard let prefs = SCPreferencesCreate(nil, "NotchApp" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return [] }
        let primary = (SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["PrimaryInterface"] as? String
        return services.compactMap { service -> Connection? in
            guard SCNetworkServiceGetEnabled(service),
                  let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  ["VPN", "IPSec", "PPP", "L2TP"].contains(type),
                  let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
            let name = SCNetworkServiceGetName(service) as String? ?? "VPN"
            let config = SCNetworkInterfaceGetConfiguration(interface) as? [String: Any] ?? [:]
            let provider = config["NEProviderBundleIdentifier"] as? String ?? config["VPNType"] as? String
            var c = Connection(id: id, name: name, status: .disconnected)
            c.protocolName = protocolName(type: type, provider: provider, name: name)
            c.appURL = appURL(forProvider: provider) ?? appURL(named: name)
            c.server = (config["RemoteAddress"] as? String).flatMap { $0 == "127.0.0.1" ? nil : $0 }

            guard let connection = SCNetworkConnectionCreateWithServiceID(nil, id as CFString, nil, nil) else { return c }
            c.status = switch SCNetworkConnectionGetStatus(connection) {
            case .connected: .connected
            case .connecting: .connecting
            case .disconnecting: .disconnecting
            case .disconnected: .disconnected
            default: .invalid
            }
            guard c.status == .connected, let status = SCNetworkConnectionCopyExtendedStatus(connection) as? [String: Any] else { return c }
            if let ipv4 = status["IPv4"] as? [String: Any] {
                c.interface = ipv4["InterfaceName"] as? String
                c.tunnelAddresses = ipv4["Addresses"] as? [String] ?? []
                if let server = ipv4["ServerAddress"] as? String, server != "127.0.0.1", c.server == nil { c.server = server }
            }
            if let ipv6 = status["IPv6"] as? [String: Any] {
                c.interface = c.interface ?? ipv6["InterfaceName"] as? String
                c.tunnelAddresses += (ipv6["Addresses"] as? [String] ?? []).filter { !$0.hasPrefix("fe80") }
            }
            if let vpn = status["VPN"] as? [String: Any] {
                if let remote = vpn["RemoteAddress"] as? String, remote != "127.0.0.1", !remote.isEmpty { c.server = remote }
            }
            // When it last changed state (connected); "ConnectTime" is only how long connecting took.
            if let changed = status["LastStatusChangeTime"] as? Date { c.since = changed }
            c.dns = status["DNSServers"] as? [String] ?? []
            c.fullTunnel = (status["IsPrimaryInterface"] as? NSNumber)?.boolValue == true || (c.interface != nil && c.interface == primary)
            return c
        }
    }

    nonisolated private static func protocolName(type: String, provider: String?, name: String) -> String? {
        let text = ((provider ?? "") + " " + name).lowercased()
        if text.contains("wireguard") || text.contains("wg-") { return "WireGuard" }
        if text.contains("openvpn") { return "OpenVPN" }
        if text.contains("ikev2") { return "IKEv2" }
        if text.contains("stealth") { return "Stealth" }
        if text.contains("tailscale") { return "WireGuard (Tailscale)" }
        switch type {
        case "IPSec": return "IPSec"
        case "L2TP": return "L2TP"
        case "PPP": return "PPP"
        default: return nil
        }
    }

    /// The app behind a network extension: "ch.protonvpn.mac.WireGuard-Extension" → Proton VPN.
    nonisolated private static func appURL(forProvider provider: String?) -> URL? {
        guard var id = provider else { return nil }
        while id.contains(".") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), url.path.hasSuffix(".app") { return url }
            id = String(id[..<id.lastIndex(of: ".")!])
        }
        return nil
    }

    nonisolated private static func appURL(named name: String) -> URL? {
        let candidates = ["/Applications/\(name).app", "/Applications/\(name.replacingOccurrences(of: " ", with: "")).app"]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - PIA and Mullvad

    nonisolated static var piactl: String? {
        ["/usr/local/bin/piactl", "/opt/homebrew/bin/piactl",
         "/Applications/Private Internet Access.app/Contents/MacOS/piactl"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static var mullvad: String? {
        ["/usr/local/bin/mullvad", "/opt/homebrew/bin/mullvad",
         "/Applications/Mullvad VPN.app/Contents/Resources/mullvad"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func toolConnections() async -> [Connection] {
        var found: [Connection] = []
        if let piactl {
            async let state = Shell.run(piactl, ["get", "connectionstate"], timeout: 4)
            async let region = Shell.run(piactl, ["get", "region"], timeout: 4)
            async let vpnIP = Shell.run(piactl, ["get", "vpnip"], timeout: 4)
            async let pubIP = Shell.run(piactl, ["get", "pubip"], timeout: 4)
            async let port = Shell.run(piactl, ["get", "portforward"], timeout: 4)
            async let proto = Shell.run(piactl, ["get", "protocol"], timeout: 4)
            let s = await state.out.trimmed
            if !s.isEmpty {
                var c = Connection(id: "pia", name: "Private Internet Access", status: s == "Connected" ? .connected
                                   : s.hasPrefix("Connecting") || s.hasPrefix("Reconnecting") ? .connecting
                                   : s.hasPrefix("Disconnecting") ? .disconnecting : .disconnected)
                c.source = .pia
                c.appURL = URL(fileURLWithPath: "/Applications/Private Internet Access.app")
                let ip = await vpnIP.out.trimmed
                if !ip.isEmpty, ip != "Unknown" { c.tunnelAddresses = [ip] }
                c.protocolName = await proto.out.trimmed.capitalized.nilIfEmpty
                c.fullTunnel = c.isUp
                c.interface = c.isUp ? tunnelInterface(with: c.tunnelAddresses.first) : nil
                found.append(c)
                let portText = await port.out.trimmed
                let extra = Extra(region: await region.out.trimmed.replacingOccurrences(of: "-", with: " ").capitalized.nilIfEmpty,
                                  portForward: Int(portText) != nil ? portText : nil,
                                  publicIP: await pubIP.out.trimmed.nilIfEmpty)
                VPNMonitor.shared.extras["pia"] = extra
            }
        }
        if let mullvad {
            let status = await Shell.run(mullvad, ["status", "-v"], timeout: 5).out
            if !status.isEmpty {
                let first = status.split(separator: "\n").first.map(String.init) ?? ""
                var c = Connection(id: "mullvad", name: "Mullvad VPN", status: first.hasPrefix("Connected") ? .connected
                                   : first.hasPrefix("Connecting") ? .connecting : .disconnected)
                c.source = .mullvad
                c.appURL = URL(fileURLWithPath: "/Applications/Mullvad VPN.app")
                c.fullTunnel = c.isUp
                for line in status.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    if line.lowercased().hasPrefix("relay:") { c.server = line.dropFirst(6).trimmingCharacters(in: .whitespaces) }
                    if line.lowercased().hasPrefix("tunnel type:") || line.lowercased().hasPrefix("features:") {
                        c.protocolName = c.protocolName ?? (line.lowercased().contains("openvpn") ? "OpenVPN" : "WireGuard")
                    }
                }
                found.append(c)
            }
        }
        return found
    }

    /// A utun interface carrying the default route that no profile or tool explains.
    nonisolated private static func unclaimedTunnel(claimed: Set<String>) -> Connection? {
        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        guard let primary = global?["PrimaryInterface"] as? String, primary.hasPrefix("utun") || primary.hasPrefix("ipsec"),
              !claimed.contains(primary) else { return nil }
        var c = Connection(id: "tunnel:\(primary)", name: "VPN tunnel", status: .connected)
        c.interface = primary
        c.fullTunnel = true
        c.source = .tunnel
        c.tunnelAddresses = addresses(on: primary)
        // The VPN app that's running is the likely owner.
        let known = ["com.privateinternetaccess", "net.mullvad", "com.nordvpn", "com.expressvpn", "ch.protonvpn", "com.surfshark",
                     "com.wireguard", "net.openvpn", "com.cloudflare", "com.windscribe", "com.cyberghost", "org.tunnelblick"]
        if let app = NSWorkspace.shared.runningApplications.first(where: { app in known.contains { app.bundleIdentifier?.hasPrefix($0) == true } }) {
            c.name = app.localizedName ?? c.name
            c.appURL = app.bundleURL
        }
        return c
    }

    nonisolated private static func tunnelInterface(with address: String?) -> String? {
        guard let address else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if String(cString: host) == address { return String(cString: ptr.pointee.ifa_name) }
        }
        return nil
    }

    nonisolated private static func addresses(on interface: String) -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) where String(cString: ptr.pointee.ifa_name) == interface {
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            result.append(String(cString: host))
        }
        return result
    }

    // MARK: - Exit location

    /// Where your traffic reaches the internet: ipinfo.io for city and provider, with Cloudflare's
    /// trace as a fallback for the address and country.
    nonisolated private static func fetchExit() async -> Exit? {
        if let url = URL(string: "https://ipinfo.io/json"),
           let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let ip = obj["ip"] as? String {
            let code = obj["country"] as? String
            // "AS62371 Proton AG" → "Proton AG"
            let org = (obj["org"] as? String).map { $0.replacingOccurrences(of: #"^AS\d+\s+"#, with: "", options: .regularExpression) }
            return Exit(ip: ip, city: obj["city"] as? String, region: obj["region"] as? String,
                        country: code.flatMap { Locale.current.localizedString(forRegionCode: $0) }, countryCode: code, org: org)
        }
        guard let url = URL(string: "https://1.1.1.1/cdn-cgi/trace"),
              let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        guard let ip = fields["ip"] else { return nil }
        let code = fields["loc"]
        return Exit(ip: ip, country: code.flatMap { Locale.current.localizedString(forRegionCode: $0) }, countryCode: code)
    }

    // MARK: - Actions

    func toggle(_ connection: Connection) {
        let up = connection.isUp || connection.status == .connecting
        switch connection.source {
        case .pia:
            guard let piactl = Self.piactl else { return }
            Task { _ = await Shell.run(piactl, [up ? "disconnect" : "connect"], timeout: 10); refreshSoon() }
        case .mullvad:
            guard let mullvad = Self.mullvad else { return }
            Task { _ = await Shell.run(mullvad, [up ? "disconnect" : "connect"], timeout: 10); refreshSoon() }
        case .tunnel:
            open(connection)
        case .system:
            guard let sc = SCNetworkConnectionCreateWithServiceID(nil, connection.id as CFString, nil, nil) else { return }
            let ok = up ? SCNetworkConnectionStop(sc, true) : SCNetworkConnectionStart(sc, nil, true)
            // Some VPN apps only connect from their own window.
            if !ok { open(connection) }
            refreshSoon()
        }
    }

    func open(_ connection: Connection) {
        if let url = connection.appURL { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }

    private func refreshSoon() {
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
    }

    /// DNS that isn't the tunnel's own while all traffic should go through it: a possible leak.
    func dnsWarning(for c: Connection) -> String? {
        guard c.isUp, c.fullTunnel else { return nil }
        let global = (SCDynamicStoreCopyValue(nil, "State:/Network/Global/DNS" as CFString) as? [String: Any])?["ServerAddresses"] as? [String] ?? []
        let leaking = global.filter { ip in !c.dns.contains(ip) && (ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.")) }
        return leaking.isEmpty || c.dns.isEmpty ? nil : "DNS also goes to \(leaking.joined(separator: ", "))"
    }
}

/// Heads-ups when the connection changes: offline and back, a VPN connecting or dropping, the
/// public address changing. Event-driven (NWPathMonitor), so it costs nothing while nothing happens.
@MainActor
final class ConnectionWatcher {
    static let shared = ConnectionWatcher()
    private var monitor: NWPathMonitor?
    private var settle: DispatchWorkItem?
    private var wasOnline: Bool?
    private var vpnStates: [String: Bool] = [:]
    private var lastIP: String?
    private var timer: Timer?

    func apply(_ enabled: Bool) {
        monitor?.cancel()
        monitor = nil
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in ConnectionWatcher.shared.changed(online: online) }
        }
        m.start(queue: .main)
        monitor = m
        // VPN apps don't always change the path (split tunnels); look in now and then too.
        let t = Timer(timeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { ConnectionWatcher.shared.checkVPNs(checkIP: false) } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        checkVPNs(announce: false, checkIP: true)
    }

    private func changed(online: Bool) {
        // Paths flap while networks switch; act once things settle.
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settled(online: online) }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func settled(online: Bool) {
        let before = wasOnline
        wasOnline = online
        NetworkMonitor.shared.refreshInfo()
        guard let before else { checkVPNs(announce: false, checkIP: true); return }
        if before && !online {
            Self.alertOffline()
        } else if !before && online {
            let info = NetworkMonitor.shared.info
            Self.alertOnline(info.ssid ?? info.interfaceName)
        }
        checkVPNs(announce: true, checkIP: true)
    }

    /// The address is only looked up when the network or a VPN changed, not on the periodic check.
    private func checkVPNs(announce: Bool = true, checkIP: Bool) {
        let vpn = VPNMonitor.shared
        vpn.refresh()
        // Give the refresh a moment, then compare.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            var states: [String: Bool] = [:]
            for c in vpn.connections { states[c.id] = c.isUp }
            if announce {
                for c in vpn.connections {
                    guard let before = self.vpnStates[c.id], before != c.isUp else { continue }
                    Self.alertVPN(c.name, up: c.isUp, detail: c.isUp ? (vpn.exit?.place.nilIfEmpty ?? c.server ?? "VPN on") : nil,
                                  fullTunnel: c.fullTunnel)
                }
            }
            let vpnChanged = states != self.vpnStates
            self.vpnStates = states
            if checkIP || vpnChanged { Task { await self.checkPublicIP(announce: announce) } }
        }
    }

    private func checkPublicIP(announce: Bool) async {
        guard wasOnline != false else { return }
        await VPNMonitor.shared.refreshExit(ifOlderThan: 5)
        guard let exit = VPNMonitor.shared.exit else { return }
        defer { lastIP = exit.ip }
        guard announce, let lastIP, lastIP != exit.ip else { return }
        Self.alertIP(exit)
    }

    // MARK: - Alerts (also used by the debug simulator)

    static func alertOffline() {
        ActivityCenter.shared.show(.notice(title: "You're offline", detail: "No internet connection", icon: "wifi.exclamationmark", tone: .warning), for: 5)
    }

    static func alertOnline(_ network: String) {
        ActivityCenter.shared.show(.notice(title: "Back online", detail: network, icon: "wifi"), for: 3)
    }

    static func alertVPN(_ name: String, up: Bool, detail: String?, fullTunnel: Bool) {
        if up {
            ActivityCenter.shared.show(.notice(title: "\(name) connected", detail: detail ?? "VPN on", icon: "lock.shield.fill"), for: 4)
        } else {
            ActivityCenter.shared.show(.notice(title: "\(name) disconnected",
                                               detail: fullTunnel ? "You're unprotected" : "VPN off",
                                               icon: "shield.slash.fill", tone: fullTunnel ? .warning : .info), for: 5)
        }
    }

    static func alertIP(_ exit: VPNMonitor.Exit) {
        ActivityCenter.shared.show(.notice(title: "Public IP changed", detail: (exit.flag.isEmpty ? "" : exit.flag + " ") + exit.ip,
                                           icon: "globe", tone: .info), for: 4)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
