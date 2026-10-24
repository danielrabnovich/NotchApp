import Foundation

/// `notch`: NotchApp from the command line, and the way coding agents reach it (Claude Code's
/// hooks run `notch hook`; MCP clients run `notch mcp`). Ships inside the app as
/// NotchApp.app/Contents/MacOS/notch. Every command is one JSON request over a Unix socket that
/// only this user can reach; NotchApp does the rest.

let usage = """
notch: talk to NotchApp from the terminal.

  notch run [--title T] [--] <command…>   Run a command with a ring beside the notch and a Banner when it ends
  notch banner <title> [detail] [--symbol S] [--success|--warning]
  notch progress <0…1|-> [title] [--id ID] [--label L]   Update a ring beside the notch (- for no percent)
  notch progress --done [--id ID]          Take it away
  notch shelf <file…>                       Put files on the Shelf
  notch ask <question> <choice> <choice> [choice] [--timeout SECONDS]
                                            Ask in the notch; prints the choice (exit 1 without an answer)
  notch mcp                                 An MCP server (stdio) for coding agents
  notch hook                                For Claude Code's hooks: reads the event on stdin

Exit status 3 means NotchApp isn't running.
"""

// MARK: - Talking to NotchApp

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/NotchApp/notch.sock").path

/// Sends one request and waits (up to `timeout`) for NotchApp's reply. Nil when it isn't running
/// or didn't answer in time.
func send(_ request: [String: Any], timeout: TimeInterval = 5) -> [String: Any]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8)
    guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: path)
        raw[path.count] = 0
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return nil }
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
    data.append(0x0A)
    let sent = data.withUnsafeBytes { raw -> Bool in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
    guard sent else { return nil }

    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while reply.count < 1_000_000 {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        reply.append(contentsOf: chunk[0..<n])
        if chunk[0..<n].contains(0x0A) { break }
    }
    return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
}

/// Who's asking: the process that ran `notch` (a shell, or the agent for `notch mcp`), so a click
/// on what it shows can go back to that terminal, and the folder it's in names the project.
var source: [String: Any] {
    ["pid": Int(getppid()), "cwd": FileManager.default.currentDirectoryPath]
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("notch: \(message)\n".utf8))
    exit(code)
}

func notRunning() -> Never { fail("NotchApp isn't running", code: 3) }

/// Sends a request where a reply is all that's needed: errors from NotchApp go to stderr.
func request(_ body: [String: Any], timeout: TimeInterval = 5) -> [String: Any] {
    guard let reply = send(body, timeout: timeout) else { notRunning() }
    if let error = reply["error"] as? String { fail(error, code: 1) }
    return reply
}

// MARK: - Arguments

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    /// `valued` options take the next argument; anything else starting with -- is a flag. A bare
    /// `--` ends the options (the rest is positional, as given).
    init(_ args: ArraySlice<String>, valued: Set<String>, stopAtFirstPositional: Bool = false) {
        var rest = args[...]
        while let arg = rest.first {
            rest = rest.dropFirst()
            if arg == "--" { positional += rest; return }
            if arg.hasPrefix("--"), positional.isEmpty || !stopAtFirstPositional {
                let name = String(arg.dropFirst(2))
                if valued.contains(name) {
                    guard let value = rest.first else { fail("--\(name) needs a value") }
                    options[name] = value
                    rest = rest.dropFirst()
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(arg)
                if stopAtFirstPositional { positional += rest; return }
            }
        }
    }
}

// MARK: - Commands

func run(_ args: ArraySlice<String>) -> Never {
    let parsed = Arguments(args, valued: ["title"], stopAtFirstPositional: true)
    let command = parsed.positional
    guard !command.isEmpty else { fail("usage: notch run [--title T] [--] <command…>") }
    let title = parsed.options["title"] ?? command.joined(separator: " ")
    let id = "run:\(getpid())"

    // Ctrl-C reaches the command and this process alike: let the command decide, and report how it ended.
    signal(SIGINT) { _ in }
    signal(SIGTERM) { _ in }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    let started = Date()
    do { try process.run() } catch { fail("couldn't run \(command[0]): \(error.localizedDescription)", code: 127) }

    // NotchApp being away never stops the command; it just goes unannounced.
    let announced = send(["cmd": "progress", "id": id, "title": title, "owner": Int(getpid()), "source": source], timeout: 1) != nil
    process.waitUntilExit()
    let status = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
    if announced {
        _ = send(["cmd": "finished", "id": id, "title": title, "status": Int(status),
                  "seconds": Date().timeIntervalSince(started), "source": source], timeout: 2)
    }
    exit(status)
}

func banner(_ args: ArraySlice<String>) -> Never {
    let parsed = Arguments(args, valued: ["symbol"])
    guard let title = parsed.positional.first else { fail("usage: notch banner <title> [detail]") }
    var body: [String: Any] = ["cmd": "banner", "title": title, "detail": parsed.positional.dropFirst().joined(separator: " "), "source": source]
    if let symbol = parsed.options["symbol"] { body["symbol"] = symbol }
    if parsed.flags.contains("success") { body["tone"] = "success" }
    if parsed.flags.contains("warning") { body["tone"] = "warning" }
    _ = request(body)
    exit(0)
}

func progress(_ args: ArraySlice<String>) -> Never {
    let parsed = Arguments(args, valued: ["id", "label"])
    let id = "cli:" + (parsed.options["id"] ?? "\(getppid())")
    if parsed.flags.contains("done") {
        _ = request(["cmd": "progress", "id": id, "done": true])
        exit(0)
    }
    guard let amount = parsed.positional.first else { fail("usage: notch progress <0…1|-> [title]") }
    var body: [String: Any] = ["cmd": "progress", "id": id, "owner": Int(getppid()), "source": source,
                               "title": parsed.positional.dropFirst().joined(separator: " ").nilIfEmpty ?? "Working"]
    if amount != "-" {
        // 0.4, 40% or 40 all mean the same.
        let number = Double(amount.replacingOccurrences(of: "%", with: "")) ?? -1
        guard number >= 0 else { fail("\(amount) isn't a fraction (0…1) or a percent") }
        body["fraction"] = amount.hasSuffix("%") || number > 1 ? min(number / 100, 1) : number
    }
    if let label = parsed.options["label"] { body["label"] = label }
    _ = request(body)
    exit(0)
}

func shelf(_ args: ArraySlice<String>) -> Never {
    guard !args.isEmpty else { fail("usage: notch shelf <file…>") }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let paths = args.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL.path }
    for path in paths where !FileManager.default.fileExists(atPath: path) { fail("no such file: \(path)") }
    _ = request(["cmd": "shelf", "paths": paths])
    exit(0)
}

func ask(_ args: ArraySlice<String>) -> Never {
    let parsed = Arguments(args, valued: ["timeout"])
    guard parsed.positional.count >= 3 else { fail("usage: notch ask <question> <choice> <choice> [choice]") }
    let timeout = min(max(Double(parsed.options["timeout"] ?? "") ?? 120, 5), 600)
    let body: [String: Any] = ["cmd": "ask", "question": parsed.positional[0], "choices": Array(parsed.positional.dropFirst()),
                               "timeout": timeout, "source": source]
    let reply = request(body, timeout: timeout + 5)
    guard let choice = reply["choice"] as? String else {
        FileHandle.standardError.write(Data("notch: \(reply["outcome"] as? String ?? "no answer")\n".utf8))
        exit(1)
    }
    print(choice)
    exit(0)
}

/// A Claude Code hook: the event arrives on stdin as JSON. Only what the notch shows is passed on
/// (never file contents or prompts), and nothing is printed: the hook never answers for the user
/// or changes what the agent does. Always exits 0, quickly, whether or not NotchApp is there.
func hook() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }
    var payload: [String: Any] = [:]
    for key in ["session_id", "hook_event_name", "cwd", "tool_name", "notification_type", "source", "reason"] {
        if let value = event[key] as? String { payload[key] = String(value.prefix(300)) }
    }
    if let message = event["message"] as? String { payload["message"] = String(message.prefix(200)) }
    if let input = event["tool_input"] as? [String: Any] {
        var kept: [String: String] = [:]
        for key in ["file_path", "notebook_path", "description", "subagent_type", "command", "pattern", "url", "query"] {
            if let value = input[key] as? String { kept[key] = String(value.prefix(200)) }
        }
        payload["tool_input"] = kept
    }
    _ = send(["cmd": "hook", "event": payload], timeout: 0.5)
    exit(0)
}

// MARK: - MCP

/// A Model Context Protocol server over stdio (newline-delimited JSON-RPC), so a coding agent can
/// show progress and Banners in the notch, put files on the Shelf, and ask a quick question.
enum MCP {
    static let output = NSLock()

    static let tools: [[String: Any]] = [
        [
            "name": "notify",
            "description": "Show a short Banner under the user's MacBook notch. Use it sparingly: when a long task finishes, or when something needs the user's attention while they may be away from the terminal. Not for routine updates.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "A few words, like \"Tests pass\"."],
                    "detail": ["type": "string", "description": "One short line of detail."],
                    "tone": ["type": "string", "enum": ["info", "success", "warning"]],
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "report_progress",
            "description": "Show progress for a long-running step as a ring beside the notch (for steps that take a minute or more). Call again to update it, and with done: true when the step ends.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "What's happening, like \"Migrating 1,200 files\"."],
                    "fraction": ["type": "number", "minimum": 0, "maximum": 1, "description": "How far along, 0 to 1. Leave out when unknown."],
                    "label": ["type": "string", "description": "Short text shown in place of the percent, like \"3/12\"."],
                    "done": ["type": "boolean", "description": "The step has ended: take the ring away."],
                ],
            ],
        ],
        [
            "name": "put_on_shelf",
            "description": "Put files on the user's NotchApp Shelf, where they can drag them into any app: screenshots, exports, builds or documents you made for them.",
            "inputSchema": [
                "type": "object",
                "properties": ["paths": ["type": "array", "items": ["type": "string"], "description": "File paths, absolute or relative to the working directory."]],
                "required": ["paths"],
            ],
        ],
        [
            "name": "ask_user",
            "description": "Ask the user a quick multiple-choice question in the notch and wait for the answer, for decisions like which of two approaches to take. 2 or 3 short choices. Never use it to ask permission to run a tool or command: permissions are answered in the terminal only, and such questions are refused. Returns the choice, or says no answer came (then carry on or ask in the terminal).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "question": ["type": "string", "description": "The question, in one short sentence."],
                    "choices": ["type": "array", "items": ["type": "string"], "minItems": 2, "maxItems": 3, "description": "2 or 3 choices of a few words each."],
                    "timeout_seconds": ["type": "number", "description": "How long to wait (default 120, at most 600)."],
                ],
                "required": ["question", "choices"],
            ],
        ],
    ]

    static func serve() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let id = message["id"]
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                respond(id, result: [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "notchapp", "version": "1.0"],
                    "instructions": "NotchApp shows things in the MacBook notch. Use report_progress for long steps, notify when something long finishes or needs the user, put_on_shelf for files you made for them, and ask_user for quick decisions (never for permissions). Keep it to what's worth interrupting for.",
                ])
            case "ping":
                respond(id, result: [:])
            case "tools/list":
                respond(id, result: ["tools": tools])
            case "tools/call":
                // Off the reading loop: a question can wait minutes for its answer.
                DispatchQueue.global().async {
                    let (text, isError) = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
                    respond(id, result: ["content": [["type": "text", "text": text]], "isError": isError])
                }
            default:
                // Notifications (no id) need no answer; unknown requests get "method not found".
                if id != nil { respond(id, error: ["code": -32601, "message": "Method not found: \(method)"]) }
            }
        }
        exit(0)
    }

    static func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        let body: [String: Any]
        var timeout: TimeInterval = 5
        switch name {
        case "notify":
            body = ["cmd": "banner", "title": args["title"] as? String ?? "", "detail": args["detail"] as? String ?? "",
                    "tone": args["tone"] as? String ?? "info", "agent": true, "source": source]
        case "report_progress":
            // One ring per agent session (this server lives as long as it does).
            let id = "mcp:\(getppid())"
            if args["done"] as? Bool == true {
                body = ["cmd": "progress", "id": id, "done": true]
            } else {
                var b: [String: Any] = ["cmd": "progress", "id": id, "title": args["title"] as? String ?? "Working",
                                        "owner": Int(getpid()), "agent": true, "source": source]
                if let f = args["fraction"] as? Double { b["fraction"] = min(max(f, 0), 1) }
                if let label = args["label"] as? String { b["label"] = label }
                body = b
            }
        case "put_on_shelf":
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let paths = (args["paths"] as? [String] ?? []).map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL.path
            }
            let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
            if paths.isEmpty { return ("No paths given.", true) }
            if !missing.isEmpty { return ("Not found: \(missing.joined(separator: ", "))", true) }
            body = ["cmd": "shelf", "paths": paths]
        case "ask_user":
            let wait = min(max(args["timeout_seconds"] as? Double ?? 120, 10), 600)
            timeout = wait + 5
            body = ["cmd": "ask", "question": args["question"] as? String ?? "", "choices": args["choices"] as? [String] ?? [],
                    "timeout": wait, "agent": true, "source": source]
        default:
            return ("Unknown tool: \(name)", true)
        }
        guard let reply = send(body, timeout: timeout) else { return ("NotchApp isn't running, so nothing was shown.", true) }
        if let error = reply["error"] as? String { return (error, true) }
        switch name {
        case "ask_user":
            if let choice = reply["choice"] as? String { return ("The user chose: \(choice)", false) }
            return (reply["outcome"] as? String ?? "No answer came.", false)
        case "put_on_shelf": return ("On the Shelf.", false)
        case "report_progress": return (args["done"] as? Bool == true ? "Progress ring removed." : "Progress shown.", false)
        default: return ("Shown.", false)
        }
    }

    static func respond(_ id: Any?, result: [String: Any]? = nil, error: [String: Any]? = nil) {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull()]
        if let result { message["result"] = result }
        if let error { message["error"] = error }
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        output.lock()
        FileHandle.standardOutput.write(data)
        output.unlock()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: -

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "run": run(args.dropFirst())
case "banner": banner(args.dropFirst())
case "progress": progress(args.dropFirst())
case "shelf": shelf(args.dropFirst())
case "ask": ask(args.dropFirst())
case "hook": hook()
case "mcp": MCP.serve()
case "ping":
    guard let reply = send(["cmd": "ping"]) else { notRunning() }
    print("NotchApp \(reply["version"] as? String ?? "") is listening")
    exit(0)
case nil, "help", "-h", "--help": print(usage); exit(0)
default: fail("unknown command \(args.first!)\n\n\(usage)")
}
