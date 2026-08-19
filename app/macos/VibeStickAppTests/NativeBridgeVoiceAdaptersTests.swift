import Foundation
import Testing

@Suite("Native Swift Bridge production voice adapters")
struct NativeBridgeVoiceAdaptersTests {
    @Test("PCM writer produces private WAV and speech metrics")
    func wavWriterAndMetrics() throws {
        try withVoiceAdapterDirectory { directory in
            let store = NativeVoiceFileAudioStore(recordingsDirectory: directory.appendingPathComponent("Recordings"))
            var pcm = Data()
            for sampleIndex in 0..<(16_000 * 2) {
                let active = sampleIndex >= 4_000 && sampleIndex < 12_000
                let sample = active
                    ? Int16((sin(Double(sampleIndex) * 2 * .pi * 440 / 16_000) * 8_000).rounded())
                    : Int16(0)
                var littleEndian = sample.littleEndian
                Swift.withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
            }
            let url = try store.writePCM(
                pcm,
                sessionID: adapterSessionID,
                sampleRate: 16_000,
                channels: 1,
                bitsPerSample: 16
            )
            let data = try Data(contentsOf: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let metrics = try #require(store.metrics(for: url))
            #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
            #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(metrics.durationSeconds == 2)
            #expect(metrics.speechWindows >= 3)
            #expect(metrics.rms > 120)
        }
    }

    @Test("PCM writer rejects traversal, misalignment, and unsupported audio")
    func wavWriterRejectsInvalidInput() throws {
        try withVoiceAdapterDirectory { directory in
            let store = NativeVoiceFileAudioStore(recordingsDirectory: directory)
            #expect(throws: (any Error).self) {
                try store.writePCM(
                    Data([0, 1]),
                    sessionID: "../../escape",
                    sampleRate: 16_000,
                    channels: 1,
                    bitsPerSample: 16
                )
            }
            #expect(throws: (any Error).self) {
                try store.writePCM(
                    Data([0]),
                    sessionID: adapterSessionID,
                    sampleRate: 16_000,
                    channels: 1,
                    bitsPerSample: 16
                )
            }
            #expect(throws: (any Error).self) {
                try store.writePCM(
                    Data([0, 1, 2, 3]),
                    sessionID: adapterSessionID,
                    sampleRate: 16_000,
                    channels: 1,
                    bitsPerSample: 24
                )
            }
        }
    }

    @Test("ASR configuration never sends credentials over remote HTTP")
    func asrURLPolicy() {
        #expect(NativeASRConfiguration.normalized(
            provider: "groq",
            baseURL: "http://api.example.invalid/v1",
            apiKey: "fixture-secret",
            model: "fixture-model",
            language: "zh"
        ) == nil)
        #expect(NativeASRConfiguration.normalized(
            provider: "groq",
            baseURL: "https://api.example.invalid/v1",
            apiKey: "",
            model: "fixture-model",
            language: "zh"
        ) == nil)
        #expect(NativeASRConfiguration.normalized(
            provider: "openai-compatible",
            baseURL: "http://127.0.0.1:8080/v1",
            apiKey: "",
            model: "fixture-model",
            language: "zh"
        ) != nil)
    }

    @Test("multipart request is bounded, deterministic under injected boundary, and sanitizes filename")
    func multipartRequest() throws {
        let configuration = try #require(NativeASRConfiguration.normalized(
            provider: "groq",
            baseURL: "https://api.example.invalid/openai/v1",
            apiKey: "fixture-secret",
            model: "whisper-fixture",
            language: "zh"
        ))
        let request = try #require(NativeOpenAICompatibleTranscriber.request(
            configuration: configuration,
            audioFileName: "private\"name.wav",
            audio: Data([0, 1, 2, 3]),
            boundary: "FixtureBoundary"
        ))
        let body = try #require(String(data: request.httpBody ?? Data(), encoding: .utf8))
        #expect(request.url?.absoluteString == "https://api.example.invalid/openai/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
        #expect(body.contains("name=\"model\"\r\n\r\nwhisper-fixture"))
        #expect(body.contains("name=\"language\"\r\n\r\nzh"))
        #expect(body.contains("filename=\"private_name.wav\""))
        #expect(!body.contains("private\"name.wav"))
    }

    @Test("ASR retries transient status then returns transcript without exposing secret")
    func asrRetry() throws {
        try withVoiceAdapterDirectory { directory in
            let audioURL = directory.appendingPathComponent("fixture.wav")
            try NativeBridgeSecureFile.writeDataAtomically(Data([0, 1, 2, 3]), to: audioURL)
            let transport = VoiceASRTransportFixture(results: [
                .success(NativeASRTransportResponse(statusCode: 503, data: Data("secret body".utf8))),
                .success(NativeASRTransportResponse(
                    statusCode: 200,
                    data: try JSONSerialization.data(withJSONObject: ["text": "你好，Swift"])
                )),
            ])
            var delays: [TimeInterval] = []
            let configuration = try #require(NativeASRConfiguration.normalized(
                provider: "groq",
                baseURL: "https://api.example.invalid/v1",
                apiKey: "fixture-super-secret",
                model: "fixture-model",
                language: "zh",
                attempts: 2
            ))
            let transcriber = NativeOpenAICompatibleTranscriber(
                configuration: configuration,
                transport: transport,
                retryDelay: { delays.append($0) }
            )
            var session = NativeVoiceRecordingSession()
            session.audioFile = audioURL.path
            let result = transcriber.transcribe(session: session, explicitText: "")
            #expect(result.success)
            #expect(result.text == "你好，Swift")
            #expect(transport.requests.count == 2)
            #expect(delays == [0.4])
            #expect(!result.message.contains("fixture-super-secret"))
            #expect(!result.message.contains("secret body"))
        }
    }

    @Test("paste helper receives transcript only through a private request file")
    func pasteRequestPrivacy() throws {
        try withVoiceAdapterDirectory { directory in
            let helper = directory.appendingPathComponent("VibeStick Paste.app", isDirectory: true)
            try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: false)
            let runner = VoiceProcessRunnerFixture()
            let client = NativePasteHelperClient(
                helperApp: helper,
                runner: runner,
                temporaryRoot: directory
            )
            runner.onRun = { executable, arguments in
                guard executable.path == "/usr/bin/open" else { return .success }
                #expect(!arguments.joined(separator: " ").contains("private transcript"))
                let requestIndex = try #require(arguments.firstIndex(of: "--request"))
                let responseIndex = try #require(arguments.firstIndex(of: "--response"))
                let requestPath = URL(fileURLWithPath: arguments[requestIndex + 1])
                let responsePath = URL(fileURLWithPath: arguments[responseIndex + 1])
                let request = try voiceAdapterJSON(requestPath)
                #expect(request["text"] as? String == "private transcript")
                let attributes = try FileManager.default.attributesOfItem(atPath: requestPath.path)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
                try NativeBridgeSecureFile.writeJSONAtomically([
                    "success": true,
                    "message": "Pasted",
                    "delivery": "pasted",
                    "target": adapterTarget().jsonObject(),
                ], to: responsePath)
                return .success
            }
            let result = client.paste(text: "private transcript", pressEnter: false)
            #expect(result.success)
            #expect(result.target == adapterTarget())
            #expect(runner.calls.first?.0.path == "/usr/bin/open")
            #expect(runner.calls.count == 2)
        }
    }

    @Test("paste confirmation rejects a helper response for another target")
    func pasteTargetMismatch() throws {
        try withVoiceAdapterDirectory { directory in
            let helper = directory.appendingPathComponent("VibeStick Paste.app", isDirectory: true)
            try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: false)
            let runner = VoiceProcessRunnerFixture()
            runner.onRun = { executable, arguments in
                guard executable.path == "/usr/bin/open" else { return .success }
                let responseIndex = try #require(arguments.firstIndex(of: "--response"))
                let responsePath = URL(fileURLWithPath: arguments[responseIndex + 1])
                let other = NativeSendTarget.normalized(
                    bundleID: "com.example.Other",
                    processID: 99,
                    focusFingerprint: String(repeating: "f", count: 64)
                )!
                try NativeBridgeSecureFile.writeJSONAtomically([
                    "success": true,
                    "message": "Sent",
                    "target": other.jsonObject(),
                ], to: responsePath)
                return .success
            }
            let client = NativePasteHelperClient(
                helperApp: helper,
                runner: runner,
                temporaryRoot: directory
            )
            let result = client.confirmReturn(expected: adapterTarget())
            #expect(!result.success)
            #expect(result.message.contains("different target"))
        }
    }

    @Test("HUD state preserves a short final display then hides privately")
    func hudState() throws {
        try withVoiceAdapterDirectory { directory in
            let path = directory.appendingPathComponent("hud-state.json")
            var now = 500.0
            let hud = NativeHUDStateClient(path: path, clock: { now })
            hud.show("transcribing", holdSeconds: nil)
            var object = try voiceAdapterJSON(path)
            #expect(object["active"] as? Bool == true)
            #expect(object["text"] as? String == "正在识别")

            now = 501
            hud.hide(delaySeconds: 0.5)
            object = try voiceAdapterJSON(path)
            #expect(object["active"] as? Bool == true)
            #expect((object["expires_at_epoch"] as? NSNumber)?.doubleValue == 501.5)

            now = 502
            hud.hide(delaySeconds: nil)
            object = try voiceAdapterJSON(path)
            #expect(object["active"] as? Bool == false)
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test("Bridge bundle declares microphone purpose without a runtime compiler")
    func microphonePurpose() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VibeStickBridge/Info.plist")
        let data = try Data(contentsOf: source)
        let plist = try #require(PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any])
        #expect((plist["NSMicrophoneUsageDescription"] as? String)?.isEmpty == false)
    }

    @Test("local command receives one bounded JSON payload through stdin")
    func localCommandPayload() throws {
        let runner = VoiceLocalCommandRunnerFixture(result: NativeProcessResult(
            exitCode: 0,
            standardOutput: Data("  原生 Swift 转写  \n".utf8),
            standardError: Data()
        ))
        let transcriber = NativeLocalCommandTranscriber(
            command: "/usr/local/bin/fictional-transcriber --stdin",
            runner: runner,
            timeout: 30
        )
        var session = NativeVoiceRecordingSession()
        session.sessionID = adapterSessionID
        session.audioFile = "/private/tmp/fictional-recording.wav"
        session.audioSource = "sticks3_pcm"
        let result = transcriber.transcribe(session: session, explicitText: "")
        let input = try #require(runner.inputs.first)
        let payload = try #require(JSONSerialization.jsonObject(
            with: input
        ) as? [String: Any])

        #expect(result.success)
        #expect(result.text == "原生 Swift 转写")
        #expect(runner.commands == ["/usr/local/bin/fictional-transcriber --stdin"])
        #expect(runner.timeouts == [30])
        #expect(payload["audio_file"] as? String == "/private/tmp/fictional-recording.wav")
        #expect(payload["session_id"] as? String == adapterSessionID)
        #expect(payload["transcript"] == nil)
    }

    @Test("local command failures never return stderr or secret-like output")
    func localCommandFailurePrivacy() {
        let runner = VoiceLocalCommandRunnerFixture(result: NativeProcessResult(
            exitCode: 2,
            standardOutput: Data(),
            standardError: Data("fixture-secret must not escape".utf8)
        ))
        let transcriber = NativeLocalCommandTranscriber(command: "fictional", runner: runner)
        var session = NativeVoiceRecordingSession()
        session.audioFile = "/private/tmp/fictional.wav"
        let result = transcriber.transcribe(session: session, explicitText: "")
        #expect(!result.success)
        #expect(result.message == "Transcription command failed")
        #expect(!result.message.contains("fixture-secret"))
    }
}

private let adapterSessionID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

private func adapterTarget() -> NativeSendTarget {
    NativeSendTarget.normalized(
        bundleID: "com.openai.codex",
        processID: 42,
        focusFingerprint: String(repeating: "a", count: 64)
    )!
}

private func withVoiceAdapterDirectory(_ operation: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeStick-VoiceAdapters-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(directory)
}

private func voiceAdapterJSON(_ url: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private final class VoiceASRTransportFixture: NativeASRTransport {
    var results: [Result<NativeASRTransportResponse, Error>]
    var requests: [URLRequest] = []

    init(results: [Result<NativeASRTransportResponse, Error>]) {
        self.results = results
    }

    func send(_ request: URLRequest, timeout: TimeInterval) -> Result<NativeASRTransportResponse, Error> {
        requests.append(request)
        return results.removeFirst()
    }
}

private final class VoiceProcessRunnerFixture: NativeProcessRunning {
    enum Outcome: Equatable {
        case success
        case failure
    }

    var calls: [(URL, [String])] = []
    var onRun: ((URL, [String]) throws -> Outcome)?

    func run(executable: URL, arguments: [String], timeout: TimeInterval) -> NativeProcessResult {
        calls.append((executable, arguments))
        do {
            let outcome = try onRun?(executable, arguments) ?? .success
            return NativeProcessResult(
                exitCode: outcome == .success ? 0 : 1,
                standardOutput: Data(),
                standardError: Data()
            )
        } catch {
            return NativeProcessResult(exitCode: 1, standardOutput: Data(), standardError: Data())
        }
    }
}

private final class VoiceLocalCommandRunnerFixture: NativeLocalTranscriptionRunning {
    let result: NativeProcessResult
    private(set) var commands: [String] = []
    private(set) var inputs: [Data] = []
    private(set) var timeouts: [TimeInterval] = []

    init(result: NativeProcessResult) { self.result = result }

    func run(command: String, input: Data, timeout: TimeInterval) -> NativeProcessResult {
        commands.append(command)
        inputs.append(input)
        timeouts.append(timeout)
        return result
    }
}
