import Foundation
import QuotaBackend
import os

extension ProxyViewModel {

    // MARK: - Statistics Management

    func loadStatistics() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.proxyStatistics) else {
            return
        }

        do {
            statistics = try JSONDecoder().decode([String: ProxyStatistics].self, from: data)
            flushLogsRefresh()
        } catch {
            logPersistenceError("load proxy statistics", error: error)
        }
    }

    /// 主线程只取值快照，JSON 编码与 UserDefaults 写入在持久化队列上执行。
    func saveStatistics() {
        let snapshot = statistics
        ProxyPersistence.queue.async {
            do {
                let data = try ProxyPersistence.encoder.encode(snapshot)
                UserDefaults.standard.set(data, forKey: DefaultsKey.proxyStatistics)
            } catch {
                proxyPersistenceLog.error("Failed to save proxy statistics: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func recordRequest(_ log: ProxyRequestLog) {
        var stats = statistics[log.configId] ?? .empty
        stats.totalRequests += 1
        if log.success {
            stats.successfulRequests += 1
        } else {
            stats.failedRequests += 1
        }
        stats.totalTokensInput += log.tokensInput
        stats.totalTokensOutput += log.tokensOutput
        stats.totalTokensCacheRead += log.tokensCacheRead
        stats.totalTokensCacheCreation += log.tokensCacheCreation
        stats.estimatedCostUSD += log.estimatedCostUSD
        stats.lastRequestAt = log.timestamp

        let totalTime = stats.averageResponseTime * Double(stats.totalRequests - 1) + log.responseTimeMs
        stats.averageResponseTime = totalTime / Double(stats.totalRequests)

        // 首字时间 TTFT 仅在流式请求里可采，单独累计样本数做运行平均，
        // 非流式 / 旧日志（firstTokenMs == nil）不污染该均值。
        if let firstTokenMs = log.firstTokenMs {
            let prevTotal = stats.averageFirstTokenTime * Double(stats.firstTokenSamples)
            stats.firstTokenSamples += 1
            stats.averageFirstTokenTime = (prevTotal + firstTokenMs) / Double(stats.firstTokenSamples)
        }

        stats.requestsByModel[log.upstreamModel, default: 0] += 1

        statistics[log.configId] = stats

        recentLogs[log.configId, default: []].append(log)

        logsDirtyDays.insert(shardDayKey(log.timestamp))
        schedulePersistence()
        scheduleLogsRefresh()
    }

    /// Coalesce persistence writes: waits `persistenceDebounceInterval` after the first dirty event,
    /// then flushes. A running timer is NOT cancelled by subsequent events; this guarantees an upper
    /// bound on data loss even during sustained streaming (unlike a pure debounce).
    func schedulePersistence() {
        guard persistenceWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistenceWorkItem = nil
            // 折叠脏日期进永久归档须早于 saveLogs（后者会清空 logsDirtyDays）。
            self.foldDaysIntoUsageArchive(self.logsDirtyDays)
            self.saveStatistics()
            self.saveLogs()
        }
        persistenceWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.persistenceDebounceInterval,
            execute: item
        )
    }

    /// Immediately flush any pending debounced persistence.
    /// 注意：实际写盘在持久化队列上异步完成；若调用方依赖「文件已落盘」
    /// 的顺序（如刷新前冻结归档），请使用 `flushPersistenceAsync()`。
    func flushPersistence() {
        persistenceWorkItem?.cancel()
        persistenceWorkItem = nil
        // 折叠脏日期进永久归档须早于 saveLogs（后者会清空 logsDirtyDays）。
        foldDaysIntoUsageArchive(logsDirtyDays)
        saveStatistics()
        saveLogs()
    }

    /// Flush 并异步等待后台写盘完成。供本地统计刷新链路使用：
    /// 归档文件确认写完后，ProviderEngine 才去读盘，避免读到旧数据。
    func flushPersistenceAsync() async {
        flushPersistence()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ProxyPersistence.queue.async { continuation.resume() }
        }
    }

    /// Fill in pricing for logs that were recorded before their model had a configured price.
    /// Logs with existing non-zero costs are preserved as-is.
    func recalculateCosts(for configId: String) {
        guard let config = configurations.first(where: { $0.id == configId }),
              let logs = recentLogs[configId] else { return }

        var changed = false
        var changedDayKeys = Set<String>()
        var costDelta = 0.0
        var updatedLogs: [ProxyRequestLog] = []

        for log in logs {
            if !log.pricingResolved, log.tokensInput + log.tokensOutput + log.tokensCache > 0 {
                let pricing = config.pricingForModel(log.upstreamModel)
                let cost = pricing?.costForTokens(
                    input: log.tokensInput,
                    output: log.tokensOutput,
                    cacheRead: log.tokensCacheRead,
                    cacheCreate: log.tokensCacheCreation
                ) ?? 0
                if pricing != nil {
                    changed = true
                    changedDayKeys.insert(shardDayKey(log.timestamp))
                    costDelta += cost - log.estimatedCostUSD
                    updatedLogs.append(ProxyRequestLog(
                        id: log.id, configId: log.configId, timestamp: log.timestamp,
                        method: log.method, path: log.path,
                        claudeModel: log.claudeModel, upstreamModel: log.upstreamModel,
                        success: log.success, responseTimeMs: log.responseTimeMs,
                        firstTokenMs: log.firstTokenMs,
                        tokensInput: log.tokensInput, tokensOutput: log.tokensOutput,
                        tokensCacheRead: log.tokensCacheRead,
                        tokensCacheCreation: log.tokensCacheCreation,
                        estimatedCostUSD: cost,
                        pricingResolved: true,
                        errorMessage: log.errorMessage,
                        errorType: log.errorType,
                        statusCode: log.statusCode,
                        sessionId: log.sessionId,
                        conversationId: log.conversationId,
                        upstreamRequestId: log.upstreamRequestId,
                        clientSurface: log.clientSurface,
                        isGlobalProxy: log.isGlobalProxy
                    ))
                    continue
                }
            }
            updatedLogs.append(log)
        }

        if changed {
            recentLogs[configId] = updatedLogs
            logsDirtyDays.formUnion(changedDayKeys)
            if var stats = statistics[configId] {
                stats.estimatedCostUSD += costDelta
                statistics[configId] = stats
            }
            foldDaysIntoUsageArchive(changedDayKeys)
            saveStatistics()
            saveLogs()
            flushLogsRefresh()
        }
    }

    // MARK: - Logs Management (Daily Sharding)
    // Logs are stored as per-day shard files under ~/.config/aiusage/proxy-logs/
    // to avoid rewriting the entire log corpus on every proxied request.
    // Only days that received new entries are written during each persistence cycle.

    func loadLogs() {
        let fm = FileManager.default
        let shardDir = URL(fileURLWithPath: logsShardDirPath, isDirectory: true)

        // Phase 1: Migrate legacy single-file format to sharded storage
        let legacyURL = URL(fileURLWithPath: logsFilePath)
        if fm.fileExists(atPath: legacyURL.path) {
            migrateFromSingleFile(legacyURL, to: shardDir)
        } else if let data = UserDefaults.standard.data(forKey: DefaultsKey.proxyLogs) {
            do {
                let legacy = try JSONDecoder().decode([String: [ProxyRequestLog]].self, from: data)
                UserDefaults.standard.removeObject(forKey: DefaultsKey.proxyLogs)
                mergeIntoMemory(legacy)
                logsDirtyDays.formUnion(allDayKeys(from: recentLogs))
                saveLogs()
            } catch {
                logPersistenceError("migrate legacy proxy logs from UserDefaults", error: error)
            }
        }

        // Phase 2: Load all shard files within retention window
        loadShardFiles(from: shardDir)
        // 裁剪前先把所有已加载日期折叠进永久用量归档，确保即将被裁剪的日期不丢聚合值。
        foldAllLoadedDaysIntoUsageArchive()
        pruneOldLogs()
        flushLogsRefresh()
    }

    /// 主线程只做日志字典快照（CoW，O(1)），按日过滤、JSON 编码与写盘
    /// 全部在持久化队列上执行，避免代理高频请求期间阻塞 UI。
    func saveLogs() {
        guard !logsDirtyDays.isEmpty else { return }

        let dirtyDays = logsDirtyDays
        logsDirtyDays.removeAll()
        let logsSnapshot = recentLogs
        let shardDir = URL(fileURLWithPath: logsShardDirPath, isDirectory: true)

        ProxyPersistence.queue.async {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: shardDir, withIntermediateDirectories: true)
            } catch {
                proxyPersistenceLog.error("Failed to create proxy logs shard directory: \(String(describing: error), privacy: .public)")
                return
            }

            for dayKey in dirtyDays {
                guard let interval = ProxyPersistence.dayInterval(for: dayKey) else { continue }
                var dayLogs: [String: [ProxyRequestLog]] = [:]
                for (configId, logs) in logsSnapshot {
                    let filtered = logs.filter { $0.timestamp >= interval.start && $0.timestamp < interval.end }
                    if !filtered.isEmpty {
                        dayLogs[configId] = filtered
                    }
                }

                let url = shardDir.appendingPathComponent("proxy-logs-\(dayKey).json")
                if dayLogs.isEmpty {
                    try? fm.removeItem(at: url)
                } else {
                    do {
                        let data = try ProxyPersistence.encoder.encode(dayLogs)
                        try data.write(to: url, options: .atomic)
                    } catch {
                        proxyPersistenceLog.error("Failed to save proxy logs shard \(dayKey, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
    }

    func pruneOldLogs() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -logRetentionDays, to: Date()) ?? .distantPast
        let cutoffKey = shardDayKey(cutoff)

        var pruned = false
        for (configId, logs) in recentLogs {
            let filtered = logs.filter { $0.timestamp > cutoff }
            if filtered.count != logs.count {
                recentLogs[configId] = filtered
                pruned = true
            }
        }

        // 文件枚举与删除走持久化队列：与排队中的写入保持先后顺序，且不阻塞主线程。
        let shardDir = URL(fileURLWithPath: logsShardDirPath, isDirectory: true)
        ProxyPersistence.queue.async {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(
                at: shardDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            for item in items {
                guard let dayKey = Self.extractShardDayKey(from: item.lastPathComponent) else { continue }
                if dayKey < cutoffKey {
                    try? fm.removeItem(at: item)
                }
            }
        }

        if pruned {
            flushLogsRefresh()
        }
    }

    func clearLogs(for configId: String) {
        guard let logs = recentLogs[configId], !logs.isEmpty else { return }
        let dayKeys = Set(logs.map { shardDayKey($0.timestamp) })
        foldDaysIntoUsageArchive(dayKeys)
        logsDirtyDays.formUnion(dayKeys)
        recentLogs[configId] = []
        saveLogs()
        flushLogsRefresh()
    }

    func clearAllLogs() {
        foldAllLoadedDaysIntoUsageArchive()
        recentLogs.removeAll()
        logsDirtyDays.removeAll()

        // 删除入队到持久化队列：保证先于本次删除入队的写盘任务完成后才删，
        // 不会出现「队列里的旧写入把刚删掉的分片文件又写回来」。
        let shardDir = URL(fileURLWithPath: logsShardDirPath, isDirectory: true)
        ProxyPersistence.queue.async {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(
                at: shardDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            for item in items where item.lastPathComponent.hasPrefix("proxy-logs-") {
                try? fm.removeItem(at: item)
            }
        }
        flushLogsRefresh()
    }

    // MARK: - Shard Helpers

    private func loadShardFiles(from shardDir: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: shardDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let decoder = JSONDecoder()
        for item in items {
            guard item.pathExtension == "json",
                  item.lastPathComponent.hasPrefix("proxy-logs-") else { continue }
            do {
                let data = try Data(contentsOf: item)
                let dayLogs = try decoder.decode([String: [ProxyRequestLog]].self, from: data)
                mergeIntoMemory(dayLogs)
            } catch {
                logPersistenceError("load proxy logs shard \(item.lastPathComponent)", error: error)
            }
        }
    }

    private func migrateFromSingleFile(_ legacyURL: URL, to shardDir: URL) {
        do {
            let data = try Data(contentsOf: legacyURL)
            let legacy = try JSONDecoder().decode([String: [ProxyRequestLog]].self, from: data)
            mergeIntoMemory(legacy)
            logsDirtyDays.formUnion(allDayKeys(from: legacy))
            saveLogs()
            // 串行队列保证：分片写盘完成后才删除旧的单文件，迁移途中崩溃不丢数据。
            ProxyPersistence.queue.async {
                try? FileManager.default.removeItem(at: legacyURL)
            }
        } catch {
            logPersistenceError("migrate proxy logs from single file", error: error)
        }
    }

    private func mergeIntoMemory(_ logs: [String: [ProxyRequestLog]]) {
        for (configId, entries) in logs {
            recentLogs[configId, default: []].append(contentsOf: entries)
        }
    }

    private func allDayKeys(from logs: [String: [ProxyRequestLog]]) -> Set<String> {
        var keys = Set<String>()
        for entries in logs.values {
            for entry in entries {
                keys.insert(shardDayKey(entry.timestamp))
            }
        }
        return keys
    }

    private nonisolated static func extractShardDayKey(from filename: String) -> String? {
        guard filename.hasPrefix("proxy-logs-"), filename.hasSuffix(".json") else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: "proxy-logs-".count)
        let end = filename.index(filename.endIndex, offsetBy: -".json".count)
        guard start < end else { return nil }
        return String(filename[start..<end])
    }
}
