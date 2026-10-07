// Sends a debug command to a running NotchApp (requires the debugHooks default).
import Foundation
let cmd = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(.init("com.notchapp.debug"), object: cmd, userInfo: nil, deliverImmediately: true)
