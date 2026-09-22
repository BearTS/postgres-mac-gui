import Foundation

/// Vault's HTTP API. Uses URLSession only — no dependency needed for this.
public struct VaultClient: Sendable {

    public struct VaultAPIError: LocalizedError, Sendable {
        public let statusCode: Int
        public let errors: [String]
        public var errorDescription: String? {
            if errors.isEmpty { return "Vault returned HTTP \(statusCode)." }
            return errors.joined(separator: "\n")
        }
        /// 403 usually means the token is missing, wrong, or expired.
        public var isPermissionDenied: Bool { statusCode == 403 }
    }

    public let baseURL: URL
    public let token: String?

    public init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }

    public func withToken(_ token: String?) -> VaultClient {
        VaultClient(baseURL: baseURL, token: token)
    }

    // MARK: Server state

    public struct Health: Sendable, Equatable {
        public let initialized: Bool
        public let sealed: Bool
        public let standby: Bool
        public let version: String
        public let clusterName: String?
    }

    /// `sys/health` answers even when sealed or uninitialised, which is why it uses odd status
    /// codes (501 uninitialised, 503 sealed) rather than errors.
    public func health() async throws -> Health {
        let (data, response) = try await send("GET", path: "sys/health", authenticated: false)
        let status = response.statusCode
        guard [200, 429, 472, 473, 501, 503].contains(status) else {
            throw try Self.apiError(status: status, data: data)
        }
        let json = try Self.json(data)
        return Health(
            initialized: json["initialized"] as? Bool ?? false,
            sealed: json["sealed"] as? Bool ?? true,
            standby: json["standby"] as? Bool ?? false,
            version: json["version"] as? String ?? "unknown",
            clusterName: json["cluster_name"] as? String
        )
    }

    public struct SealStatus: Sendable, Equatable {
        public let sealed: Bool
        public let initialized: Bool
        /// Unseal keys required and total, i.e. the Shamir threshold.
        public let threshold: Int
        public let shares: Int
        /// How many keys have been entered so far in this unseal attempt.
        public let progress: Int
    }

    public func sealStatus() async throws -> SealStatus {
        let json = try await getJSON("sys/seal-status", authenticated: false)
        return SealStatus(
            sealed: json["sealed"] as? Bool ?? true,
            initialized: json["initialized"] as? Bool ?? false,
            threshold: json["t"] as? Int ?? 0,
            shares: json["n"] as? Int ?? 0,
            progress: json["progress"] as? Int ?? 0
        )
    }

    /// True when the server is up and answering at all.
    public func isReachable() async -> Bool {
        (try? await health()) != nil
    }

    // MARK: Initialise / unseal / seal

    public struct InitResult: Sendable {
        public let unsealKeys: [String]
        public let rootToken: String
    }

    /// One key share and a threshold of one: this is a local dev server, and juggling five
    /// key shares by hand helps nobody here.
    public func initialize(shares: Int = 1, threshold: Int = 1) async throws -> InitResult {
        let json = try await sendJSON(
            "PUT", path: "sys/init",
            body: ["secret_shares": shares, "secret_threshold": threshold],
            authenticated: false
        )
        return InitResult(
            unsealKeys: json["keys_base64"] as? [String] ?? json["keys"] as? [String] ?? [],
            rootToken: json["root_token"] as? String ?? ""
        )
    }

    @discardableResult
    public func unseal(key: String) async throws -> SealStatus {
        let json = try await sendJSON("PUT", path: "sys/unseal", body: ["key": key], authenticated: false)
        return SealStatus(
            sealed: json["sealed"] as? Bool ?? true,
            initialized: json["initialized"] as? Bool ?? true,
            threshold: json["t"] as? Int ?? 0,
            shares: json["n"] as? Int ?? 0,
            progress: json["progress"] as? Int ?? 0
        )
    }

    public func seal() async throws {
        _ = try await send("PUT", path: "sys/seal", authenticated: true)
    }

    // MARK: Token

    public struct TokenInfo: Sendable {
        public let displayName: String
        public let policies: [String]
        public let renewable: Bool
        public let timeToLive: Int
    }

    public func lookupSelf() async throws -> TokenInfo {
        let json = try await getJSON("auth/token/lookup-self", authenticated: true)
        let data = json["data"] as? [String: Any] ?? [:]
        return TokenInfo(
            displayName: data["display_name"] as? String ?? "token",
            policies: data["policies"] as? [String] ?? [],
            renewable: data["renewable"] as? Bool ?? false,
            timeToLive: data["ttl"] as? Int ?? 0
        )
    }

    // MARK: Secret engines

    public struct SecretEngine: Identifiable, Sendable, Hashable {
        /// Mount path including the trailing slash, e.g. `secret/`.
        public let path: String
        public let type: String
        public let description: String
        /// KV engines are either version 1 or 2, and their API paths differ.
        public let kvVersion: Int?

        public var id: String { path }
        public var name: String { String(path.dropLast()) }
        public var isKeyValue: Bool { type == "kv" || type == "generic" }
    }

    public func secretEngines() async throws -> [SecretEngine] {
        let json = try await getJSON("sys/mounts", authenticated: true)
        // Vault returns the mounts either at the top level or under `data`, depending on version.
        let mounts = (json["data"] as? [String: Any]) ?? json
        var engines: [SecretEngine] = []
        for (path, value) in mounts {
            guard let entry = value as? [String: Any], let type = entry["type"] as? String else { continue }
            let options = entry["options"] as? [String: Any]
            let versionString = options?["version"] as? String
            engines.append(SecretEngine(
                path: path,
                type: type,
                description: entry["description"] as? String ?? "",
                kvVersion: versionString.flatMap(Int.init)
            ))
        }
        return engines.sorted { $0.path < $1.path }
    }

    /// Enable a new KV v2 engine at a mount point.
    public func enableKV(at mountPath: String) async throws {
        _ = try await sendJSON(
            "POST", path: "sys/mounts/\(mountPath)",
            body: ["type": "kv", "options": ["version": "2"]],
            authenticated: true
        )
    }

    public func disableEngine(at mountPath: String) async throws {
        _ = try await send("DELETE", path: "sys/mounts/\(mountPath)", authenticated: true)
    }

    // MARK: KV secrets

    /// A KV v2 engine splits its API: data lives under `<mount>/data/<path>` and the listing
    /// under `<mount>/metadata/<path>`. KV v1 has neither and uses the bare path.
    static func dataPath(mount: String, path: String, kvVersion: Int?) -> String {
        let mountName = mount.hasSuffix("/") ? String(mount.dropLast()) : mount
        let suffix = path.isEmpty ? "" : "/\(path)"
        return kvVersion == 2 ? "\(mountName)/data\(suffix)" : "\(mountName)\(suffix)"
    }

    static func metadataPath(mount: String, path: String, kvVersion: Int?) -> String {
        let mountName = mount.hasSuffix("/") ? String(mount.dropLast()) : mount
        let suffix = path.isEmpty ? "" : "/\(path)"
        return kvVersion == 2 ? "\(mountName)/metadata\(suffix)" : "\(mountName)\(suffix)"
    }

    /// Keys directly under a path. Entries ending in `/` are folders, not secrets.
    public func listSecrets(mount: String, path: String, kvVersion: Int?) async throws -> [String] {
        let apiPath = Self.metadataPath(mount: mount, path: path, kvVersion: kvVersion)
        let (data, response) = try await send("LIST", path: apiPath, authenticated: true)
        // An empty folder is a 404, which is not an error worth surfacing.
        if response.statusCode == 404 { return [] }
        guard response.statusCode == 200 else { throw try Self.apiError(status: response.statusCode, data: data) }
        let json = try Self.json(data)
        let payload = json["data"] as? [String: Any] ?? [:]
        return (payload["keys"] as? [String] ?? []).sorted()
    }

    public struct Secret: Sendable {
        public let values: [String: String]
        public let version: Int?
        public let createdAt: String?
    }

    public func readSecret(mount: String, path: String, kvVersion: Int?) async throws -> Secret {
        let apiPath = Self.dataPath(mount: mount, path: path, kvVersion: kvVersion)
        let json = try await getJSON(apiPath, authenticated: true)
        let outer = json["data"] as? [String: Any] ?? [:]
        // KV v2 nests the values one level deeper and adds metadata alongside them.
        let raw = kvVersion == 2 ? (outer["data"] as? [String: Any] ?? [:]) : outer
        let metadata = outer["metadata"] as? [String: Any]

        var values: [String: String] = [:]
        for (key, value) in raw {
            values[key] = Self.stringify(value)
        }
        return Secret(
            values: values,
            version: metadata?["version"] as? Int,
            createdAt: metadata?["created_time"] as? String
        )
    }

    public func writeSecret(mount: String, path: String, kvVersion: Int?, values: [String: String]) async throws {
        let apiPath = Self.dataPath(mount: mount, path: path, kvVersion: kvVersion)
        let body: [String: Any] = kvVersion == 2 ? ["data": values] : values
        _ = try await sendJSON("POST", path: apiPath, body: body, authenticated: true)
    }

    /// Remove a secret and, for KV v2, all of its version history.
    public func deleteSecret(mount: String, path: String, kvVersion: Int?) async throws {
        let apiPath = Self.metadataPath(mount: mount, path: path, kvVersion: kvVersion)
        _ = try await send("DELETE", path: apiPath, authenticated: true)
    }

    // MARK: Transport

    private func url(for path: String) -> URL {
        baseURL.appendingPathComponent("v1").appendingPathComponent(path)
    }

    private func send(
        _ method: String,
        path: String,
        body: Data? = nil,
        authenticated: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.timeoutInterval = 10
        if authenticated, let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Vault-Token")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VaultAPIError(statusCode: 0, errors: ["Vault did not return an HTTP response."])
        }
        return (data, http)
    }

    private func sendJSON(
        _ method: String,
        path: String,
        body: [String: Any],
        authenticated: Bool
    ) async throws -> [String: Any] {
        let encoded = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(method, path: path, body: encoded, authenticated: authenticated)
        guard (200..<300).contains(response.statusCode) else {
            throw try Self.apiError(status: response.statusCode, data: data)
        }
        return (try? Self.json(data)) ?? [:]
    }

    private func getJSON(_ path: String, authenticated: Bool) async throws -> [String: Any] {
        let (data, response) = try await send("GET", path: path, authenticated: authenticated)
        guard (200..<300).contains(response.statusCode) else {
            throw try Self.apiError(status: response.statusCode, data: data)
        }
        return try Self.json(data)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VaultAPIError(statusCode: 0, errors: ["Vault returned a response that was not JSON."])
        }
        return object
    }

    /// Vault reports problems as `{"errors": [...]}`.
    static func apiError(status: Int, data: Data) throws -> VaultAPIError {
        let messages = (try? json(data))?["errors"] as? [String] ?? []
        return VaultAPIError(statusCode: status, errors: messages)
    }

    /// Values are usually strings, but Vault stores whatever JSON it was given.
    static func stringify(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case let bool as Bool:     return bool ? "true" : "false"
        case let number as NSNumber: return number.stringValue
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
                return String(describing: value)
            }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
