import AppKit
import CoreWLAN
import Darwin
import SystemConfiguration

/// Network throughput (from the interface byte counters, so it's the whole Mac's traffic) and
/// details about the current connection. Only samples while something is showing it.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    struct Info: Equatable {
        enum Kind: Equatable { case wifi, ethernet, cellular, vpn, other, offline }
        var kind: Kind = .offline
        /// "Wi-Fi", "Thunderbolt Ethernet", "iPhone USB".
        var interfaceName = ""
        var bsdName = ""
        /// Only available when macOS shares it (Location Services); otherwise nil.
        var ssid: String?
        var rssi: Int?
        var noise: Int?
        var txRateMbps: Double?
        var channel: String?
        var localIP: String?
        var router: String?
        /// "Tailscale" or "VPN" when a tunnel has an address.
        var vpn: String?
        var tailscaleIP: String?

        var signalQuality: Double? {
            guard let rssi else { return nil }
            return min(1, max(0, Double(rssi + 90) / 50)) // -90 dBm → 0, -40 dBm → 1
        }
    }

    struct PublicInfo: Equatable {
        var ip: String
        var location: String?
    }

    @Published private(set) var downRate: Double = 0 // bytes per second
    @Published private(set) var upRate: Double = 0
    @Published private(set) var downHistory: [Double] = []
    @Published private(set) var upHistory: [Double] = []
    @Published private(set) var info = Info()
    @Published private(set) var publicInfo: PublicInfo?
    @Published private(set) var routerPing: Double?
    @Published private(set) var internetPing: Double?
    @Published private(set) var pinging = false

    static let historyLength = 60

    private var timer: Timer?
    private var viewers = 0
    private var liveDemand = false
    private var speedTestDemand = false
    private var last: (time: TimeInterval, inBytes: UInt64, outBytes: UInt64)?
    private var publicFetched: Date?
    private var publicForInterface = ""
    private var infoTick = 0

    private init() {}

    // MARK: - Demand

    func viewerAppeared() {
        viewers += 1
        reschedule()
        refreshDetails()
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        reschedule()
    }

    func setLiveDemand(_ wanted: Bool) {
        guard wanted != liveDemand else { return }
        liveDemand = wanted
        reschedule()
    }

    func setSpeedTestDemand(_ wanted: Bool) {
        speedTestDemand = wanted
        reschedule()
    }

    private var isWanted: Bool { viewers > 0 || liveDemand || speedTestDemand }

    private func reschedule() {
        if isWanted, timer == nil {
            last = nil
            refreshInfo()
            sample()
            let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { NetworkMonitor.shared.tick() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !isWanted, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    private func tick() {
        sample()
        infoTick += 1
        // Wi-Fi signal moves around; the rest rarely changes.
        if infoTick % 5 == 0 { refreshInfo() }
    }

    // MARK: - Throughput

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let (inBytes, outBytes) = Self.byteCounters()
        defer { last = (now, inBytes, outBytes) }
        guard let last, now > last.time else { return }
        let dt = now - last.time
        // Counters reset when an interface goes away; skip that sample rather than show a spike.
        let down = inBytes >= last.inBytes ? Double(inBytes - last.inBytes) / dt : 0
        let up = outBytes >= last.outBytes ? Double(outBytes - last.outBytes) / dt : 0
        downRate = down
        upRate = up
        downHistory.append(down)
        upHistory.append(up)
        if downHistory.count > Self.historyLength { downHistory.removeFirst(downHistory.count - Self.historyLength) }
        if upHistory.count > Self.historyLength { upHistory.removeFirst(upHistory.count - Self.historyLength) }
    }

    /// Total bytes in and out across physical interfaces. Tunnels (VPN, Tailscale) are skipped:
    /// their traffic is already counted on the interface it travels over.
    nonisolated static func byteCounters() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(msg.ifm_index), &name) != nil, countsTraffic(String(cString: name)) {
                        inBytes += msg.ifm_data.ifi_ibytes
                        outBytes += msg.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (inBytes, outBytes)
    }

    nonisolated private static func countsTraffic(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    // MARK: - Connection details

    /// Interface, Wi-Fi signal, addresses. Cheap; runs on the main thread.
    func refreshInfo() {
        var new = Info()
        let store = SCDynamicStoreCreate(nil, "NotchApp" as CFString, nil, nil)
        let global = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] }
        let primary = global?["PrimaryInterface"] as? String
        new.router = global?["Router"] as? String
        let addresses = Self.ipv4Addresses()

        if let ts = addresses.first(where: { $0.name.hasPrefix("utun") && $0.address.hasPrefix("100.") && Self.isCGNAT($0.address) }) {
            new.tailscaleIP = ts.address
        }
        let otherTunnel = addresses.contains { $0.name.hasPrefix("utun") && !Self.isCGNAT($0.address) }
        new.vpn = otherTunnel || primary?.hasPrefix("utun") == true ? "VPN" : new.tailscaleIP != nil ? "Tailscale" : nil

        if let primary {
            new.bsdName = primary
            new.localIP = addresses.first { $0.name == primary }?.address
            let wifi = CWWiFiClient.shared().interface()
            if let wifi, wifi.interfaceName == primary {
                new.kind = .wifi
                new.interfaceName = "Wi-Fi"
                new.ssid = wifi.ssid()
                let rssi = wifi.rssiValue()
                new.rssi = rssi != 0 ? rssi : nil
                let noise = wifi.noiseMeasurement()
                new.noise = noise != 0 ? noise : nil
                let tx = wifi.transmitRate()
                new.txRateMbps = tx > 0 ? tx : nil
                if let ch = wifi.wlanChannel() {
                    let band: String = switch ch.channelBand {
                    case .band2GHz: "2.4 GHz"
                    case .band5GHz: "5 GHz"
                    case .band6GHz: "6 GHz"
                    default: ""
                    }
                    new.channel = band.isEmpty ? "Ch \(ch.channelNumber)" : "\(band) · Ch \(ch.channelNumber)"
                }
            } else if primary.hasPrefix("utun") || primary.hasPrefix("ipsec") || primary.hasPrefix("ppp") {
                new.kind = .vpn
                new.interfaceName = "VPN"
            } else if primary.hasPrefix("pdp_ip") {
                new.kind = .cellular
                new.interfaceName = "Cellular"
            } else {
                new.kind = primary.hasPrefix("en") ? .ethernet : .other
                new.interfaceName = Self.displayName(bsd: primary) ?? "Ethernet"
            }
        }
        if new != info { info = new }
    }

    /// Public address and pings: network calls, so only when the Network pane is opened.
    func refreshDetails(force: Bool = false) {
        refreshInfo()
        let stale = publicFetched.map { Date().timeIntervalSince($0) > 600 } ?? true
        if force || stale || publicForInterface != info.bsdName {
            publicForInterface = info.bsdName
            publicFetched = Date()
            Task { publicInfo = await Self.fetchPublicInfo() }
        }
        ping()
    }

    func ping() {
        guard !pinging else { return }
        pinging = true
        let router = info.router
        Task {
            async let r: Double? = router == nil ? nil : await Self.ping(router!)
            async let i = Self.ping("1.1.1.1")
            let (routerMs, internetMs) = await (r, i)
            routerPing = routerMs
            internetPing = internetMs
            pinging = false
        }
    }

    nonisolated static func ping(_ host: String) async -> Double? {
        let result = await Shell.run("/sbin/ping", ["-c", "3", "-i", "0.2", "-t", "3", "-q", host], timeout: 5)
        // "round-trip min/avg/max/stddev = 1.234/2.345/3.456/0.5 ms"
        guard let line = result.out.split(separator: "\n").first(where: { $0.contains("min/avg/max") }),
              let values = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces).split(separator: "/"),
              values.count >= 2 else { return nil }
        return Double(values[1])
    }

    /// Cloudflare's trace page: the address the internet sees and the country.
    nonisolated private static func fetchPublicInfo() async -> PublicInfo? {
        guard let url = URL(string: "https://1.1.1.1/cdn-cgi/trace") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        guard let ip = fields["ip"] else { return nil }
        let country = fields["loc"].flatMap { Locale.current.localizedString(forRegionCode: $0) }
        return PublicInfo(ip: ip, location: country)
    }

    nonisolated private static func ipv4Addresses() -> [(name: String, address: String)] {
        var result: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard !address.hasPrefix("127."), !address.hasPrefix("169.254.") else { continue }
            result.append((String(cString: ifa.ifa_name), address))
        }
        return result
    }

    /// 100.64.0.0/10, the range Tailscale hands out.
    nonisolated private static func isCGNAT(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    nonisolated private static func displayName(bsd: String) -> String? {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        return all.first { SCNetworkInterfaceGetBSDName($0) as String? == bsd }
            .flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
    }
}
