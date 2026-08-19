import AVFoundation
import Darwin
import Foundation

enum NativeVoiceAdapterError: Error {
    case invalidAudioFormat
    case invalidConfiguration
    case unavailable
}

final class NativeVoiceFileAudioStore: NativeVoiceAudioStore {
    static let speechWindowSeconds = 0.10
    static let speechRMSThreshold = 900.0
    static let speechEdgeIgnoreSeconds = 0.18
    static let maximumAudioBytes = 25 * 1_024 * 1_024

    private let recordingsDirectory: URL

    init(recordingsDirectory: URL) {
        self.recordingsDirectory = recordingsDirectory
    }

    func writePCM(
        _ data: Data,
        sessionID: String,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) throws -> URL {
        guard !data.isEmpty,
              data.count <= Self.maximumAudioBytes,
              nativeVoiceAdapterSessionID(sessionID),
              (8_000...96_000).contains(sampleRate),
              (1...8).contains(channels),
              bitsPerSample == 16,
              data.count.isMultiple(of: channels * 2) else {
            throw NativeVoiceAdapterError.invalidAudioFormat
        }
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: recordingsDirectory.path
        )
        let destination = recordingsDirectory.appendingPathComponent("\(sessionID).wav")
        var wave = Data()
        wave.append(Data("RIFF".utf8))
        wave.appendLittleEndian(UInt32(36 + data.count))
        wave.append(Data("WAVEfmt ".utf8))
        wave.appendLittleEndian(UInt32(16))
        wave.appendLittleEndian(UInt16(1))
        wave.appendLittleEndian(UInt16(channels))
        wave.appendLittleEndian(UInt32(sampleRate))
        wave.appendLittleEndian(UInt32(sampleRate * channels * bitsPerSample / 8))
        wave.appendLittleEndian(UInt16(channels * bitsPerSample / 8))
        wave.appendLittleEndian(UInt16(bitsPerSample))
        wave.append(Data("data".utf8))
        wave.appendLittleEndian(UInt32(data.count))
        wave.append(data)
        try NativeBridgeSecureFile.writeDataAtomically(wave, to: destination)
        return destination
    }

    func metrics(for url: URL) -> NativeVoiceAudioMetrics? {
        guard url.pathExtension.lowercased() == "wav",
              let data = try? NativeBridgeSecureFile.readData(
                at: url,
                maximumBytes: Self.maximumAudioBytes + 4_096
              ),
              let wave = Self.parseWave(data) else { return nil }
        let samples = stride(from: 0, to: wave.pcm.count, by: 2).map { offset -> Double in
            let low = UInt16(wave.pcm[offset])
            let high = UInt16(wave.pcm[offset + 1]) << 8
            return Double(Int16(bitPattern: low | high))
        }
        guard !samples.isEmpty else {
            return NativeVoiceAudioMetrics(
                durationSeconds: 0,
                audioBytes: 0,
                rms: 0,
                acRMS: 0,
                speechSeconds: 0,
                speechWindows: 0
            )
        }
        let sampleFrames = samples.count / wave.channels
        let duration = Double(sampleFrames) / Double(wave.sampleRate)
        let mean = samples.reduce(0, +) / Double(samples.count)
        let squareSum = samples.reduce(0) { $0 + $1 * $1 }
        let acSquareSum = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let rms = sqrt(squareSum / Double(samples.count))
        let acRMS = sqrt(acSquareSum / Double(samples.count))

        let windowFrames = max(1, Int(Double(wave.sampleRate) * Self.speechWindowSeconds))
        let windowSamples = windowFrames * wave.channels
        let edgeWindows = Int(ceil(Self.speechEdgeIgnoreSeconds / Self.speechWindowSeconds))
        var windowRMS: [Double] = []
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + windowSamples)
            let chunk = Array(samples[start..<end])
            if chunk.count >= max(1, windowSamples / 2) {
                let chunkMean = chunk.reduce(0, +) / Double(chunk.count)
                let sum = chunk.reduce(0) { $0 + ($1 - chunkMean) * ($1 - chunkMean) }
                windowRMS.append(sqrt(sum / Double(chunk.count)))
            }
            start += windowSamples
        }
        let speechWindows = windowRMS.indices.filter { index in
            index >= edgeWindows
                && index < windowRMS.count - edgeWindows
                && windowRMS[index] >= Self.speechRMSThreshold
        }.count
        return NativeVoiceAudioMetrics(
            durationSeconds: duration,
            audioBytes: wave.pcm.count,
            rms: rms,
            acRMS: acRMS,
            speechSeconds: Double(speechWindows) * Self.speechWindowSeconds,
            speechWindows: speechWindows
        )
    }

    private struct WaveData {
        let sampleRate: Int
        let channels: Int
        let pcm: Data
    }

    private static func parseWave(_ data: Data) -> WaveData? {
        guard data.count >= 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        var offset = 12
        var sampleRate = 0
        var channels = 0
        var bitsPerSample = 0
        var pcm: Data?
        while offset + 8 <= data.count {
            let name = String(data: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            guard let size = data.uint32LittleEndian(at: offset + 4),
                  Int(size) <= data.count - offset - 8 else { return nil }
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + Int(size)
            if name == "fmt ", size >= 16,
               let format = data.uint16LittleEndian(at: payloadStart),
               let channelValue = data.uint16LittleEndian(at: payloadStart + 2),
               let rateValue = data.uint32LittleEndian(at: payloadStart + 4),
               let bitValue = data.uint16LittleEndian(at: payloadStart + 14),
               format == 1 {
                channels = Int(channelValue)
                sampleRate = Int(rateValue)
                bitsPerSample = Int(bitValue)
            } else if name == "data" {
                pcm = Data(data[payloadStart..<payloadEnd])
            }
            offset = payloadEnd + (Int(size) % 2)
        }
        guard sampleRate > 0,
              (1...8).contains(channels),
              bitsPerSample == 16,
              let pcm,
              !pcm.isEmpty,
              pcm.count.isMultiple(of: channels * 2) else { return nil }
        return WaveData(sampleRate: sampleRate, channels: channels, pcm: pcm)
    }
}

final class NativeAVFoundationRecorder: NSObject, NativeVoiceRecorder, AVAudioRecorderDelegate, @unchecked Sendable {
    private let recordingsDirectory: URL
    private let permissionTimeout: TimeInterval
    private let lock = NSLock()
    private var audioRecorder: AVAudioRecorder?
    private var audioURL: URL?

    init(recordingsDirectory: URL, permissionTimeout: TimeInterval = 60) {
        self.recordingsDirectory = recordingsDirectory
        self.permissionTimeout = max(1, min(120, permissionTimeout))
    }

    func start(sessionID: String) -> NativeVoiceRecorderResult? {
        guard nativeVoiceAdapterSessionID(sessionID) else {
            return NativeVoiceRecorderResult(success: false, audioFile: nil, message: "Invalid recording session")
        }
        lock.lock()
        defer { lock.unlock() }
        if audioRecorder?.isRecording == true {
            return NativeVoiceRecorderResult(
                success: false,
                audioFile: audioURL,
                message: "A recording session is already active"
            )
        }
        guard microphoneAuthorized() else {
            return NativeVoiceRecorderResult(
                success: false,
                audioFile: nil,
                message: "Microphone permission was denied"
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: recordingsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: recordingsDirectory.path
            )
            let url = recordingsDirectory.appendingPathComponent("\(sessionID).m4a")
            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
            )
            recorder.delegate = self
            guard recorder.record() else {
                return NativeVoiceRecorderResult(
                    success: false,
                    audioFile: url,
                    message: "AVFoundation failed to start recording"
                )
            }
            audioRecorder = recorder
            audioURL = url
            return NativeVoiceRecorderResult(
                success: true,
                audioFile: url,
                message: "Recording from Mac microphone"
            )
        } catch {
            return NativeVoiceRecorderResult(
                success: false,
                audioFile: nil,
                message: "Could not start Mac microphone recording"
            )
        }
    }

    func stop() -> NativeVoiceRecorderResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let recorder = audioRecorder else { return nil }
        let url = audioURL
        recorder.stop()
        audioRecorder = nil
        audioURL = nil
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            return NativeVoiceRecorderResult(
                success: false,
                audioFile: url,
                message: "Mac microphone produced no audio"
            )
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
        return NativeVoiceRecorderResult(success: true, audioFile: url, message: "Recording stopped")
    }

    private func microphoneAuthorized() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            let box = NativePermissionBox()
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                box.lock.lock()
                box.granted = granted
                box.lock.unlock()
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + permissionTimeout) == .success else { return false }
            box.lock.lock()
            defer { box.lock.unlock() }
            return box.granted
        @unknown default:
            return false
        }
    }
}

private final class NativePermissionBox: @unchecked Sendable {
    let lock = NSLock()
    var granted = false
}

struct NativeASRConfiguration: Equatable {
    let provider: String
    let baseURL: URL
    let apiKey: String
    let model: String
    let language: String
    let attempts: Int
    let timeout: TimeInterval

    static func normalized(
        provider rawProvider: String,
        baseURL rawBaseURL: String,
        apiKey: String,
        model: String,
        language: String,
        attempts: Int = 2,
        timeout: TimeInterval = 15
    ) -> NativeASRConfiguration? {
        let provider = rawProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["groq", "siliconflow", "openai-compatible"].contains(provider),
              let baseURL = URL(string: rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = baseURL.scheme?.lowercased(),
              let host = baseURL.host?.lowercased(),
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback),
              loopback || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return NativeASRConfiguration(
            provider: provider,
            baseURL: baseURL,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            language: language.trimmingCharacters(in: .whitespacesAndNewlines),
            attempts: max(1, min(5, attempts)),
            timeout: max(3, min(60, timeout))
        )
    }

    var label: String {
        switch provider {
        case "groq": return "Groq"
        case "siliconflow": return "SiliconFlow"
        default: return "OpenAI-compatible"
        }
    }

    var transcriptionURL: URL {
        if baseURL.path.hasSuffix("/audio/transcriptions") { return baseURL }
        return baseURL.appendingPathComponent("audio/transcriptions")
    }
}

struct NativeASRTransportResponse {
    let statusCode: Int
    let data: Data
}

protocol NativeASRTransport: AnyObject {
    func send(_ request: URLRequest, timeout: TimeInterval) -> Result<NativeASRTransportResponse, Error>
}

final class NativeURLSessionASRTransport: NativeASRTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest, timeout: TimeInterval) -> Result<NativeASRTransportResponse, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = NativeASRResultBox()
        var configured = request
        configured.timeoutInterval = timeout
        let task = session.dataTask(with: configured) { data, response, error in
            box.lock.lock()
            defer { box.lock.unlock() }
            if let error {
                box.result = .failure(error)
            } else if let response = response as? HTTPURLResponse {
                box.result = .success(NativeASRTransportResponse(
                    statusCode: response.statusCode,
                    data: data ?? Data()
                ))
            } else {
                box.result = .failure(NativeVoiceAdapterError.unavailable)
            }
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout + 1) == .success else {
            task.cancel()
            return .failure(URLError(.timedOut))
        }
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.result ?? .failure(NativeVoiceAdapterError.unavailable)
    }
}

private final class NativeASRResultBox: @unchecked Sendable {
    let lock = NSLock()
    var result: Result<NativeASRTransportResponse, Error>?
}

final class NativeOpenAICompatibleTranscriber: NativeVoiceTranscriber {
    private let configuration: NativeASRConfiguration?
    private let transport: NativeASRTransport
    private let retryDelay: (TimeInterval) -> Void

    init(
        configuration: NativeASRConfiguration?,
        transport: NativeASRTransport = NativeURLSessionASRTransport(),
        retryDelay: @escaping (TimeInterval) -> Void = Thread.sleep
    ) {
        self.configuration = configuration
        self.transport = transport
        self.retryDelay = retryDelay
    }

    func transcribe(
        session: NativeVoiceRecordingSession,
        explicitText: String
    ) -> NativeVoiceTranscriptionResult {
        let supplied = explicitText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !supplied.isEmpty {
            return NativeVoiceTranscriptionResult(
                text: supplied,
                success: true,
                message: "Transcript supplied by request",
                source: "request"
            )
        }
        guard let configuration else {
            return failure("No transcription adapter configured", source: "none")
        }
        guard !session.audioFile.isEmpty,
              let audio = try? NativeBridgeSecureFile.readData(
                at: URL(fileURLWithPath: session.audioFile),
                maximumBytes: NativeVoiceFileAudioStore.maximumAudioBytes + 4_096
              ),
              !audio.isEmpty else {
            return failure("No audio file available for transcription", source: "none")
        }
        var last = failure("\(configuration.label) transcription failed", source: configuration.provider)
        for attempt in 1...configuration.attempts {
            guard let request = Self.request(
                configuration: configuration,
                audioFileName: URL(fileURLWithPath: session.audioFile).lastPathComponent,
                audio: audio
            ) else {
                return failure("Could not prepare transcription request", source: configuration.provider)
            }
            switch transport.send(request, timeout: configuration.timeout) {
            case .success(let response):
                if response.statusCode == 200 {
                    guard response.data.count <= 1_048_576,
                          let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                          let text = object["text"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return failure("\(configuration.label) returned no transcript", source: configuration.provider)
                    }
                    return NativeVoiceTranscriptionResult(
                        text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        success: true,
                        message: "Transcript supplied by \(configuration.label) ASR",
                        source: configuration.provider
                    )
                }
                last = failure(
                    "\(configuration.label) transcription failed on attempt \(attempt): HTTP \(response.statusCode)",
                    source: configuration.provider
                )
                guard Self.retryableHTTPStatus(response.statusCode), attempt < configuration.attempts else {
                    return last
                }
            case .failure(let error):
                let code = (error as? URLError)?.code
                last = failure(
                    "\(configuration.label) transcription failed on attempt \(attempt)",
                    source: configuration.provider
                )
                guard Self.retryableURLCode(code), attempt < configuration.attempts else { return last }
            }
            retryDelay(min(2, 0.4 * Double(attempt)))
        }
        return last
    }

    static func request(
        configuration: NativeASRConfiguration,
        audioFileName: String,
        audio: Data,
        boundary: String = "VibeStickASR-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    ) -> URLRequest? {
        guard !audio.isEmpty,
              audio.count <= NativeVoiceFileAudioStore.maximumAudioBytes + 4_096 else { return nil }
        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        addField("model", configuration.model)
        if configuration.provider != "siliconflow" {
            addField("response_format", "json")
            addField("temperature", "0")
            if !configuration.language.isEmpty { addField("language", configuration.language) }
        }
        let safeName = nativeVoiceSafeFilename(audioFileName)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(nativeVoiceContentType(safeName))\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: configuration.transcriptionURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("VibeStick/0.2 macOS", forHTTPHeaderField: "User-Agent")
        request.setValue("close", forHTTPHeaderField: "Connection")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func failure(_ message: String, source: String) -> NativeVoiceTranscriptionResult {
        NativeVoiceTranscriptionResult(text: "", success: false, message: message, source: source)
    }

    private static func retryableHTTPStatus(_ status: Int) -> Bool {
        [408, 409, 425, 429, 500, 502, 503, 504].contains(status)
    }

    private static func retryableURLCode(_ code: URLError.Code?) -> Bool {
        guard let code else { return false }
        return [
            .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
        ].contains(code)
    }
}

protocol NativeLocalTranscriptionRunning: AnyObject {
    func run(command: String, input: Data, timeout: TimeInterval) -> NativeProcessResult
}

final class NativeLocalTranscriptionProcessRunner: NativeLocalTranscriptionRunning {
    private let temporaryRoot: URL

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.temporaryRoot = temporaryRoot
    }

    func run(command: String, input: Data, timeout: TimeInterval) -> NativeProcessResult {
        let directory = temporaryRoot.appendingPathComponent(
            "vibestick-local-asr-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let inputURL = directory.appendingPathComponent("request.json")
            let outputURL = directory.appendingPathComponent("stdout.txt")
            let errorURL = directory.appendingPathComponent("stderr.txt")
            try NativeBridgeSecureFile.writeDataAtomically(input, to: inputURL)
            guard FileManager.default.createFile(
                atPath: outputURL.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            ), FileManager.default.createFile(
                atPath: errorURL.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            ) else {
                return NativeProcessResult(exitCode: 127, standardOutput: Data(), standardError: Data())
            }
            let process = Process()
            let inputHandle = try FileHandle(forReadingFrom: inputURL)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            defer {
                try? inputHandle.close()
                try? outputHandle.close()
                try? errorHandle.close()
            }
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardInput = inputHandle
            process.standardOutput = outputHandle
            process.standardError = errorHandle
            let semaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in semaphore.signal() }
            try process.run()
            if semaphore.wait(timeout: .now() + max(5, min(600, timeout))) != .success {
                process.terminate()
                if semaphore.wait(timeout: .now() + 1) != .success {
                    kill(process.processIdentifier, SIGKILL)
                    _ = semaphore.wait(timeout: .now() + 1)
                }
            }
            try? outputHandle.synchronize()
            try? errorHandle.synchronize()
            let output = (try? NativeBridgeSecureFile.readData(
                at: outputURL,
                maximumBytes: 65_536
            )) ?? nil
            let error = (try? NativeBridgeSecureFile.readData(
                at: errorURL,
                maximumBytes: 8_192
            )) ?? nil
            return NativeProcessResult(
                exitCode: process.terminationStatus,
                standardOutput: output ?? Data(),
                standardError: error ?? Data()
            )
        } catch {
            return NativeProcessResult(exitCode: 127, standardOutput: Data(), standardError: Data())
        }
    }
}

final class NativeLocalCommandTranscriber: NativeVoiceTranscriber {
    private let command: String
    private let runner: NativeLocalTranscriptionRunning
    private let timeout: TimeInterval

    init(
        command: String,
        runner: NativeLocalTranscriptionRunning = NativeLocalTranscriptionProcessRunner(),
        timeout: TimeInterval = 120
    ) {
        self.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runner = runner
        self.timeout = max(5, min(600, timeout))
    }

    func transcribe(
        session: NativeVoiceRecordingSession,
        explicitText: String
    ) -> NativeVoiceTranscriptionResult {
        let supplied = explicitText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !supplied.isEmpty {
            return NativeVoiceTranscriptionResult(
                text: supplied,
                success: true,
                message: "Transcript supplied by request",
                source: "request"
            )
        }
        guard !command.isEmpty, !session.audioFile.isEmpty else {
            return failure("No transcription adapter configured")
        }
        let payload: [String: Any] = [
            "schema_version": 2,
            "session_id": session.sessionID,
            "audio_file": session.audioFile,
            "audio_source": session.audioSource,
            "started_at": session.startedAt,
            "stopped_at": session.stoppedAt,
            "interaction_version": session.interactionVersion,
        ]
        guard let input = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return failure("Could not prepare transcription command")
        }
        let result = runner.run(command: command, input: input, timeout: timeout)
        guard result.exitCode == 0 else {
            return failure("Transcription command failed")
        }
        guard result.standardOutput.count <= 65_536,
              let text = String(data: result.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return failure("Transcription command returned no text")
        }
        return NativeVoiceTranscriptionResult(
            text: text,
            success: true,
            message: "Transcript supplied by local command",
            source: "command"
        )
    }

    private func failure(_ message: String) -> NativeVoiceTranscriptionResult {
        NativeVoiceTranscriptionResult(text: "", success: false, message: message, source: "command")
    }
}

struct NativeProcessResult {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
}

protocol NativeProcessRunning: AnyObject {
    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> NativeProcessResult
}

final class NativeBoundedProcessRunner: NativeProcessRunning {
    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> NativeProcessResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            return NativeProcessResult(exitCode: 127, standardOutput: Data(), standardError: Data())
        }
        if semaphore.wait(timeout: .now() + max(0.1, timeout)) != .success {
            process.terminate()
            if semaphore.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        return NativeProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: output.fileHandleForReading.readDataToEndOfFile(),
            standardError: error.fileHandleForReading.readDataToEndOfFile()
        )
    }
}

final class NativePasteHelperClient: NativeVoicePasteClient {
    private let helperApp: URL
    private let runner: NativeProcessRunning
    private let temporaryRoot: URL

    init(
        helperApp: URL,
        runner: NativeProcessRunning = NativeBoundedProcessRunner(),
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.helperApp = helperApp
        self.runner = runner
        self.temporaryRoot = temporaryRoot
    }

    func paste(text: String, pressEnter: Bool) -> NativeVoicePasteResult {
        invoke([
            "operation": "paste",
            "text": text.trimmingCharacters(in: .whitespacesAndNewlines),
            "press_enter": pressEnter,
        ])
    }

    func inspectTarget(expected: NativeSendTarget) -> NativeVoicePasteResult {
        invoke(["operation": "inspect_target", "expected_target": expected.jsonObject()])
    }

    func confirmReturn(expected: NativeSendTarget) -> NativeVoicePasteResult {
        let result = invoke(["operation": "confirm_return", "expected_target": expected.jsonObject()])
        guard !result.success || result.target == expected else {
            return NativeVoicePasteResult(
                success: false,
                message: "VibeStick Paste confirmed a different target",
                target: result.target,
                delivery: result.delivery
            )
        }
        return result
    }

    private func invoke(_ request: [String: Any]) -> NativeVoicePasteResult {
        guard FileManager.default.fileExists(atPath: helperApp.path),
              helperApp.pathExtension == "app" else {
            return failure("VibeStick Paste helper not found")
        }
        let directory = temporaryRoot.appendingPathComponent("vibestick-paste-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let requestPath = directory.appendingPathComponent("request.json")
            let responsePath = directory.appendingPathComponent("response.json")
            try NativeBridgeSecureFile.writeJSONAtomically(request, to: requestPath)
            let process = runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: [
                    "-W", "-g", "-n", helperApp.path, "--args",
                    "--request", requestPath.path,
                    "--response", responsePath.path,
                ],
                timeout: 5
            )
            unregister()
            guard process.exitCode == 0,
                  let data = try NativeBridgeSecureFile.readData(at: responsePath, maximumBytes: 32_768),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return failure("VibeStick Paste helper returned no result")
            }
            let success = (object["success"] as? Bool) == true
            let target = NativeSendTarget.fromJSON(object["target"])
            let delivery = ["pasted", "pasted_compat", "clipboard"]
                .contains(object["delivery"] as? String ?? "")
                ? object["delivery"] as? String ?? "" : (success && target != nil ? "pasted" : "")
            return NativeVoicePasteResult(
                success: success,
                message: object["message"] as? String ?? "VibeStick Paste helper failed",
                target: target,
                delivery: delivery
            )
        } catch {
            return failure("VibeStick Paste helper failed")
        }
    }

    private func unregister() {
        let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        guard FileManager.default.isExecutableFile(atPath: path) else { return }
        _ = runner.run(
            executable: URL(fileURLWithPath: path),
            arguments: ["-u", helperApp.path],
            timeout: 2
        )
    }

    private func failure(_ message: String) -> NativeVoicePasteResult {
        NativeVoicePasteResult(success: false, message: message, target: nil, delivery: "")
    }
}

final class NativeHUDStateClient: NativeVoiceHUDClient {
    private static let text: [String: String] = [
        "listening": "正在聆听",
        "sending": "正在发送",
        "transcribing": "正在识别",
        "unclear": "未听清",
        "failed": "识别失败",
        "send_failed": "发送失败",
    ]

    private let path: URL
    private let clock: () -> TimeInterval

    init(path: URL, clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.path = path
        self.clock = clock
    }

    func show(_ state: String, holdSeconds: TimeInterval?) {
        let now = finiteNow()
        try? NativeBridgeSecureFile.writeJSONAtomically([
            "active": true,
            "status": state,
            "text": Self.text[state] ?? state,
            "updated_at_epoch": now,
            "expires_at_epoch": holdSeconds.map { now + max(0, $0) } ?? NSNull(),
        ], to: path)
    }

    func hide(delaySeconds: TimeInterval?) {
        let now = finiteNow()
        if let delaySeconds, delaySeconds > 0,
           let data = try? NativeBridgeSecureFile.readData(at: path, maximumBytes: 16_384),
           let current = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           current["active"] as? Bool == true,
           let status = current["status"] as? String,
           let text = current["text"] as? String,
           nativeHUDUnexpired(current["expires_at_epoch"], now: now) {
            try? NativeBridgeSecureFile.writeJSONAtomically([
                "active": true,
                "status": status,
                "text": text,
                "updated_at_epoch": now,
                "expires_at_epoch": now + delaySeconds,
            ], to: path)
            return
        }
        try? NativeBridgeSecureFile.writeJSONAtomically([
            "active": false,
            "status": "idle",
            "text": "",
            "updated_at_epoch": now,
            "expires_at_epoch": NSNull(),
        ], to: path)
    }

    private func finiteNow() -> TimeInterval {
        let value = clock()
        return value.isFinite && value >= 0 ? value : 0
    }
}

private func nativeHUDUnexpired(_ raw: Any?, now: TimeInterval) -> Bool {
    if raw is NSNull || raw == nil { return true }
    guard let number = raw as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite else { return false }
    return number.doubleValue > now
}

private func nativeVoiceAdapterSessionID(_ value: String) -> Bool {
    (8...64).contains(value.count)
        && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
}

private func nativeVoiceSafeFilename(_ value: String) -> String {
    let name = value.unicodeScalars.map { scalar -> Character in
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return scalar.isASCII && allowed.contains(scalar) ? Character(String(scalar)) : "_"
    }
    let result = String(name.prefix(128))
    return result.isEmpty ? "recording.m4a" : result
}

private func nativeVoiceContentType(_ filename: String) -> String {
    switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
    case "wav": return "audio/wav"
    case "ogg": return "audio/ogg"
    case "mp3": return "audio/mpeg"
    default: return "audio/mp4"
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func uint16LittleEndian(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LittleEndian(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
