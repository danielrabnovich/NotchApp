// Sends a debug command to a running NotchApp (requires the debugHooks default).
// Each command carries the token NotchApp writes at launch, which only this user can read.
import Foundation
let cmd = CommandLine.arguments.dropFirst().joined(separator: " ")
let tokenFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/NotchApp/debug-token")
guard let token = try? String(contentsOf: tokenFile, encoding: .utf8), !token.isEmpty else {
    FileHandle.standardError.write(Data("No debug token: turn on debugHooks and relaunch NotchApp.\n".utf8))
    exit(1)
}
DistributedNotificationCenter.default().postNotificationName(.init("com.notchapp.debug"), object: token + " " + cmd, userInfo: nil, deliverImmediately: true)
