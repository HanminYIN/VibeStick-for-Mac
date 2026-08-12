import Darwin
import Foundation

private func fail(_ message: String, code: Int32 = 1) -> Never {
    if let data = "VibeStick Bridge: \(message)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    exit(code)
}

private func loadDotEnv(_ url: URL) {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
    for rawLine in contents.split(whereSeparator: \Character.isNewline) {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("export ") {
            line.removeFirst("export ".count)
        }
        guard let separator = line.firstIndex(of: "=") else { continue }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { continue }
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" || first == "'"),
           first == last {
            value.removeFirst()
            value.removeLast()
        }
        setenv(key, value, 1)
    }
}

let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/VibeStick", isDirectory: true)
loadDotEnv(supportDirectory.appendingPathComponent(".env"))

let runtimeSource = supportDirectory
    .appendingPathComponent("runtime/bridge/src", isDirectory: true)
let pasteHelper = supportDirectory
    .appendingPathComponent("Components.noindex/VibeStick Paste.app", isDirectory: true)
setenv("PYTHONPATH", runtimeSource.path, 1)
setenv("VIBE_STICK_PASTE_HELPER", pasteHelper.path, 1)

guard FileManager.default.changeCurrentDirectoryPath(supportDirectory.path) else {
    fail("cannot open support directory at \(supportDirectory.path)")
}

let pythonPath = ProcessInfo.processInfo.environment["VIBE_STICK_PYTHON_PATH"]
    ?? "/usr/bin/python3"
guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
    fail("Python executable not found at \(pythonPath)")
}

let arguments = [
    pythonPath,
    "-m",
    "vibe_stick",
    "--host",
    "0.0.0.0",
    "--port",
    "8765",
]
var cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
cArguments.append(nil)
defer {
    for argument in cArguments where argument != nil {
        free(argument)
    }
}

let result = cArguments.withUnsafeMutableBufferPointer { buffer in
    pythonPath.withCString { executable in
        execv(executable, buffer.baseAddress!)
    }
}
let errorMessage = String(cString: strerror(errno))
fail("failed to start bridge runtime: \(errorMessage)", code: result == -1 ? 127 : 1)
