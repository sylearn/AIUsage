// MARK: - Batch Import View
// Sheet-based UI for selecting a folder, scanning auth files, and importing multiple accounts.

import SwiftUI
import QuotaBackend

struct BatchImportView: View {
    let providerId: String

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var scannedFiles: [ScannedAuthFile] = []
    @State private var selectedIds: Set<String> = []
    @State private var isScanning = false
    @State private var isImporting = false
    @State private var importResult: ImportResult?
    @State private var directoryURL: URL?

    private var providerTitle: String {
        appState.providerCatalogItem(for: providerId)?.title(for: appState.language) ?? providerId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            selectFolderButton

            if !scannedFiles.isEmpty {
                fileListSection
                actionBar
            } else if directoryURL != nil, !isScanning {
                emptyStateView
            }

            if let result = importResult {
                resultBanner(result)
            }
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 220, maxHeight: 600)
        .appPageChrome(colorScheme)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ProviderIconView(providerId, size: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(L("Batch Import \(providerTitle)", "批量导入 \(providerTitle)"))
                    .font(.title3).bold()

                Text(L(
                    "Select a folder containing auth JSON files to import multiple accounts at once.",
                    "选择一个包含认证 JSON 文件的文件夹，即可一次性导入多个账号。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(L("Close", "关闭")) { dismiss() }
                .buttonStyle(.borderless)
        }
    }

    // MARK: - Folder Selection

    private var selectFolderButton: some View {
        HStack(spacing: 12) {
            Button {
                openFolderPanel()
            } label: {
                Label(
                    directoryURL == nil
                        ? L("Select Folder", "选择文件夹")
                        : L("Change Folder", "更换文件夹"),
                    systemImage: "folder.badge.plus"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isImporting)

            if isScanning {
                ProgressView().controlSize(.small)
                Text(L("Scanning…", "扫描中…"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let url = directoryURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - File List

    private var fileListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L(
                    "\(scannedFiles.count) auth files found",
                    "发现 \(scannedFiles.count) 个认证文件"
                ))
                .font(.subheadline.weight(.semibold))

                Spacer()

                Button(allSelected ? L("Deselect All", "取消全选") : L("Select All", "全选")) {
                    if allSelected {
                        selectedIds.removeAll()
                    } else {
                        selectedIds = Set(scannedFiles.map(\.id))
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isImporting)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(scannedFiles) { file in
                        fileRow(file)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
    }

    private func fileRow(_ file: ScannedAuthFile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selectedIds.contains(file.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selectedIds.contains(file.id) ? .blue : .secondary)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.detectedEmail ?? file.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(file.fileName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let date = file.modifiedAt {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedIds.contains(file.id)
                      ? Color.accentColor.opacity(0.08)
                      : AppSurface.card(colorScheme))
        )
        .contentShape(Rectangle())
        .onTapGesture { toggleSelection(file) }
    }

    private var emptyStateView: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.questionmark")
                .foregroundStyle(.secondary)
            Text(L(
                "No importable auth files found in this folder.",
                "此文件夹中没有可导入的认证文件。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppSurface.card(colorScheme)))
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            Text(L("Selected \(selectedIds.count)", "已选 \(selectedIds.count) 个"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if isImporting {
                ProgressView().controlSize(.small)
            }

            Button {
                Task { await performBatchImport() }
            } label: {
                Label(
                    L("Import Selected (\(selectedIds.count))", "导入选中 (\(selectedIds.count))"),
                    systemImage: "square.and.arrow.down.on.square"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(selectedIds.isEmpty || isImporting)
        }
    }

    // MARK: - Result Banner

    private func resultBanner(_ result: ImportResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.failed == 0 ? .green : .orange)

            Text(L(
                "Imported \(result.succeeded)/\(result.total). \(result.failed) failed.",
                "已导入 \(result.succeeded)/\(result.total)，失败 \(result.failed)。"
            ))
            .font(.caption)
            .foregroundStyle(result.failed == 0 ? .green : .orange)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((result.failed == 0 ? Color.green : Color.orange).opacity(0.1))
        )
    }

    // MARK: - Helpers

    private var allSelected: Bool {
        !scannedFiles.isEmpty && selectedIds.count == scannedFiles.count
    }

    private func toggleSelection(_ file: ScannedAuthFile) {
        if selectedIds.contains(file.id) {
            selectedIds.remove(file.id)
        } else {
            selectedIds.insert(file.id)
        }
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L(
            "Choose a folder containing \(providerTitle) auth files",
            "选择包含 \(providerTitle) 认证文件的文件夹"
        )

        guard panel.runModal() == .OK, let url = panel.url else { return }
        directoryURL = url
        importResult = nil
        scanDirectory(url)
    }

    private func scanDirectory(_ url: URL) {
        isScanning = true
        scannedFiles = []
        selectedIds = []

        DispatchQueue.global(qos: .userInitiated).async {
            let results = BatchAuthFileScanner.scanDirectory(at: url, for: providerId, recursive: true)
            DispatchQueue.main.async {
                scannedFiles = results
                selectedIds = Set(results.map(\.id))
                isScanning = false
            }
        }
    }

    // MARK: - Import Logic

    private func performBatchImport() async {
        let filesToImport = scannedFiles.filter { selectedIds.contains($0.id) }
        guard !filesToImport.isEmpty else { return }

        await MainActor.run { isImporting = true; importResult = nil }

        var succeeded = 0
        var failed = 0

        for file in filesToImport {
            let candidate = makeCandidateFromScannedFile(file)
            do {
                let (credential, usage) = try await ProviderAuthManager.authenticateCandidate(candidate)
                try await MainActor.run {
                    try appState.registerAuthenticatedCredential(credential, usage: usage, note: nil)
                    succeeded += 1
                }
            } catch {
                failed += 1
            }
        }

        if succeeded > 0 {
            _ = await refreshCoordinator.fetchSingleProvider(providerId)
        }

        await MainActor.run {
            isImporting = false
            importResult = ImportResult(total: filesToImport.count, succeeded: succeeded, failed: failed)
        }
    }

    private func makeCandidateFromScannedFile(_ file: ScannedAuthFile) -> ProviderAuthCandidate {
        let path = file.fileURL.path
        let canonical = ProviderAuthManager.canonicalPath(path)
        let json = ProviderAuthManager.loadJSONObject(at: path)
        let fingerprint: String? = json.flatMap { ProviderAuthManager.sessionFingerprint(from: $0) }

        return ProviderAuthCandidate(
            id: "\(providerId):batch:\(canonical)",
            providerId: providerId,
            sourceIdentifier: "file:\(canonical)",
            sessionFingerprint: fingerprint,
            title: file.detectedEmail ?? file.fileName,
            subtitle: L("Batch import", "批量导入"),
            detail: ProviderAuthManager.compactDetail(parts: [
                ProviderAuthManager.displayPath(path),
                ProviderAuthManager.formattedDate(file.modifiedAt)
            ]),
            modifiedAt: file.modifiedAt,
            authMethod: .authFile,
            credentialValue: path,
            sourcePath: path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )
    }
}

// MARK: - Import Result

extension BatchImportView {
    struct ImportResult {
        let total: Int
        let succeeded: Int
        let failed: Int
    }
}
