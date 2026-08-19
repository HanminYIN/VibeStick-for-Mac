import Darwin
import Dispatch
import Foundation

private func writeStandardError(_ message: String) {
    guard let data = "VibeStick Bridge: \(message)\n".data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}

private func fail(_ message: String, code: Int32 = 1) -> Never {
    writeStandardError(message)
    exit(code)
}

signal(SIGPIPE, SIG_IGN)

let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
let supportDirectory = homeDirectory
    .appendingPathComponent("Library/Application Support/VibeStick", isDirectory: true)

let assembly: NativeBridgeProductionAssembly
do {
    assembly = try NativeBridgeProductionFactory.make(
        supportDirectory: supportDirectory,
        homeDirectory: homeDirectory
    )
} catch let error as NativeBridgeRuntimeConfigurationError {
    fail("native runtime configuration is unavailable [\(error.code)]")
} catch {
    fail("native runtime startup is unavailable")
}

assembly.server.start()
if let data = "VibeStick Bridge 0.2.0 listening on http://0.0.0.0:8765\n".data(using: .utf8) {
    FileHandle.standardOutput.write(data)
}
dispatchMain()
