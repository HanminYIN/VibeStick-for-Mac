import AppKit
import ApplicationServices
import CryptoKit
import Foundation

private let focusedInputScope = "focused_input"
private let chatGPTWindowScope = "chatgpt_window"
private let chatGPTCompatibilityBundleIDs: Set<String> = ["com.openai.codex"]

private struct PasteTarget: Codable, Equatable {
    let bundle_id: String
    let process_id: Int
    let focus_fingerprint: String
    let verification_scope: String

    init(
        bundle_id: String,
        process_id: Int,
        focus_fingerprint: String,
        verification_scope: String = focusedInputScope
    ) {
        self.bundle_id = bundle_id
        self.process_id = process_id
        self.focus_fingerprint = focus_fingerprint
        self.verification_scope = verification_scope
    }

    private enum CodingKeys: String, CodingKey {
        case bundle_id
        case process_id
        case focus_fingerprint
        case verification_scope
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bundle_id = try values.decode(String.self, forKey: .bundle_id)
        process_id = try values.decode(Int.self, forKey: .process_id)
        focus_fingerprint = try values.decode(String.self, forKey: .focus_fingerprint)
        verification_scope = try values.decodeIfPresent(
            String.self,
            forKey: .verification_scope
        ) ?? focusedInputScope
    }
}

private struct PasteRequest: Decodable {
    let text: String?
    let press_enter: Bool?
    let operation: String?
    let expected_target: PasteTarget?
}

private struct PasteResponse: Encodable {
    let success: Bool
    let message: String
    let target: PasteTarget?
    let delivery: String?

    init(
        success: Bool,
        message: String,
        target: PasteTarget? = nil,
        delivery: String? = nil
    ) {
        self.success = success
        self.message = message
        self.target = target
        self.delivery = delivery
    }
}

private enum TargetCapture {
    case success(PasteTarget)
    case failure(String)
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

private func accessibilityPermission(prompt: Bool) -> Bool {
    let options = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt,
    ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

private func elementAttribute(_ attribute: CFString, of element: AXUIElement) -> AXUIElement? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        attribute,
        &rawValue
    ) == .success,
          let rawValue,
          CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeBitCast(rawValue, to: AXUIElement.self)
}

private func focusedElement(applicationPID: pid_t) -> AXUIElement? {
    let applicationElement = AXUIElementCreateApplication(applicationPID)
    if let element = elementAttribute(
        kAXFocusedUIElementAttribute as CFString,
        of: applicationElement
    ) {
        return element
    }
    return elementAttribute(
        kAXFocusedUIElementAttribute as CFString,
        of: AXUIElementCreateSystemWide()
    )
}

private func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
          let value = rawValue as? String else {
        return ""
    }
    return value
}

private func pointAttribute(_ attribute: CFString, of element: AXUIElement) -> CGPoint? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
          let rawValue,
          CFGetTypeID(rawValue) == AXValueGetTypeID() else {
        return nil
    }
    let value = unsafeBitCast(rawValue, to: AXValue.self)
    var point = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &point) ? point : nil
}

private func sizeAttribute(_ attribute: CFString, of element: AXUIElement) -> CGSize? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
          let rawValue,
          CFGetTypeID(rawValue) == AXValueGetTypeID() else {
        return nil
    }
    let value = unsafeBitCast(rawValue, to: AXValue.self)
    var size = CGSize.zero
    return AXValueGetValue(value, .cgSize, &size) ? size : nil
}

private func isEditableTextInput(_ element: AXUIElement, role: String) -> Bool {
    if role == (kAXTextFieldRole as String) ||
       role == (kAXTextAreaRole as String) ||
       role == (kAXComboBoxRole as String) {
        return true
    }
    for attribute in [kAXValueAttribute, kAXSelectedTextRangeAttribute] {
        var isSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &isSettable
        ) == .success && isSettable.boolValue {
            return true
        }
    }
    return false
}

private func editableFocusedElement(applicationPID: pid_t) -> AXUIElement? {
    guard var element = focusedElement(applicationPID: applicationPID) else {
        return nil
    }
    for _ in 0..<6 {
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success,
              elementPID == applicationPID else {
            return nil
        }
        let role = stringAttribute(kAXRoleAttribute as CFString, of: element)
        if !role.isEmpty, isEditableTextInput(element, role: role) {
            return element
        }
        guard let parent = elementAttribute(kAXParentAttribute as CFString, of: element) else {
            return nil
        }
        element = parent
    }
    return nil
}

private func identityParts(for element: AXUIElement) -> [String] {
    let role = stringAttribute(kAXRoleAttribute as CFString, of: element)
    let subrole = stringAttribute(kAXSubroleAttribute as CFString, of: element)
    let identifier = stringAttribute(kAXIdentifierAttribute as CFString, of: element)
    let position = pointAttribute(kAXPositionAttribute as CFString, of: element)
    let size = sizeAttribute(kAXSizeAttribute as CFString, of: element)
    return [
        role,
        subrole,
        identifier,
        position.map { "\(Int($0.x.rounded())):\(Int($0.y.rounded()))" } ?? "-",
        size.map { "\(Int($0.width.rounded())):\(Int($0.height.rounded()))" } ?? "-",
    ]
}

private func semanticIdentityParts(for element: AXUIElement) -> [String] {
    [
        stringAttribute(kAXRoleAttribute as CFString, of: element),
        stringAttribute(kAXSubroleAttribute as CFString, of: element),
        stringAttribute(kAXIdentifierAttribute as CFString, of: element),
    ]
}

private func makeTarget(
    bundleID: String,
    processID: pid_t,
    scope: String,
    identity: [String]
) -> PasteTarget {
    let fingerprintSource = ([scope, bundleID, String(processID)] + identity)
        .joined(separator: "\u{1f}")
    let digest = SHA256.hash(data: Data(fingerprintSource.utf8))
    let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
    return PasteTarget(
        bundle_id: bundleID,
        process_id: Int(processID),
        focus_fingerprint: fingerprint,
        verification_scope: scope
    )
}

private func captureFocusedInputTarget() -> TargetCapture {
    guard let application = NSWorkspace.shared.frontmostApplication,
          let bundleID = application.bundleIdentifier,
          !bundleID.isEmpty else {
        return .failure("Could not identify the focused application")
    }
    guard let element = editableFocusedElement(
        applicationPID: application.processIdentifier
    ) else {
        return .failure("Could not identify the focused input")
    }

    var elementPID: pid_t = 0
    guard AXUIElementGetPid(element, &elementPID) == .success,
          elementPID == application.processIdentifier else {
        return .failure("The focused input no longer belongs to the frontmost application")
    }

    return .success(
        makeTarget(
            bundleID: bundleID,
            processID: elementPID,
            scope: focusedInputScope,
            identity: identityParts(for: element)
        )
    )
}

private func captureChatGPTWindowTarget() -> TargetCapture {
    guard let application = NSWorkspace.shared.frontmostApplication,
          let bundleID = application.bundleIdentifier,
          chatGPTCompatibilityBundleIDs.contains(bundleID) else {
        return .failure("ChatGPT is not the focused application")
    }
    let processID = application.processIdentifier
    let applicationElement = AXUIElementCreateApplication(processID)
    guard let window = elementAttribute(
        kAXFocusedWindowAttribute as CFString,
        of: applicationElement
    ) else {
        return .failure("Could not identify the focused ChatGPT window")
    }
    var windowPID: pid_t = 0
    guard AXUIElementGetPid(window, &windowPID) == .success,
          windowPID == processID else {
        return .failure("The focused window no longer belongs to ChatGPT")
    }

    var identity = ["window"] + identityParts(for: window) + [
        "title",
        stringAttribute(kAXTitleAttribute as CFString, of: window),
    ]
    if let element = focusedElement(applicationPID: processID) {
        var elementPID: pid_t = 0
        if AXUIElementGetPid(element, &elementPID) == .success,
           elementPID == processID {
            identity += ["focus"] + semanticIdentityParts(for: element)
        }
    }
    return .success(
        makeTarget(
            bundleID: bundleID,
            processID: processID,
            scope: chatGPTWindowScope,
            identity: identity
        )
    )
}

private func captureTarget(scope: String) -> TargetCapture {
    if scope == chatGPTWindowScope {
        return captureChatGPTWindowTarget()
    }
    return captureFocusedInputTarget()
}

private func targetForPaste(allowChatGPTWindowFallback: Bool) -> PasteTarget? {
    if case .success(let target) = captureFocusedInputTarget() {
        return target
    }
    guard allowChatGPTWindowFallback,
          case .success(let target) = captureChatGPTWindowTarget() else {
        return nil
    }
    return target
}

private func performPaste(text rawText: String, pressEnter: Bool) -> PasteResponse {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        return PasteResponse(success: false, message: "No text received", target: nil)
    }

    let accessibilityTrusted = accessibilityPermission(prompt: true)
    let target: PasteTarget?
    if accessibilityTrusted {
        target = targetForPaste(allowChatGPTWindowFallback: !pressEnter)
    } else {
        target = nil
    }

    let pasteboard = NSPasteboard.general
    let previousText = pasteboard.string(forType: .string)
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
        return PasteResponse(success: false, message: "Could not update the clipboard", target: nil)
    }

    guard accessibilityTrusted else {
        return PasteResponse(
            success: true,
            message: "Transcript copied to the clipboard; automatic paste needs Accessibility permission",
            target: nil,
            delivery: "clipboard"
        )
    }

    guard postKey(9, flags: .maskCommand) else { // V
        return PasteResponse(
            success: true,
            message: "Transcript copied to the clipboard; automatic paste was unavailable",
            target: nil,
            delivery: "clipboard"
        )
    }

    guard let target else {
        Thread.sleep(forTimeInterval: 0.2)
        return PasteResponse(
            success: true,
            message: "Paste attempted; transcript remains on the clipboard",
            target: nil,
            delivery: "clipboard"
        )
    }

    if pressEnter {
        Thread.sleep(forTimeInterval: 0.12)
        guard case .success(let currentTarget) = captureTarget(
            scope: target.verification_scope
        ), currentTarget == target else {
            return PasteResponse(
                success: false,
                message: "Focused input changed before Return",
                target: target
            )
        }
        guard postKey(36) else { // Return
            return PasteResponse(
                success: false,
                message: "Could not create Return event",
                target: target
            )
        }
    }
    Thread.sleep(forTimeInterval: 0.2)
    pasteboard.clearContents()
    if let previousText {
        _ = pasteboard.setString(previousText, forType: .string)
    }
    return PasteResponse(
        success: true,
        message: target.verification_scope == chatGPTWindowScope
            ? "Pasted into ChatGPT; waiting for blue-button confirmation"
            : "Pasted into the focused app",
        target: target,
        delivery: target.verification_scope == chatGPTWindowScope
            ? "pasted_compat"
            : "pasted"
    )
}

private func inspectTarget(expectedTarget: PasteTarget?) -> PasteResponse {
    guard accessibilityPermission(prompt: false) else {
        return PasteResponse(
            success: false,
            message: "Accessibility permission is disabled",
            target: nil
        )
    }
    let scope = expectedTarget?.verification_scope ?? focusedInputScope
    switch captureTarget(scope: scope) {
    case .success(let target):
        return PasteResponse(success: true, message: "Focused input identified", target: target)
    case .failure(let message):
        return PasteResponse(success: false, message: message, target: nil)
    }
}

private func confirmReturn(expectedTarget: PasteTarget?) -> PasteResponse {
    guard accessibilityPermission(prompt: true) else {
        return PasteResponse(
            success: false,
            message: "Accessibility permission is disabled",
            target: nil
        )
    }
    guard let expectedTarget else {
        return PasteResponse(success: false, message: "Expected target is missing", target: nil)
    }
    switch captureTarget(scope: expectedTarget.verification_scope) {
    case .failure(let message):
        return PasteResponse(success: false, message: message, target: nil)
    case .success(let currentTarget):
        guard currentTarget == expectedTarget else {
            return PasteResponse(
                success: false,
                message: "Focused input changed; Return was not sent",
                target: currentTarget
            )
        }
        guard postKey(36) else {
            return PasteResponse(
                success: false,
                message: "Could not create Return event",
                target: currentTarget
            )
        }
        return PasteResponse(success: true, message: "Return sent to the confirmed input", target: currentTarget)
    }
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
            message: AXIsProcessTrusted() ? "Accessibility permission is enabled" : "Accessibility permission is disabled",
            target: nil
        )
    } else if request.operation == "inspect_target" {
        response = inspectTarget(expectedTarget: request.expected_target)
    } else if request.operation == "confirm_return" {
        response = confirmReturn(expectedTarget: request.expected_target)
    } else {
        response = performPaste(
            text: request.text ?? "",
            pressEnter: request.press_enter ?? false
        )
    }
} catch {
    response = PasteResponse(success: false, message: "Invalid paste request: \(error)", target: nil)
}
writeResponse(response, to: responseURL)
