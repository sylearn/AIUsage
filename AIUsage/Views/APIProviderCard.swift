import SwiftUI
import AppKit
import QuotaBackend

// MARK: - Inheritance Banner
// 链接节点编辑器顶部横幅：提示该节点继承自某「API 提供商」主配置，并提供「重置为继承」
// （丢弃本地覆盖，按主配置当前值整体重写本节点）。

struct InheritanceBanner: View {
    let providerName: String
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Linked to API provider \"\(providerName)\"", "继承自 API 提供商「\(providerName)」"))
                    .font(.caption.weight(.semibold))
                Text(L(
                    "Shared fields follow the provider. Editing one here keeps it local; use Reset to follow the provider again.",
                    "共享字段跟随主配置；在此修改即转为本地覆盖，点「重置为继承」可恢复跟随。"
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(L("Reset to Inherit", "重置为继承")) { onReset() }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
    }
}

// MARK: - API Provider Card
// 「API 提供商」列表行：安静表面（已分发不再整卡蓝染），格式徽章贴标题旁，
// 模型/默认模型收进次要元信息行，分发状态用安静胶囊。右键菜单承担复制/同步/复制等。

struct APIProviderCard: View {
    enum SyncPhase: Equatable {
        case idle
        case syncing
        case success
        case failure
    }

    let provider: APIProvider
    let distributedTargets: Set<ProxyTarget>
    var syncPhase: SyncPhase = .idle

    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onEdit: () -> Void = {}
    var onSync: () -> Void = {}
    var onDuplicate: () -> Void = {}
    var onDelete: () -> Void = {}
    var onCopied: (String) -> Void = { _ in }
    var onOpenTarget: (ProxyTarget) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    private var isDistributed: Bool { !distributedTargets.isEmpty }

    private static let chatBrand = Color(red: 0.29, green: 0.73, blue: 0.56)
    private static let anthropicBrand = Color(red: 0.85, green: 0.47, blue: 0.34)
    private static let responsesBrand = Color(red: 0.40, green: 0.52, blue: 0.92)

    private var formatColor: Color {
        switch provider.format {
        case .openAIChatCompletions: return Self.chatBrand
        case .anthropic: return Self.anthropicBrand
        case .openAIResponses: return Self.responsesBrand
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            dragHandle
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                titleRow
                Text(provider.baseURL.nilIfBlank ?? L("Base URL not set", "未设置 Base URL"))
                    .font(.caption)
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                NodeBalanceLine(target: balanceTarget)
                metaRow
                distributionLine
            }

            Spacer(minLength: 8)

            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .contextMenu { contextMenu }
    }

    private var balanceTarget: APIKeyBalanceTarget? {
        APIKeyBalanceTarget(baseURL: provider.baseURL, apiKey: provider.apiKey)
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(provider.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppContent.primary(colorScheme))
                .lineLimit(1)
            formatBadge
            Spacer(minLength: 0)
        }
    }

    // MARK: - Meta

    private var metaRow: some View {
        HStack(spacing: 6) {
            Text(L("\(provider.models.count) models", "\(provider.models.count) 个模型"))
                .font(.caption2)
                .foregroundStyle(AppContent.tertiary(colorScheme))
            if let dm = provider.effectiveDefaultModel.nilIfBlank {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(AppContent.tertiary(colorScheme))
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange.opacity(0.85))
                Text(dm)
                    .font(.caption2)
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Drag Handle

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.quaternary)
            .frame(width: 16, height: 28)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { onDragChanged($0.translation.height) }
                    .onEnded { _ in onDragEnded() }
            )
    }

    // MARK: - Format Badge

    private var formatBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: 7, weight: .bold))
            Text(provider.format.badgeName)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(formatColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(formatColor.opacity(0.12)))
        .help(L(
            "API format: \(provider.format.displayName)",
            "接口格式：\(provider.format.displayName)"
        ))
    }

    // MARK: - Distribution Line

    @ViewBuilder
    private var distributionLine: some View {
        if isDistributed {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppContent.tertiary(colorScheme))
                ForEach(ProxyTarget.allCases.filter { distributedTargets.contains($0) }) { target in
                    Button {
                        onOpenTarget(target)
                    } label: {
                        HStack(spacing: 3) {
                            Text(target.displayName)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppSurface.chip(colorScheme)))
                        .foregroundStyle(AppContent.secondary(colorScheme))
                    }
                    .buttonStyle(.plain)
                    .help(L("Open \(target.displayName)", "打开 \(target.displayName)"))
                }
            }
        } else {
            Text(L("Not distributed", "未分发"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppContent.tertiary(colorScheme))
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 4) {
            syncButton
            actionIconButton(
                systemImage: "pencil",
                help: L("Edit", "编辑"),
                action: onEdit
            )
            actionIconButton(
                systemImage: "trash",
                help: L("Delete", "删除"),
                tint: .red,
                action: onDelete
            )
        }
    }

    private var syncButton: some View {
        Button(action: onSync) {
            Group {
                switch syncPhase {
                case .idle:
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(
                            isDistributed
                                ? AppContent.secondary(colorScheme)
                                : AppContent.tertiary(colorScheme).opacity(0.45)
                        )
                case .syncing:
                    ProgressView()
                        .controlSize(.small)
                case .success:
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.green)
                case .failure:
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 28, height: 28)
            .background(syncBackground, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isDistributed || syncPhase == .syncing)
        .help(syncHelp)
        .animation(.easeInOut(duration: 0.15), value: syncPhase)
    }

    private var syncBackground: Color {
        switch syncPhase {
        case .idle: return AppSurface.chip(colorScheme)
        case .syncing: return AppSurface.chip(colorScheme)
        case .success: return Color.green.opacity(0.16)
        case .failure: return Color.red.opacity(0.14)
        }
    }

    private var syncHelp: String {
        switch syncPhase {
        case .idle:
            return L("Re-apply this provider to its linked nodes.", "把本提供商重新应用到所有链接节点。")
        case .syncing:
            return L("Syncing…", "同步中…")
        case .success:
            return L("Synced", "已同步")
        case .failure:
            return L("Sync failed", "同步失败")
        }
    }

    private func actionIconButton(
        systemImage: String,
        help: String,
        enabled: Bool = true,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    enabled
                        ? (tint ?? AppContent.secondary(colorScheme))
                        : AppContent.tertiary(colorScheme).opacity(0.45)
                )
                .frame(width: 28, height: 28)
                .background(AppSurface.chip(colorScheme), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenu: some View {
        NodeBalanceMenu(target: balanceTarget)
        Button(action: onEdit) {
            Label(L("Edit", "编辑"), systemImage: "pencil")
        }
        Button(action: onSync) {
            Label(L("Sync Now", "立即同步"), systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!isDistributed || syncPhase == .syncing)

        Button {
            ModelAutoSyncCoordinator.shared.syncNow(.provider(provider.id))
        } label: {
            Label(L("Update Models & Prices", "更新模型与价格"), systemImage: "arrow.down.circle")
        }
        .disabled(provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Button(action: onDuplicate) {
            Label(L("Duplicate", "创建副本"), systemImage: "plus.square.on.square")
        }

        Divider()

        Button {
            copyToPasteboard(provider.baseURL)
            onCopied(L("Base URL copied", "已复制 Base URL"))
        } label: {
            Label(L("Copy Base URL", "复制 Base URL"), systemImage: "link")
        }
        .disabled(provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Button {
            copyToPasteboard(provider.apiKey)
            onCopied(L("API Key copied", "已复制 API Key"))
        } label: {
            Label(L("Copy API Key", "复制 API Key"), systemImage: "key")
        }
        .disabled(provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        if let dm = provider.effectiveDefaultModel.nilIfBlank {
            Button {
                copyToPasteboard(dm)
                onCopied(L("Default model copied", "已复制默认模型"))
            } label: {
                Label(L("Copy Default Model", "复制默认模型"), systemImage: "star")
            }
        }

        Divider()

        Button(role: .destructive, action: onDelete) {
            Label(L("Delete", "删除"), systemImage: "trash")
        }
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

// MARK: - Row Height Key
// 测量提供商卡片真实高度，供拖拽让位的阈值/步幅计算（与节点列表同一套手感）。

struct APIProviderRowHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
