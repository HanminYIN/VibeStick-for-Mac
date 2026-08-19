import Foundation
import Testing

@Suite("Native Swift Bridge HTTP transport")
struct NativeBridgeHTTPServerTests {
    @Test("parser accepts fragmented requests and exact binary bodies")
    func fragmentedRequest() throws {
        let parser = NativeBridgeHTTPParser(maximumBodyBytes: 8)
        let first = Data("POST /recording/audio?session_id=fixed HTTP/1.1\r\nContent-Length: 4\r\nX-Test: yes\r\n\r\n\u{01}".utf8)
        let second = Data([0x02, 0x03, 0x04])
        guard case .incomplete = parser.append(first, remoteAddress: "127.0.0.1") else {
            Issue.record("first fragment should remain incomplete")
            return
        }
        guard case let .request(request) = parser.append(second, remoteAddress: "127.0.0.1") else {
            Issue.record("second fragment should complete the request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.target == "/recording/audio?session_id=fixed")
        #expect(request.header("X-Test") == "yes")
        #expect(request.body == Data([1, 2, 3, 4]))
    }

    @Test("parser rejects oversized headers and bodies before routing")
    func parserBounds() {
        let headerParser = NativeBridgeHTTPParser(maximumHeaderBytes: 1_024)
        let hugeHeader = Data(("GET /health HTTP/1.1\r\nX-Huge: " + String(repeating: "a", count: 1_100)).utf8)
        guard case let .failure(headerFailure) = headerParser.append(hugeHeader, remoteAddress: "127.0.0.1") else {
            Issue.record("oversized header should fail")
            return
        }
        #expect(headerFailure.status == 431)

        let bodyParser = NativeBridgeHTTPParser(maximumBodyBytes: 4)
        let bodyRequest = Data("POST /event HTTP/1.1\r\nContent-Length: 5\r\n\r\n".utf8)
        guard case let .failure(bodyFailure) = bodyParser.append(bodyRequest, remoteAddress: "127.0.0.1") else {
            Issue.record("oversized body should fail from headers alone")
            return
        }
        #expect(bodyFailure.status == 413)
    }

    @Test("parser rejects conflicting lengths and chunked transfer")
    func ambiguousFraming() {
        let conflicting = NativeBridgeHTTPParser().append(
            Data("POST /event HTTP/1.1\r\nContent-Length: 1\r\ncontent-length: 2\r\n\r\nxx".utf8),
            remoteAddress: "127.0.0.1"
        )
        let chunked = NativeBridgeHTTPParser().append(
            Data("POST /event HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8),
            remoteAddress: "127.0.0.1"
        )
        guard case let .failure(lengthFailure) = conflicting,
              case let .failure(transferFailure) = chunked else {
            Issue.record("ambiguous framing should fail")
            return
        }
        #expect(lengthFailure.status == 400)
        #expect(transferFailure.status == 400)
    }

    @Test("wire response is deterministic and closes the connection")
    func wireResponse() {
        let wire = NativeBridgeHTTPServer.wireResponse(NativeBridgeHTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{\"ok\":true}".utf8)
        ))
        let text = String(decoding: wire, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.contains("Content-Length: 11\r\n"))
        #expect(text.hasSuffix("{\"ok\":true}"))
    }

    @Test("non-loopback binding needs an actual credential")
    func bindSecurity() {
        #expect(throws: NativeBridgeHTTPParseError.self) {
            try NativeBridgeBindPolicy.validate(
                host: "0.0.0.0",
                bridgeToken: "change-this-shared-token",
                pairedDeviceCount: 0
            )
        }
        #expect(throws: Never.self) {
            try NativeBridgeBindPolicy.validate(host: "127.0.0.1", bridgeToken: "", pairedDeviceCount: 0)
        }
        #expect(throws: Never.self) {
            try NativeBridgeBindPolicy.validate(host: "0.0.0.0", bridgeToken: "fictional-token", pairedDeviceCount: 0)
        }
        #expect(throws: Never.self) {
            try NativeBridgeBindPolicy.validate(host: "0.0.0.0", bridgeToken: "", pairedDeviceCount: 1)
        }
    }

    @Test("Bonjour TXT record advertises only public protocol metadata")
    func bonjourMetadata() {
        let bridgeID = "00000000-0000-4000-8000-000000000001"
        let record = NativeBridgeBonjour.textRecord(bridgeID: bridgeID)
        #expect(String(decoding: record["bridge_id"] ?? Data(), as: UTF8.self) == bridgeID)
        #expect(String(decoding: record["protocol"] ?? Data(), as: UTF8.self) == "2")
        #expect(String(decoding: record["auth"] ?? Data(), as: UTF8.self) == "paired")
        #expect(record["token"] == nil)
        #expect(record["device_id"] == nil)
    }

    @Test("main app and Bridge declare the local-network and Bonjour purpose")
    func localNetworkPurposePackaging() throws {
        let macOSRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relativePath in [
            "VibeStickApp/Resources/Info.plist",
            "VibeStickBridge/Info.plist",
        ] {
            let data = try Data(contentsOf: macOSRoot.appendingPathComponent(relativePath))
            let value = try PropertyListSerialization.propertyList(from: data, format: nil)
            let plist = try #require(value as? [String: Any])
            let purpose = try #require(plist["NSLocalNetworkUsageDescription"] as? String)
            let services = try #require(plist["NSBonjourServices"] as? [String])
            #expect(!purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(services == ["_vibestick._tcp"])
        }
    }
}
