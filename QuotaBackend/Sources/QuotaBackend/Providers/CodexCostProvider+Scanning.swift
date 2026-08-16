import Foundation

extension CodexCostProvider {
    func scanFiles(_ files: [String]) async -> CodexUsageSnapshot {
        let fingerprintsByFile = fileFingerprints(files)
        let cachedByFile = await Self.fileScanCache.entries(matching: fingerprintsByFile)
        var parsedUpdates: [String: CodexParsedFile] = [:]

        var metadataByFile: [String: SessionMetadata] = [:]
        var fileBySessionId: [String: String] = [:]

        for file in files {
            guard let metadata = cachedByFile[file]?.metadata ?? parseSessionMetadata(file) else { continue }
            metadataByFile[file] = metadata
            if let sessionId = metadata.sessionId, fileBySessionId[sessionId] == nil {
                fileBySessionId[sessionId] = file
            }
        }

        var filesToParse = Set(files.filter { cachedByFile[$0] == nil })
        var changedSessionIds = Set(filesToParse.compactMap { metadataByFile[$0]?.sessionId })
        var addedDependent = true
        while addedDependent {
            addedDependent = false
            for (file, metadata) in metadataByFile {
                guard !filesToParse.contains(file),
                      let parentId = metadata.forkedFromId,
                      changedSessionIds.contains(parentId) else {
                    continue
                }
                filesToParse.insert(file)
                if let sessionId = metadata.sessionId {
                    changedSessionIds.insert(sessionId)
                }
                addedDependent = true
            }
        }

        var snapshotCacheByFile: [String: [TimestampedTotals]] = [:]
        func snapshots(for file: String) -> [TimestampedTotals] {
            if let cached = snapshotCacheByFile[file] {
                return cached
            }
            if let cached = parsedUpdates[file]?.snapshots ?? cachedByFile[file]?.snapshots {
                snapshotCacheByFile[file] = cached
                return cached
            }
            let parsed = parseTokenSnapshots(file)
            snapshotCacheByFile[file] = parsed.snapshots
            return parsed.snapshots
        }

        func inheritedTotals(sessionId: String, atOrBefore cutoffTimestamp: String) -> CodexTotals? {
            guard let file = fileBySessionId[sessionId] else { return nil }
            let snapshots = snapshots(for: file)

            let cutoffDate = parseTimestamp(cutoffTimestamp)
            var inherited: CodexTotals?
            for snapshot in snapshots {
                let isBeforeCutoff: Bool
                if let snapshotDate = snapshot.date, let cutoffDate {
                    isBeforeCutoff = snapshotDate <= cutoffDate
                } else {
                    isBeforeCutoff = snapshot.timestamp <= cutoffTimestamp
                }
                if isBeforeCutoff { inherited = snapshot.totals }
            }
            return inherited
        }

        var snapshot = CodexUsageSnapshot()
        for file in files {
            let metadata = metadataByFile[file]
            let fileAggregate: CodexFileAggregate
            if filesToParse.contains(file) {
                fileAggregate = parseFile(file, metadata: metadata, inheritedTotals: inheritedTotals)
                if let fingerprint = fingerprintsByFile[file] {
                    parsedUpdates[file] = CodexParsedFile(
                        fingerprint: fingerprint,
                        metadata: metadata,
                        aggregate: fileAggregate,
                        snapshots: snapshotCacheByFile[file]
                    )
                }
            } else {
                fileAggregate = cachedByFile[file]?.aggregate ?? CodexFileAggregate(sessionId: metadata?.sessionId)
            }
            snapshot.merge(fileAggregate)
        }

        for (file, snapshots) in snapshotCacheByFile where parsedUpdates[file] == nil {
            if let cached = cachedByFile[file] {
                parsedUpdates[file] = CodexParsedFile(
                    fingerprint: cached.fingerprint,
                    metadata: cached.metadata,
                    aggregate: cached.aggregate,
                    snapshots: snapshots
                )
            }
        }

        if !parsedUpdates.isEmpty || cachedByFile.count != files.count {
            await Self.fileScanCache.store(parsedUpdates, keeping: Set(files))
        }

        return snapshot
    }

    func fileFingerprints(_ files: [String]) -> [String: CodexFileFingerprint] {
        Dictionary(uniqueKeysWithValues: files.map { file in
            (file, fileFingerprint(file))
        })
    }

    func fileFingerprint(_ path: String) -> CodexFileFingerprint {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return CodexFileFingerprint(
            path: path,
            size: size,
            modifiedAt: modifiedAt,
            scanSignature: scanCacheSignature()
        )
    }

}
