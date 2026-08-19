import Darwin
import Foundation
import Testing

@Suite("Native Swift Bridge persistence compatibility")
struct NativeBridgePersistenceTests {
    @Test("paired registry accepts only matching non-revoked device tokens")
    func pairedRegistryAuthentication() throws {
        try withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("devices-v1.json")
            let token = "device-token-abcdefghijklmnopqrstuvwxyz-123456"
            let salt = "0123456789abcdef0123456789abcdef"
            try writeFixture([
                "schema_version": 1,
                "devices": [[
                    "device_id": "vs-001122334455",
                    "name": "Fictional Stick",
                    "token_salt": salt,
                    "token_hash": NativeBridgeSecurity.pairingTokenHash(saltHex: salt, token: token),
                    "paired_at": "2026-08-19T00:00:00Z",
                    "firmware_version": "0.2.0-test",
                    "revoked": false,
                ]],
            ], to: path)
            let registry = NativePairedDeviceRegistry(path: path)

            #expect(registry.authenticate(deviceID: "vs-001122334455", token: token))
            #expect(!registry.authenticate(deviceID: "vs-001122334455", token: String(repeating: "b", count: 43)))
            #expect(!registry.authenticate(deviceID: "../../secrets", token: token))
        }
    }

    @Test("malformed, revoked, and symlinked registries fail closed")
    func malformedRegistryFailsClosed() throws {
        try withTemporaryDirectory { directory in
            let malformed = directory.appendingPathComponent("malformed.json")
            try writeFixture([
                "schema_version": 1,
                "devices": [[
                    "device_id": "vs-001122334455",
                    "token_salt": "not-hex",
                    "token_hash": String(repeating: "0", count: 64),
                ]],
            ], to: malformed)
            #expect(NativePairedDeviceRegistry(path: malformed).devices().isEmpty)

            let link = directory.appendingPathComponent("registry-link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: malformed)
            #expect(NativePairedDeviceRegistry(path: link).devices().isEmpty)
        }
    }

    @Test("device configuration normalization matches firmware limits")
    func configurationNormalization() {
        let normalized = NativeDeviceConfigurationStore.normalize([
            "schema_version": 1,
            "revision": 7,
            "modules": ["claude", "unknown", "claude"],
            "default_page": "unknown",
            "project": ["visible": false, "name": "  这是一个长度超过固件字节限制的项目名称  "],
            "buttons": ["front_double": "home", "side_single": "none"],
        ])

        #expect(normalized["revision"] as? Int == 7)
        #expect(normalized["modules"] as? [String] == ["codex", "claude", "connection"])
        #expect(normalized["default_page"] as? String == "codex")
        let project = normalized["project"] as? [String: Any]
        #expect(project?["visible"] as? Bool == false)
        #expect((project?["name"] as? String ?? "").utf8.count <= 39)
        let buttons = normalized["buttons"] as? [String: String]
        #expect(buttons?["front_double"] == "home")
        #expect(buttons?["side_single"] == "none")
    }

    @Test("oversized configuration falls back and managed project changes only presentation")
    func configurationFallbackAndManagedPresentation() throws {
        try withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("device-config-v1.json")
            try Data(repeating: 0x78, count: 20_000).write(to: path)
            let fallback = NativeDeviceConfigurationStore(path: path).current()
            #expect(fallback["revision"] as? Int == 0)
            #expect(fallback["modules"] as? [String] == ["codex", "connection"])

            try writeFixture([
                "schema_version": 1,
                "revision": 9,
                "modules": ["codex", "claude", "connection"],
                "default_page": "claude",
                "project": ["visible": false, "name": "Legacy"],
                "buttons": ["front_double": "home", "side_single": "none"],
            ], to: path)
            let managed = NativeDeviceConfigurationStore(
                path: path,
                managedProjectPresentation: ["showProjectName": true, "projectName": "Managed Project"]
            ).current()
            #expect(managed["revision"] as? Int == 9)
            #expect(managed["default_page"] as? String == "claude")
            #expect((managed["project"] as? [String: Any])?["name"] as? String == "Managed Project")
        }
    }

    @Test("bridge identity is stable, canonical, atomic, and private")
    func identityPersistence() throws {
        try withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("bridge-identity-v1.json")
            let store = NativeBridgeIdentityStore(path: path)
            let first = try store.bridgeID()
            let second = try store.bridgeID()
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue

            #expect(first == second)
            #expect(UUID(uuidString: first) != nil)
            #expect(first == first.lowercased())
            #expect(permissions == 0o600)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains(".tmp-") })
        }
    }

    @Test("identity writer refuses to replace a symbolic link")
    func identityRejectsSymlink() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("outside.json")
            try Data("untouched".utf8).write(to: destination)
            let link = directory.appendingPathComponent("bridge-identity-v1.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            let store = NativeBridgeIdentityStore(path: link)

            #expect(throws: (any Error).self) { try store.bridgeID() }
            #expect(try String(contentsOf: destination, encoding: .utf8) == "untouched")
        }
    }
}

private func withTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeStick-NativeBridge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(directory)
}

private func writeFixture(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: url)
}
