import AppKit
import ApplicationServices
import Foundation

private struct PasteRequest: Decodable {
    let text: String?
    let press_enter: Bool?
    let operation: String?
}

private struct PasteResponse: Encodable {
    let success: Bool
    let message: String
}

private func argumentValue(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag),
          CommandLine.arguments.indices.contains(index + 1) else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) -> Bool {
    guard let source = CGEventSource(stateID: .combinedSessionState),
          let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
        return false
    }
    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return true
}

private func performPaste(text rawText: String, pressEnter: Bool) -> PasteResponse {
    let permissionOptions = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
    ] as CFDictionary
    guard AXIsProcessTrustedWithOptions(permissionOptions) else {
        return PasteResponse(
            success: false,
            message: "Enable VibeStick Paste in System Settings -> Privacy & Security -> Accessibility"
        )
    }

    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        return PasteResponse(success: false, message: "No text received")
    }

    let pasteboard = NSPasteboard.general
    let previousText = pasteboard.string(forType: .string)
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
        return PasteResponse(success: false, message: "Could not update the clipboard")
    }
    guard postKey(9, flags: .maskCommand) else { // V
        return PasteResponse(success: false, message: "Could not create keyboard event")
    }
    if pressEnter {
        Thread.sleep(forTimeInterval: 0.12)
        guard postKey(36) else { // Return
            return PasteResponse(success: false, message: "Could not create Return event")
        }
    }
    Thread.sleep(forTimeInterval: 0.2)

    if let previousText {
        pasteboard.clearContents()
        _ = pasteboard.setString(previousText, forType: .string)
    }
    return PasteResponse(success: true, message: "Pasted into the focused app")
}

private func writeResponse(_ response: PasteResponse, to url: URL) {
    do {
        let data = try JSONEncoder().encode(response)
        try data.write(to: url, options: .atomic)
    } catch {
        if let data = "VibeStick Paste: could not write response: \(error)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

guard let requestPath = argumentValue(after: "--request"),
      let responsePath = argumentValue(after: "--response") else {
    exit(64)
}

let requestURL = URL(fileURLWithPath: requestPath)
let responseURL = URL(fileURLWithPath: responsePath)
private let response: PasteResponse
do {
    let request = try JSONDecoder().decode(PasteRequest.self, from: Data(contentsOf: requestURL))
    try? FileManager.default.removeItem(at: requestURL)
    if request.operation == "check" {
        response = PasteResponse(
            success: AXIsProcessTrusted(),
            message: AXIsProcessTrusted() ? "Accessibility permission is enabled" : "Accessibility permission is disabled"
        )
    } else {
        response = performPaste(
            text: request.text ?? "",
            pressEnter: request.press_enter ?? false
        )
    }
} catch {
    response = PasteResponse(success: false, message: "Invalid paste request: \(error)")
}
writeResponse(response, to: responseURL)
