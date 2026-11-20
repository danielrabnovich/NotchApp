import AppKit
import Combine
import CryptoKit
import Darwin
import UniformTypeIdentifiers

/// A device running LocalSend (localsend.org) on this network: phones, Windows and Linux PCs, other Macs.
struct LocalSendDevice: Identifiable, Equatable {
    let alias: String
    let ip: String
    let port: Int
    let secure: Bool
    let deviceType: String
    let deviceModel: String?
    let fingerprint: String
    var id: String { fingerprint }

    var icon: String {
        switch deviceType {
        case "mobile": deviceModel?.lowercased().contains("ipad") == true ? "ipad" : "iphone"
        case "web": "globe"
        case "headless", "server": "server.rack"
        default: "desktopcomputer"
        }
    }
}

/// Sending files with LocalSend's open protocol (v2), from the Shelf: devices are found by a
/// multicast hello on the local network, and files go straight to them over HTTPS once the
/// person on the other end accepts. No account, no server, nothing leaves the network.
/// Only sending: this Mac doesn't advertise itself to receive.
@MainActor
final class LocalSendService: ObservableObject {
    static let shared = LocalSendService()

    struct SendJob: Equatable {
        let device: LocalSendDevice
        let fileCount: Int
        var waitingForAccept = true
        var progress: Double?
    }

    @Published private(set) var devices: [LocalSendDevice] = []
    @Published private(set) var scanning = false
    /// Files waiting for a device to be picked.
    @Published var pending: [URL] = []
    @Published private(set) var sending: SendJob?

    private static let group = "224.0.0.167"
    private static let port: UInt16 = 53317

    /// Who this Mac says it is: its own name, as AirDrop does, and a fingerprint kept across launches.
    nonisolated private static let alias = Host.current().localizedName ?? "Mac"
    nonisolated private static let fingerprint: String = {
        let key = "localSendFingerprint"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let made = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(made, forKey: key)
        return made
    }()
    nonisolated private static var info: [String: Any] {
        ["alias": alias, "version": "2.1", "deviceModel": "Mac", "deviceType": "desktop",
         "fingerprint": fingerprint, "port": Int(port), "protocol": "https", "download": false]
    }

    // MARK: - Finding devices

    /// Says hello on the network and collects who answers over the next few seconds.
    func scan() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let found = Self.discover(for: 3)
            await MainActor.run {
                let shared = LocalSendService.shared
                shared.scanning = false
                shared.devices = found.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
            }
        }
    }

    /// Multicast discovery: join LocalSend's group, announce, and read the announcements and
    /// replies that come back. (Devices first try to reply over HTTP; with no server here that
    /// fails at once, and they fall back to replying on the group.)
    nonisolated private static func discover(for seconds: Double) -> [LocalSendDevice] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { return [] }
        var membership = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(group)), imr_interface: in_addr(s_addr: INADDR_ANY))
        setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var hello = info
        hello["announce"] = true
        hello["announcement"] = true
        if let data = try? JSONSerialization.data(withJSONObject: hello) {
            var to = sockaddr_in()
            to.sin_family = sa_family_t(AF_INET)
            to.sin_port = port.bigEndian
            to.sin_addr.s_addr = inet_addr(group)
            _ = data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                } }
            }
        }

        var found: [String: LocalSendDevice] = [:]
        let end = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < end {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard n > 0,
                  let obj = try? JSONSerialization.jsonObject(with: Data(buffer[0..<n])) as? [String: Any],
                  let print = obj["fingerprint"] as? String, print != fingerprint,
                  let alias = obj["alias"] as? String else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            found[print] = LocalSendDevice(alias: alias, ip: ip, port: obj["port"] as? Int ?? Int(port),
                                           secure: (obj["protocol"] as? String ?? "https") == "https",
                                           deviceType: obj["deviceType"] as? String ?? "desktop",
                                           deviceModel: obj["deviceModel"] as? String, fingerprint: print)
        }
        return Array(found.values)
    }

    // MARK: - Sending

    /// Queues files and opens the device picker.
    func offer(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending = urls
        scan()
    }

    func cancelPending() { pending = [] }

    func send(to device: LocalSendDevice) {
        guard !pending.isEmpty, sending == nil else { return }
        let files = pending
        pending = []
        sending = SendJob(device: device, fileCount: files.count)
        Task {
            let outcome = await Self.upload(files, to: device)
            sending = nil
            let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
            switch outcome {
            case .sent: ActivityCenter.shared.show(.notice(title: "Sent to \(device.alias)", detail: what, icon: "paperplane.fill"), for: 3.5)
            case .declined: ActivityCenter.shared.show(.notice(title: "\(device.alias) declined", detail: what, icon: "paperplane.fill", tone: .warning), for: 4)
            case .failed(let why): ActivityCenter.shared.show(.notice(title: "Couldn't send to \(device.alias)", detail: why, icon: "paperplane.fill", tone: .warning), for: 5)
            }
        }
    }

    private enum Outcome { case sent, declined, failed(String) }

    /// LocalSend's two steps: propose the files (the other side accepts or declines), then upload
    /// each one with the token it was given.
    private static func upload(_ files: [URL], to device: LocalSendDevice) async -> Outcome {
        let base = "\(device.secure ? "https" : "http")://\(device.ip):\(device.port)/api/localsend/v2"
        var meta: [String: Any] = [:]
        var ids: [String: URL] = [:]
        for (i, url) in files.enumerated() {
            let id = "f\(i)"
            ids[id] = url
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            meta[id] = ["id": id, "fileName": url.lastPathComponent, "size": size, "fileType": type]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["info": info, "files": meta]),
              let prepare = URL(string: base + "/prepare-upload") else { return .failed("Couldn't start") }
        var request = URLRequest(url: prepare, timeoutInterval: 120) // the other person has to accept
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (data, response) = try? await LANSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .failed("Couldn't reach it") }
        switch status {
        case 200: break
        case 204: return .sent
        case 403: return .declined
        case 409: return .failed("It's busy with another transfer")
        default: return .failed("It answered \(status)")
        }
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = reply["sessionId"] as? String, let tokens = reply["files"] as? [String: String] else { return .failed("Unexpected answer") }
        await MainActor.run { LocalSendService.shared.sending?.waitingForAccept = false }
        var done = 0
        for (id, token) in tokens {
            guard let file = ids[id],
                  var parts = URLComponents(string: base + "/upload") else { continue }
            parts.queryItems = [.init(name: "sessionId", value: session), .init(name: "fileId", value: id), .init(name: "token", value: token)]
            guard let url = parts.url else { continue }
            var put = URLRequest(url: url, timeoutInterval: 600)
            put.httpMethod = "POST"
            guard let (_, r) = try? await LANSession.shared.upload(for: put, fromFile: file),
                  (r as? HTTPURLResponse)?.statusCode == 200 else { return .failed("Stopped at \(file.lastPathComponent)") }
            done += 1
            let progress = Double(done) / Double(tokens.count)
            await MainActor.run { LocalSendService.shared.sending?.progress = progress }
        }
        return .sent
    }
}

/// LocalSend devices use self-signed certificates (their fingerprint is the certificate's hash),
/// so the usual check can't pass; this session accepts them for addresses on the local network only.
private final class LANSession: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared: URLSession = URLSession(configuration: .ephemeral, delegate: LANSession(), delegateQueue: nil)

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              Self.isLocal(host), let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// Private IPv4 ranges (10/8, 172.16/12, 192.168/16) and link-local (169.254/16).
    static func isLocal(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
    }
}
