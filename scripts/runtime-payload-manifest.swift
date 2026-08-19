#!/usr/bin/env swift

import CryptoKit
import Darwin
import Foundation

private let schemaVersion = 1
private let manifestName = "manifest-v1.json"
private let requiredFiles: Set<String> = [
    "Components.noindex/VibeStick Bridge.app/Contents/MacOS/VibeStickBridge",
    "Components.noindex/VibeStick HUD.app/Contents/MacOS/VibeStickHUD",
    "Components.noindex/VibeStick Paste.app/Contents/MacOS/VibeStickPaste",
    "Components.noindex/VibeStick Paste.app/Contents/Resources/VibeStickPaste.build",
]

private struct PayloadFile: Codable {
    let mode: UInt16
    let path: String
    let sha256: String
    let size: UInt64
}

private struct PayloadManifest: Codable {
    let files: [PayloadFile]
    let payloadVersion: String
    let schemaVersion: Int
}

private struct ManifestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { "runtime payload: \(message)" }
}

private func fail(_ message: String) throws -> Never {
    throw ManifestFailure(message: message)
}

private func safeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty,
          !path.hasPrefix("/"),
          !path.hasPrefix("~"),
          !path.contains("\\") else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false)
        .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}

private func payloadFiles(root: URL) throws -> [(path: String, url: URL)] {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: []
    ) else { try fail("payload root does not exist: \(root.path)") }

    let rootPrefix = root.standardizedFileURL.path + "/"
    var result: [(String, URL)] = []
    while let url = enumerator.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let standardized = url.standardizedFileURL.path
        guard standardized.hasPrefix(rootPrefix) else { try fail("unsafe enumerated path") }
        let relative = String(standardized.dropFirst(rootPrefix.count))
        if values.isSymbolicLink == true { try fail("symlink is not allowed: \(relative)") }
        guard relative != manifestName else {
            guard values.isRegularFile == true else { try fail("non-regular file is not allowed: \(relative)") }
            continue
        }
        if values.isRegularFile == true { result.append((relative, url)) }
    }
    return result.sorted { $0.0 < $1.0 }
}

private func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while true {
        let data = try handle.read(upToCount: 1_048_576) ?? Data()
        if data.isEmpty { break }
        digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private func entry(relative: String, url: URL) throws -> PayloadFile {
    guard safeRelativePath(relative) else { try fail("unsafe path: \(relative)") }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
          let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value else {
        try fail("cannot read metadata: \(relative)")
    }
    return PayloadFile(mode: mode, path: relative, sha256: try sha256(url), size: size)
}

private func generate(root: URL, version: String) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        try fail("payload root does not exist: \(root.path)")
    }
    guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        try fail("payloadVersion is empty")
    }
    let entries = try payloadFiles(root: root).map { try entry(relative: $0.path, url: $0.url) }
    let actual = Set(entries.map(\.path))
    let missing = requiredFiles.subtracting(actual).sorted()
    guard missing.isEmpty else { try fail("required files are missing: \(missing.joined(separator: ", "))") }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(PayloadManifest(
        files: entries,
        payloadVersion: version,
        schemaVersion: schemaVersion
    ))
    data.append(0x0A)
    let destination = root.appendingPathComponent(manifestName)
    try data.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
}

private func verify(root: URL) throws {
    let manifestURL = root.appendingPathComponent(manifestName)
    let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
        try fail("cannot read \(manifestName)")
    }
    let manifest: PayloadManifest
    do { manifest = try JSONDecoder().decode(PayloadManifest.self, from: Data(contentsOf: manifestURL)) }
    catch { try fail("cannot read \(manifestName): \(error.localizedDescription)") }
    guard manifest.schemaVersion == schemaVersion else { try fail("unsupported schema version") }
    guard !manifest.payloadVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        try fail("payloadVersion is empty")
    }

    var declared: [String: PayloadFile] = [:]
    for item in manifest.files {
        guard safeRelativePath(item.path) else { try fail("unsafe path: \(item.path)") }
        guard declared[item.path] == nil else { try fail("duplicate path: \(item.path)") }
        declared[item.path] = item
    }
    let actualFiles = try payloadFiles(root: root)
    let actual = Dictionary(uniqueKeysWithValues: actualFiles.map { ($0.path, $0.url) })
    guard Set(actual.keys) == Set(declared.keys) else {
        let missing = Set(declared.keys).subtracting(actual.keys).sorted()
        let extra = Set(actual.keys).subtracting(declared.keys).sorted()
        try fail("file set mismatch; missing=\(missing), extra=\(extra)")
    }
    let requiredMissing = requiredFiles.subtracting(declared.keys).sorted()
    guard requiredMissing.isEmpty else {
        try fail("required files are missing: \(requiredMissing.joined(separator: ", "))")
    }
    for relative in actual.keys.sorted() {
        guard let url = actual[relative], let expected = declared[relative] else { continue }
        let observed = try entry(relative: relative, url: url)
        guard observed.size == expected.size else { try fail("size mismatch: \(relative)") }
        guard observed.mode == expected.mode else { try fail("mode mismatch: \(relative)") }
        guard observed.sha256 == expected.sha256 else { try fail("SHA-256 mismatch: \(relative)") }
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2 || arguments.count == 3 else {
        try fail("usage: runtime-payload-manifest.swift generate ROOT VERSION | verify ROOT")
    }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
    switch arguments[0] {
    case "generate" where arguments.count == 3:
        try generate(root: root, version: arguments[2])
    case "verify" where arguments.count == 2:
        try verify(root: root)
    default:
        try fail("usage: runtime-payload-manifest.swift generate ROOT VERSION | verify ROOT")
    }
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
