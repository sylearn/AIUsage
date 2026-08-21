import Foundation

nonisolated struct CLIProxyManagementClient: Sendable {
    private struct FilesResponse: Decodable { let files: [CLIProxyAuthFile] }
    private struct ModelsResponse: Decodable { let models: [CLIProxyModel] }
    private struct PublicModelsResponse: Decodable { let data: [CLIProxyModel] }
    private struct GeminiModelsResponse: Decodable {
        struct Model: Decodable {
            let name: String
            let displayName: String?
        }
        let models: [Model]
    }
    private struct APIErrorResponse: Decodable {
        let error: String?
        let message: String?
    }
    private struct PluginsResponse: Decodable {
        let pluginsEnabled: Bool
        let plugins: [CLIProxyPlugin]

        enum CodingKeys: String, CodingKey {
            case plugins
            case pluginsEnabled = "plugins_enabled"
        }
    }
    private struct PluginStoreResponse: Decodable {
        let pluginsEnabled: Bool
        let plugins: [CLIProxyPluginStoreEntry]

        enum CodingKeys: String, CodingKey {
            case plugins
            case pluginsEnabled = "plugins_enabled"
        }
    }
    private struct PluginInstallResponse: Decodable {
        let status: String
        let restartRequired: Bool?

        enum CodingKeys: String, CodingKey {
            case status
            case restartRequired = "restart_required"
        }
    }
    private struct OpenAICompatResponse: Decodable {
        let providers: [CLIProxyOpenAICompatibleProvider]

        enum CodingKeys: String, CodingKey {
            case providers = "openai-compatibility"
        }
    }
    private struct AuthFileFieldsRequest: Encodable {
        let name: String
        let note: String
        let priority: Int
    }
    private struct APICallRequest: Encodable {
        let authIndex: String
        let method: String
        let url: String
        let header: [String: String]
        let data: String

        enum CodingKeys: String, CodingKey {
            case authIndex = "auth_index"
            case method, url, header, data
        }
    }

    let baseURL: URL
    let managementKey: String
    let clientAPIKey: String
    var session: URLSession = .shared

    func listAuthFiles() async throws -> [CLIProxyAuthFile] {
        let response: FilesResponse = try await request(method: "GET", path: "v0/management/auth-files")
        return response.files
    }

    func downloadAuthFile(name: String) async throws -> Data {
        try Self.validateAuthFileName(name)
        return try await requestData(
            method: "GET",
            path: "v0/management/auth-files/download",
            query: [URLQueryItem(name: "name", value: name)]
        )
    }

    func models(forAuthFile name: String) async throws -> [CLIProxyModel] {
        let response: ModelsResponse = try await request(
            method: "GET",
            path: "v0/management/auth-files/models",
            query: [URLQueryItem(name: "name", value: name)]
        )
        return response.models
    }

    /// Runs a credential-scoped upstream request through CPA's protected
    /// management endpoint. `$TOKEN$` substitution and any supported refresh
    /// stay owned by CPA; AIUsage never reads the credential token here.
    func callUpstream(
        authIndex: String,
        method: String,
        url: URL,
        headers: [String: String],
        body: String = ""
    ) async throws -> CLIProxyUpstreamCallResult {
        let normalizedIndex = authIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIndex.isEmpty else {
            throw CLIProxyGatewayError.configuration("auth_index is required for an upstream check")
        }
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil else {
            throw CLIProxyGatewayError.configuration("upstream check URL is invalid")
        }
        let requestBody = try JSONEncoder().encode(APICallRequest(
            authIndex: normalizedIndex,
            method: method.uppercased(),
            url: url.absoluteString,
            header: headers,
            data: body
        ))
        return try await request(
            method: "POST",
            path: "v0/management/api-call",
            body: requestBody
        )
    }

    func availableModels() async throws -> [CLIProxyModel] {
        try await publicModels(
            path: "v1/models",
            headers: ["Authorization": "Bearer \(clientAPIKey)"]
        )
    }

    /// Returns the three protocol-specific model views exposed by CPA. The
    /// OpenAI list remains separate because it is the only list that should be
    /// written into AIUsage's Responses-compatible managed provider.
    func modelCatalog() async throws -> CLIProxyModelCatalogSnapshot {
        async let anthropicModels: [CLIProxyModel]? = try? await publicModels(
            path: "v1/models",
            headers: [
                "X-Api-Key": clientAPIKey,
                "Anthropic-Version": "2023-06-01"
            ]
        )
        async let geminiCatalogModels: [CLIProxyModel]? = try? await geminiModels()
        let openAIModels = try await availableModels()
        return CLIProxyModelCatalogBuilder.build(
            openAIModels: openAIModels,
            anthropicModels: await anthropicModels,
            geminiModels: await geminiCatalogModels
        )
    }

    func setDisabled(_ disabled: Bool, name: String) async throws {
        let body = try JSONEncoder().encode([
            "name": AnyCodable.string(name),
            "disabled": AnyCodable.bool(disabled)
        ])
        let _: EmptyResponse = try await request(
            method: "PATCH",
            path: "v0/management/auth-files/status",
            body: body
        )
    }

    func patchAuthFileFields(name: String, note: String, priority: Int) async throws {
        try Self.validateAuthFileName(name)
        let body = try JSONEncoder().encode(
            AuthFileFieldsRequest(
                name: name,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                priority: priority
            )
        )
        let _: EmptyResponse = try await request(
            method: "PATCH",
            path: "v0/management/auth-files/fields",
            body: body
        )
    }

    func deleteAuthFile(name: String) async throws {
        try Self.validateAuthFileName(name)
        let _: EmptyResponse = try await request(
            method: "DELETE",
            path: "v0/management/auth-files",
            query: [URLQueryItem(name: "name", value: name)]
        )
    }

    func uploadAuthFile(data: Data, name: String) async throws {
        try Self.validateAuthFileName(name)
        let _: EmptyResponse = try await request(
            method: "POST",
            path: "v0/management/auth-files",
            query: [URLQueryItem(name: "name", value: name)],
            body: data
        )
    }

    func beginOAuth(_ provider: CLIProxyOAuthProvider) async throws -> CLIProxyOAuthSession {
        try await beginOAuth(endpoint: provider.endpoint)
    }

    func beginPluginOAuth(providerID: String) async throws -> CLIProxyOAuthSession {
        let normalized = try safePathComponent(providerID)
        return try await beginOAuth(endpoint: "\(normalized)-auth-url")
    }

    func listPlugins() async throws -> (enabled: Bool, plugins: [CLIProxyPlugin]) {
        let response: PluginsResponse = try await request(method: "GET", path: "v0/management/plugins")
        return (response.pluginsEnabled, response.plugins)
    }

    func listPluginStore() async throws -> (enabled: Bool, plugins: [CLIProxyPluginStoreEntry]) {
        let response: PluginStoreResponse = try await request(method: "GET", path: "v0/management/plugin-store")
        return (response.pluginsEnabled, response.plugins)
    }

    @discardableResult
    func installPlugin(id: String, sourceID: String?) async throws -> Bool {
        let safeID = try safePathComponent(id)
        let response: PluginInstallResponse = try await request(
            method: "POST",
            path: "v0/management/plugin-store/\(safeID)/install",
            query: sourceID.flatMap { value in
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty ? nil : [URLQueryItem(name: "source", value: normalized)]
            } ?? [],
            timeout: 120
        )
        return response.restartRequired ?? false
    }

    func setPluginEnabled(id: String, enabled: Bool) async throws {
        let safeID = try safePathComponent(id)
        let body = try JSONEncoder().encode(["enabled": enabled])
        let _: EmptyResponse = try await request(
            method: "PATCH",
            path: "v0/management/plugins/\(safeID)/enabled",
            body: body
        )
    }

    func addOpenAICompatibleProvider(_ provider: CLIProxyOpenAICompatibleProvider) async throws {
        try await mutateOpenAICompatibleProviders { providers in
            guard !providers.contains(where: {
                (($0["name"] as? String) ?? "").caseInsensitiveCompare(provider.name) == .orderedSame
            }) else {
                throw CLIProxyGatewayError.configuration("an OpenAI-compatible provider with this name already exists")
            }
            let encoded = try JSONEncoder().encode(provider)
            guard let raw = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                throw CLIProxyGatewayError.invalidResponse("could not encode the OpenAI-compatible provider")
            }
            providers.append(raw)
        }
    }

    /// 按 name 覆盖写入；`replacingName` 用于改名时先移除旧条目。
    func upsertOpenAICompatibleProvider(
        _ provider: CLIProxyOpenAICompatibleProvider,
        replacingName: String? = nil
    ) async throws {
        try await mutateOpenAICompatibleProviders { providers in
            let namesToRemove = Set(
                [replacingName, provider.name]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { $0.lowercased() }
            )
            providers.removeAll { entry in
                let name = ((entry["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return namesToRemove.contains(name.lowercased())
            }
            let encoded = try JSONEncoder().encode(provider)
            guard let raw = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                throw CLIProxyGatewayError.invalidResponse("could not encode the OpenAI-compatible provider")
            }
            providers.append(raw)
        }
    }

    func listOpenAICompatibleProviders() async throws -> [CLIProxyOpenAICompatibleProvider] {
        let response: OpenAICompatResponse = try await request(
            method: "GET",
            path: "v0/management/openai-compatibility"
        )
        return response.providers
    }

    func setOpenAICompatibleProviderDisabled(name: String, disabled: Bool) async throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CLIProxyGatewayError.configuration("OpenAI-compatible provider name is required")
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "name": normalized,
            "value": ["disabled": disabled]
        ])
        let _: EmptyResponse = try await request(
            method: "PATCH",
            path: "v0/management/openai-compatibility",
            body: body
        )
    }

    func deleteOpenAICompatibleProvider(name: String) async throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CLIProxyGatewayError.configuration("OpenAI-compatible provider name is required")
        }
        let _: EmptyResponse = try await request(
            method: "DELETE",
            path: "v0/management/openai-compatibility",
            query: [URLQueryItem(name: "name", value: normalized)]
        )
    }

    private func mutateOpenAICompatibleProviders(
        _ update: (inout [[String: Any]]) throws -> Void
    ) async throws {
        let data = try await requestData(method: "GET", path: "v0/management/openai-compatibility")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var providers = root["openai-compatibility"] as? [[String: Any]] else {
            throw CLIProxyGatewayError.invalidResponse("invalid OpenAI-compatible provider response")
        }
        try update(&providers)
        guard JSONSerialization.isValidJSONObject(providers) else {
            throw CLIProxyGatewayError.invalidResponse("OpenAI-compatible provider configuration is not valid JSON")
        }
        let body = try JSONSerialization.data(withJSONObject: providers, options: [.sortedKeys])
        let _: EmptyResponse = try await request(
            method: "PUT",
            path: "v0/management/openai-compatibility",
            body: body
        )
    }

    private func beginOAuth(endpoint: String) async throws -> CLIProxyOAuthSession {
        try await request(
            method: "GET",
            path: "v0/management/\(endpoint)",
            query: [URLQueryItem(name: "is_webui", value: "true")]
        )
    }

    func oauthStatus(state: String) async throws -> CLIProxyOAuthStatus {
        try await request(
            method: "GET",
            path: "v0/management/get-auth-status",
            query: [URLQueryItem(name: "state", value: state)]
        )
    }

    func cancelOAuth(state: String) async throws {
        let _: EmptyResponse = try await request(
            method: "DELETE",
            path: "v0/management/oauth-session",
            query: [URLQueryItem(name: "state", value: state)]
        )
    }

    private func request<T: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws -> T {
        let data = try await requestData(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body,
            timeout: timeout
        )
        if T.self == EmptyResponse.self, data.isEmpty { return EmptyResponse() as! T }
        return try decode(T.self, from: data)
    }

    private func publicModels(path: String, headers: [String: String]) async throws -> [CLIProxyModel] {
        let data = try await publicData(path: path, headers: headers)
        return try decode(PublicModelsResponse.self, from: data).data
    }

    private func geminiModels() async throws -> [CLIProxyModel] {
        let data = try await publicData(
            path: "v1beta/models",
            headers: ["X-Goog-Api-Key": clientAPIKey]
        )
        return try decode(GeminiModelsResponse.self, from: data).models.map { model in
            let id = model.name.hasPrefix("models/")
                ? String(model.name.dropFirst("models/".count))
                : model.name
            return CLIProxyModel(
                id: id,
                displayName: model.displayName,
                type: "model",
                ownedBy: "google"
            )
        }
    }

    private func publicData(path: String, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 15)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
            return data
        } catch let error as CLIProxyGatewayError {
            throw error
        } catch {
            throw CLIProxyGatewayError.network(error.localizedDescription)
        }
    }

    private func requestData(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CLIProxyGatewayError.configuration("invalid Management API URL") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
            return data
        } catch let error as CLIProxyGatewayError {
            throw error
        } catch {
            throw CLIProxyGatewayError.network(error.localizedDescription)
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CLIProxyGatewayError.invalidResponse("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CLIProxyGatewayError.managementAPI(http.statusCode, Self.managementErrorDetail(from: data))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CLIProxyGatewayError.invalidResponse(error.localizedDescription) }
    }

    private static func validateAuthFileName(_ name: String) throws {
        guard !name.isEmpty,
              name.utf8.count <= 240,
              name.lowercased().hasSuffix(".json"),
              name == URL(fileURLWithPath: name).lastPathComponent,
              !name.contains("\\"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CLIProxyGatewayError.configuration("invalid auth file name")
        }
    }

    private func safePathComponent(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 100,
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0)
              }) else {
            throw CLIProxyGatewayError.configuration("invalid plugin provider identifier")
        }
        return normalized
    }

    private static func managementErrorDetail(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
            let code = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = decoded.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !detail.isEmpty { return detail }
            if !code.isEmpty { return code }
        }
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "unknown error" : raw
    }
}

nonisolated private struct EmptyResponse: Decodable { init() {} }

/// Small Codable bridge used only for a two-field JSON request body.
nonisolated private enum AnyCodable: Codable {
    case string(String)
    case bool(Bool)

    init(_ value: String) { self = .string(value) }
    init(_ value: Bool) { self = .bool(value) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        self = .string(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}
