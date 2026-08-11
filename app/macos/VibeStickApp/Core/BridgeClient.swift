import Foundation

actor BridgeClient {
    private let session: URLSession
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "http://127.0.0.1:8765")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    func fetchSnapshot() async -> BridgeSnapshot {
        let checkedAt = Date()
        async let health = fetchHealth()
        async let state: BridgeStateDTO? = try? fetch(path: "state")
        let fetchedHealth = await health
        let fetchedState = await state

        return BridgeSnapshot(
            health: fetchedHealth.value,
            state: fetchedState,
            healthEndpointResponded: fetchedHealth.endpointResponded,
            errorMessage: fetchedHealth.value == nil ? BridgeClientError.invalidResponse.localizedDescription : nil,
            checkedAt: checkedAt
        )
    }

    private func fetchHealth() async -> BridgeHealthFetchResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2.5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard response is HTTPURLResponse else {
                return BridgeHealthFetchResult(value: nil, endpointResponded: false)
            }
            return BridgeHealthFetchResult(
                value: try? JSONDecoder().decode(BridgeHealthDTO.self, from: data),
                endpointResponded: true
            )
        } catch {
            return BridgeHealthFetchResult(value: nil, endpointResponded: false)
        }
    }

    private func fetch<Value: Decodable & Sendable>(path: String) async throws -> Value {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 2.5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeClientError.invalidResponse
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

private struct BridgeHealthFetchResult: Sendable {
    let value: BridgeHealthDTO?
    let endpointResponded: Bool
}

enum BridgeClientError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "本机连接服务暂时没有返回有效状态"
    }
}
