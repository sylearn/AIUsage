import SwiftUI
import UniformTypeIdentifiers

// MARK: - OpenCodeManagementView Banners & Toolbar
// 状态横幅（接管态/JSONC/代理异常）与顶部工具栏（opencode.json/导入/导出/新建）。
// 与 Claude/Codex 页的工具栏同款容器按钮组视觉。拆出以控制单文件规模；
// 依赖主视图的 internal @State / store。

extension OpenCodeManagementView {

    // MARK: - Warning Banners
    // 仅保留异常告警（代理进程故障）；常态信息不占版面，
    // 与 Claude/Codex 页一致（接管状态由节点卡片的激活开关表达）。
    // 注: opencode.jsonc 现已支持接管（注释由备份保真还原），不再提示迁移。

    /// 运行时本会话接管（建立了 Instance）、但当前进程不在运行且不在启动/重启窗口内的节点
    /// = 真·故障，需横幅提示。以「运行时是否接管」为准而非持久配置：设置关闭未恢复时为空，
    /// 不会误报；启动恢复/退避重启期间被 startingNodeIds 抑制，不闪现。
    private var stoppedManagedNodes: [OpenCodeNode] {
        proxyRuntime.managedNodeIds
            .subtracting(proxyRuntime.runningNodeIds)
            .subtracting(proxyRuntime.startingNodeIds)
            .compactMap { id in store.nodes.first { $0.id == id } }
    }

    /// 代理进程异常：崩溃多次自动重启失败，或运行时接管的节点进程未在运行。
    @ViewBuilder
    var proxyErrorBanner: some View {
        let stopped = stoppedManagedNodes
        // 仅在确有进程未运行时才报错：进程都在跑时即便残留 stale lastError 也不误报（避免横幅闪现）。
        if !stopped.isEmpty, let error = proxyRuntime.lastError {
            banner(
                icon: "bolt.trianglebadge.exclamationmark.fill",
                tint: .red,
                title: L("Local proxy error", "本地代理异常"),
                message: error,
                trailing: AnyView(restartProxyButton)
            )
        } else if !stopped.isEmpty {
            let ports = stopped.map { "127.0.0.1:\(String($0.proxyPort))" }.joined(separator: ", ")
            banner(
                icon: "bolt.trianglebadge.exclamationmark.fill",
                tint: .orange,
                title: L("Local proxy is not running", "本地代理未在运行"),
                message: L(
                    "Requests via \(ports) will fail until the proxy is restarted.",
                    "重启代理前，经 \(ports) 的请求将失败。"
                ),
                trailing: AnyView(restartProxyButton)
            )
        }
    }

    private var restartProxyButton: some View {
        Button(L("Restart Proxy", "重启代理")) {
            Task { await proxyRuntime.restartStopped() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func banner(icon: String, tint: Color, title: String, message: String, trailing: AnyView? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let trailing { trailing }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.12 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Action Bar (Claude/Codex 页同款容器按钮组)

    var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ccSwitchSyncButton
                configFileButton
                Spacer(minLength: 16)
                importNodesButton
                exportNodesButton
                newNodeButton
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ccSwitchSyncButton
                    configFileButton
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    importNodesButton
                    exportNodesButton
                    Spacer(minLength: 8)
                    newNodeButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppSurface.card(colorScheme).opacity(colorScheme == .dark ? 0.78 : 1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    private var configFileButton: some View {
        actionBarButton(
            title: "opencode.json",
            icon: "doc.text.magnifyingglass",
            role: .file,
            help: L("View and edit the live opencode.json with syntax highlighting.", "查看并编辑当前生效的 opencode.json（语法高亮）。")
        ) {
            showConfigFileEditor = true
        }
    }

    private var ccSwitchSyncButton: some View {
        actionBarButton(
            title: isSyncingCCSwitch ? L("Importing", "导入中") : L("Import cc-switch", "导入 cc-switch"),
            icon: "tray.and.arrow.down.fill",
            role: .secondary,
            help: L(
                "Mirror-sync OpenCode providers from cc-switch (repeat syncs update the same nodes).",
                "从 cc-switch 镜像同步 OpenCode 供应商（重复同步更新同一批节点，不产生重复）。"
            )
        ) {
            syncCCSwitch()
        }
        .disabled(isSyncingCCSwitch)
    }

    private var importNodesButton: some View {
        actionBarButton(
            title: L("Import Nodes", "导入节点"),
            icon: "square.and.arrow.down",
            role: .secondary,
            help: L("Import node profiles from a JSON file.", "从 JSON 文件导入节点配置。")
        ) {
            importNodesFromFile()
        }
    }

    private var exportNodesButton: some View {
        actionBarButton(
            title: L("Export Nodes", "导出节点"),
            icon: "square.and.arrow.up",
            role: .secondary,
            help: L("Export all nodes to a JSON file (includes API keys).", "把全部节点导出为 JSON 文件（含 API Key）。")
        ) {
            exportNodesToFile()
        }
        .disabled(store.nodes.isEmpty)
    }

    private var newNodeButton: some View {
        actionBarButton(
            title: L("New Node", "新建节点"),
            icon: "plus.circle.fill",
            role: .primary,
            help: L("Create a new OpenCode node.", "新建一个 OpenCode 节点。")
        ) {
            editingNode = OpenCodeNode()
        }
        .keyboardShortcut("n", modifiers: [.command])
    }

    private enum ActionBarButtonRole {
        case secondary
        case file
        case primary
    }

    private func actionBarButton(
        title: String,
        icon: String,
        role: ActionBarButtonRole,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(actionButtonForeground(role))
            .padding(.horizontal, 11)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(actionButtonBackground(role))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(actionButtonBorder(role), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func actionButtonForeground(_ role: ActionBarButtonRole) -> Color {
        switch role {
        case .primary: return .white
        case .file: return .blue
        case .secondary: return .primary
        }
    }

    private func actionButtonBackground(_ role: ActionBarButtonRole) -> Color {
        switch role {
        case .primary: return Color.accentColor
        case .file: return Color.blue.opacity(colorScheme == .dark ? 0.18 : 0.10)
        case .secondary: return colorScheme == .dark ? Color.white.opacity(0.075) : Color.primary.opacity(0.045)
        }
    }

    private func actionButtonBorder(_ role: ActionBarButtonRole) -> Color {
        switch role {
        case .primary: return Color.white.opacity(colorScheme == .dark ? 0.18 : 0.12)
        case .file: return Color.blue.opacity(colorScheme == .dark ? 0.30 : 0.18)
        case .secondary: return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.08)
        }
    }

    // MARK: - cc-switch Sync

    func syncCCSwitch() {
        guard !isSyncingCCSwitch else { return }
        isSyncingCCSwitch = true
        Task { @MainActor in
            let result = await store.importCCSwitchOpenCodeNodes()
            isSyncingCCSwitch = false
            if result.imported == 0, result.updated == 0 {
                actionError = result.errors.first.map { error in
                    L("cc-switch sync failed: \(error)", "cc-switch 同步失败：\(error)")
                } ?? L("No cc-switch OpenCode providers found.", "未在 cc-switch 中找到 OpenCode 供应商。")
            } else {
                var summary = L(
                    "Synced from cc-switch: \(result.imported) new, \(result.updated) updated.",
                    "已从 cc-switch 同步：新增 \(result.imported) 个，更新 \(result.updated) 个。"
                )
                if result.failed > 0 {
                    summary += L(" \(result.failed) failed.", " 失败 \(result.failed) 个。")
                }
                importSummary = summary
            }
        }
    }

    // MARK: - Import / Export

    func importNodesFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = L("Choose an exported OpenCode nodes JSON file", "选择导出的 OpenCode 节点 JSON 文件")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let result = try store.importNodes(from: data)
            importSummary = L(
                "Imported \(result.imported) node(s), skipped \(result.skipped) duplicate(s).",
                "已导入 \(result.imported) 个节点，跳过 \(result.skipped) 个重复项。"
            )
        } catch {
            actionError = L(
                "Import failed: the file is not a valid OpenCode nodes export.",
                "导入失败：文件不是有效的 OpenCode 节点导出。"
            )
        }
    }

    func exportNodesToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "opencode-nodes.json"
        panel.message = L("Exported file includes API keys — keep it safe.", "导出文件包含 API Key，请妥善保管。")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try store.exportNodes()
            try data.write(to: url, options: .atomic)
        } catch {
            actionError = error.localizedDescription
        }
    }
}
