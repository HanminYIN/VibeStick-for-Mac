import Foundation

protocol ASRSecretManaging: Sendable {
    func containsAPIKey() async -> Bool
    func storedAPIKey() async throws -> String?
    func saveAPIKey(_ value: String) async throws
    func deleteAPIKey() async throws
}

actor ASRKeychainManager: ASRSecretManaging {
    private let store: KeychainStore

    init(store: KeychainStore = KeychainStore()) {
        self.store = store
    }

    func containsAPIKey() -> Bool {
        store.contains(.asrAPIKey)
    }

    func storedAPIKey() throws -> String? {
        guard let data = try store.read(.asrAPIKey),
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    func saveAPIKey(_ value: String) throws {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ASRConfigurationError.missingAPIKey }
        try store.write(Data(cleaned.utf8), for: .asrAPIKey)
    }

    func deleteAPIKey() throws {
        try store.delete(.asrAPIKey)
    }
}

struct ASRTestAudioFixture: Sendable {
    static let expectedTranscript = "语音测试成功"

    let audioURL: URL
    let expectedTranscript: String
}

protocol ASRTestAudioProviding: Sendable {
    func makeFixture() async throws -> ASRTestAudioFixture
}

actor ASRTestAudioGenerator: ASRTestAudioProviding {
    func makeFixture() async throws -> ASRTestAudioFixture {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let audioURL = fileManager.temporaryDirectory
                .appendingPathComponent("VibeStick-ASR-Fixture-\(UUID().uuidString).wav")
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = [
                "-v", "Tingting",
                "-o", audioURL.path,
                "--file-format=WAVE",
                "--data-format=LEI16@16000",
                ASRTestAudioFixture.expectedTranscript,
            ]
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                process.waitUntilExit()
                let diagnostics = String(
                    decoding: (try output.fileHandleForReading.readToEnd() ?? Data()).prefix(4_096),
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus == 0 else {
                    throw ASRTestAudioError.synthesisFailed(
                        diagnostics.isEmpty
                            ? "macOS 语音合成返回退出码 \(process.terminationStatus)。"
                            : diagnostics
                    )
                }
                let attributes = try fileManager.attributesOfItem(atPath: audioURL.path)
                let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
                guard byteCount > 4_096 else { throw ASRTestAudioError.emptyFixture }
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioURL.path)
                return ASRTestAudioFixture(
                    audioURL: audioURL,
                    expectedTranscript: ASRTestAudioFixture.expectedTranscript
                )
            } catch {
                try? fileManager.removeItem(at: audioURL)
                if let audioError = error as? ASRTestAudioError { throw audioError }
                throw ASRTestAudioError.synthesisFailed(error.localizedDescription)
            }
        }.value
    }
}

protocol ASRTesting: Sendable {
    func test(
        audioURL: URL,
        expectedTranscript: String,
        configuration: ASRConfiguration,
        apiKey: String?
    ) async -> ASRTestFeedback
}

actor ASRTestService: ASRTesting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func test(
        audioURL: URL,
        expectedTranscript: String,
        configuration: ASRConfiguration,
        apiKey: String?
    ) async -> ASRTestFeedback {
        do {
            let configuration = try configuration.validated()
            if configuration.provider == .localCommand {
                return await runLocalCommand(
                    audioURL: audioURL,
                    expectedTranscript: expectedTranscript,
                    configuration: configuration
                )
            }
            return await runCloudTest(
                audioURL: audioURL,
                expectedTranscript: expectedTranscript,
                configuration: configuration,
                apiKey: apiKey
            )
        } catch {
            return .failure("配置尚未就绪", detail: error.localizedDescription)
        }
    }

    private func runCloudTest(
        audioURL: URL,
        expectedTranscript: String,
        configuration: ASRConfiguration,
        apiKey: String?
    ) async -> ASRTestFeedback {
        guard let endpoint = configuration.transcriptionURL else {
            return .failure("转写地址无效", detail: ASRConfigurationError.invalidURL.localizedDescription)
        }
        let cleanedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if configuration.requiresAPIKey && cleanedKey.isEmpty {
            return .failure("缺少 API Key", detail: ASRConfigurationError.missingAPIKey.localizedDescription)
        }

        let audio: Data
        do {
            audio = try Data(contentsOf: audioURL)
        } catch {
            return .failure("无法读取固定测试音频", detail: "本地生成的临时样本不可用，请重试。")
        }
        guard !audio.isEmpty else {
            return .failure("固定测试音频为空", detail: "macOS 没有生成可用的测试样本，请重试。")
        }

        let boundary = "VibeStickM3C-" + UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("VibeStick-for-Mac/0.2", forHTTPHeaderField: "User-Agent")
        if !cleanedKey.isEmpty {
            request.setValue("Bearer \(cleanedKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = multipartBody(
            boundary: boundary,
            audioURL: audioURL,
            audio: audio,
            configuration: configuration
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("供应方响应无效", detail: "没有收到可识别的 HTTP 响应。")
            }
            guard 200..<300 ~= http.statusCode else {
                return feedback(forHTTPStatus: http.statusCode)
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let transcript = (object["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !transcript.isEmpty else {
                return .failure("响应格式不兼容", detail: "请求成功，但响应中没有可用的 text 字段。")
            }
            return Self.transcriptFeedback(
                transcript: transcript,
                expectedTranscript: expectedTranscript,
                successTitle: "测试通过：转写匹配"
            )
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return .failure("请求超时", detail: "供应方没有在 30 秒内返回，请检查网络或稍后重试。")
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                return .failure("网络不可达", detail: "无法连接到 \(configuration.targetHost ?? "所选供应方")。")
            default:
                return .failure("供应方测试失败", detail: error.localizedDescription)
            }
        } catch {
            return .failure("供应方测试失败", detail: error.localizedDescription)
        }
    }

    private func runLocalCommand(
        audioURL: URL,
        expectedTranscript: String,
        configuration: ASRConfiguration
    ) async -> ASRTestFeedback {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", configuration.localCommand]
            process.standardOutput = output
            process.standardError = output
            process.standardInput = input
            var environment = ProcessInfo.processInfo.environment
            environment["VIBE_STICK_TEST_AUDIO"] = audioURL.path
            environment["VIBE_STICK_ASR_TEST_ONLY"] = "1"
            process.environment = environment

            let payload = [
                "audio_file": audioURL.path,
                "test_only": true,
                "inject_text": false,
            ] as [String: Any]
            do {
                try process.run()
                if let data = try? JSONSerialization.data(withJSONObject: payload) {
                    try? input.fileHandleForWriting.write(contentsOf: data)
                }
                try? input.fileHandleForWriting.close()
                let data = try output.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                let text = String(decoding: data.prefix(16_384), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus == 0 else {
                    return .failure(
                        "本地命令失败",
                        detail: text.isEmpty ? "命令退出码为 \(process.terminationStatus)。" : String(text.prefix(240))
                    )
                }
                guard !text.isEmpty else {
                    return .failure("本地命令没有返回文字", detail: "命令应把最终转写写到 stdout。")
                }
                return Self.transcriptFeedback(
                    transcript: text,
                    expectedTranscript: expectedTranscript,
                    successTitle: "本地测试通过：转写匹配"
                )
            } catch {
                return .failure("无法运行本地命令", detail: error.localizedDescription)
            }
        }.value
    }

    private func multipartBody(
        boundary: String,
        audioURL: URL,
        audio: Data,
        configuration: ASRConfiguration
    ) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        func addField(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append(value)
            append("\r\n")
        }

        addField("model", configuration.model)
        if configuration.provider != .siliconFlow {
            addField("response_format", "json")
            addField("temperature", "0")
            if !configuration.language.isEmpty { addField("language", configuration.language) }
        }
        append("--\(boundary)\r\n")
        let fileExtension = audioURL.pathExtension.lowercased()
        let safeExtension = fileExtension.isEmpty ? "wav" : fileExtension
        let contentType = safeExtension == "wav" ? "audio/wav" : "application/octet-stream"
        append("Content-Disposition: form-data; name=\"file\"; filename=\"vibestick-asr-test.\(safeExtension)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private nonisolated static func transcriptFeedback(
        transcript: String,
        expectedTranscript: String,
        successTitle: String
    ) -> ASRTestFeedback {
        let preview = String(transcript.prefix(240))
        guard ASRTestTranscriptComparator.matches(expected: expectedTranscript, actual: transcript) else {
            return ASRTestFeedback(
                phase: .failure,
                title: "测试完成：文字未匹配",
                detail: "供应方已返回转写，但与固定样本“\(expectedTranscript)”不一致。结果仅显示在本页内存中。",
                transcriptPreview: preview
            )
        }
        return ASRTestFeedback(
            phase: .success,
            title: successTitle,
            detail: "固定样本已被正确识别；结果没有复制、粘贴或发送到当前输入框。",
            transcriptPreview: preview
        )
    }

    private func feedback(forHTTPStatus status: Int) -> ASRTestFeedback {
        switch status {
        case 401, 403:
            .failure("API Key 无效", detail: "供应方拒绝了鉴权，请检查 Key 是否属于当前供应方。")
        case 404:
            .failure("模型或地址不存在", detail: "请检查 Base URL、转写路径和模型名称。")
        case 408, 504:
            .failure("请求超时", detail: "供应方没有及时完成转写，请稍后重试。")
        case 429:
            .failure("触发限流", detail: "当前请求额度或速率受限，请稍后重试。")
        case 500...599:
            .failure("供应方暂时不可用", detail: "服务返回 HTTP \(status)，请稍后重试。")
        default:
            .failure("供应方拒绝请求", detail: "服务返回 HTTP \(status)，请检查配置。")
        }
    }
}

enum ASRTestAudioError: LocalizedError {
    case synthesisFailed(String)
    case emptyFixture

    var errorDescription: String? {
        switch self {
        case let .synthesisFailed(detail): "无法生成固定测试音频：\(detail)"
        case .emptyFixture: "macOS 生成的固定测试音频为空。"
        }
    }
}
