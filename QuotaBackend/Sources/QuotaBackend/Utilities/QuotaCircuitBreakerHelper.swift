import Foundation

public enum QuotaCircuitBreakerHelper {
    public struct BreakerOutcome: Sendable {
        public let tripped: Bool
        public let reason: String

        public init(tripped: Bool, reason: String) {
            self.tripped = tripped
            self.reason = reason
        }
    }

    /// Finds matching CLIProxyAPI auth files in ~/Library/Application Support/AIUsage/CLIProxyAPI/auth
    /// for a given provider ("antigravity", "codex", etc.) and optional email / credential identifier.
    public static func findTargetCPAAuthFiles(
        providerPrefix: String,
        email: String?,
        currentFileURL: URL?
    ) -> [URL] {
        var targets: [URL] = []
        var seenPaths = Set<String>()

        func addTarget(_ url: URL) {
            let path = url.standardizedFileURL.path
            if !seenPaths.contains(path) {
                seenPaths.insert(path)
                targets.append(url)
            }
        }

        // 1. If the current file itself is in the CLIProxyAPI auth directory, include it directly
        if let currentFileURL, currentFileURL.path.contains("CLIProxyAPI/auth") {
            addTarget(currentFileURL)
        }

        // 2. Scan the standard CLIProxyAPI auth directory
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return targets
        }

        let authDir = appSupport
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("CLIProxyAPI", isDirectory: true)
            .appendingPathComponent("auth", isDirectory: true)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: authDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return targets
        }

        let cleanTargetEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = "aiusage-\(providerPrefix.lowercased())-"

        for fileURL in contents where fileURL.pathExtension.lowercased() == "json" {
            let filename = fileURL.lastPathComponent.lowercased()
            guard filename.hasPrefix(prefix) else { continue }

            guard let data = try? Data(contentsOf: fileURL),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            if let cleanTargetEmail, !cleanTargetEmail.isEmpty {
                let fileEmail = ((json["email"] as? String) ?? (json["account"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if fileEmail == cleanTargetEmail {
                    addTarget(fileURL)
                    continue
                }
            }

            // Fallback match: if currentFileURL filename contains the credential ID stored in json
            if let currentFileURL {
                let currentBasename = currentFileURL.lastPathComponent
                if let credId = json["aiusage_credential_id"] as? String, !credId.isEmpty {
                    if currentBasename.contains(credId) {
                        addTarget(fileURL)
                        continue
                    }
                }
            }
        }

        return targets
    }

    /// Evaluates and synchronizes the circuit breaker state across all target auth files.
    @discardableResult
    public static func syncCircuitBreaker(
        targets: [URL],
        shouldTrip: Bool,
        reason: String
    ) -> BreakerOutcome? {
        guard !targets.isEmpty else { return nil }

        let activeReason = reason

        for fileURL in targets {
            guard let data = try? Data(contentsOf: fileURL),
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            let currentDisabled = (json["disabled"] as? Bool) ?? ((json["disabled"] as? Int) == 1)
            let isTrippedByBreaker = json["circuit_breaker_tripped"] as? Bool ?? false

            // Safety guard: If the account was MANUALLY disabled by the user in UI,
            // the circuit breaker must never touch or re-enable it!
            if currentDisabled && !isTrippedByBreaker {
                continue
            }

            var didChange = false

            if shouldTrip {
                if !currentDisabled || !isTrippedByBreaker {
                    json["disabled"] = true
                    json["circuit_breaker_tripped"] = true
                    json["circuit_breaker_partial"] = false
                    json["circuit_breaker_reason"] = reason
                    json["circuit_breaker_tripped_at"] = ISO8601DateFormatter().string(from: Date())
                    didChange = true
                } else if let existingReason = json["circuit_breaker_reason"] as? String, existingReason != reason {
                    json["circuit_breaker_reason"] = reason
                    didChange = true
                }
            } else {
                // Healthy: Auto-recovery when all quota pools are healthy (> 5%)
                if currentDisabled && isTrippedByBreaker {
                    json["disabled"] = false
                    json["circuit_breaker_tripped"] = false
                    json["circuit_breaker_partial"] = false
                    json["circuit_breaker_recovered_at"] = ISO8601DateFormatter().string(from: Date())
                    didChange = true
                }
            }

            if didChange, let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
                try? updatedData.write(to: fileURL, options: .atomic)
            }
        }

        return BreakerOutcome(tripped: shouldTrip, reason: activeReason)
    }
}
