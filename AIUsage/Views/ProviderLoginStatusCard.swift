import AppKit
import SwiftUI

// MARK: - Visual State
// 登录卡片对外呈现的单一真相源。错误永远优先于成功，接入中（导入账号）单独成态。
// 由 LoginPhase（Service 层）+ 视图侧的 errorMessage / isWorking 共同推导。

enum ProviderLoginVisualState: Equatable {
    case launching
    case awaitingBrowser
    case awaitingCompletion
    case connecting
    case succeeded
    case failed(String)

    /// 浏览器/设备码步骤仍在进行（此时才显示「重新打开 / 复制链接 / 取消」等操作）。
    var isAwaiting: Bool {
        switch self {
        case .launching, .awaitingBrowser, .awaitingCompletion:
            return true
        case .connecting, .succeeded, .failed:
            return false
        }
    }
}

struct ProviderLoginAction {
    let title: String
    let perform: () -> Void
}

// MARK: - Unified Login Status Card
// 5 个服务商登录区共用的统一卡片：顶部状态行（含状态指示与操作按钮）+ 信息卡片（说明 / 设备码 / 账号徽标）。

struct ProviderLoginStatusCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: ProviderLoginVisualState
    let title: String
    let description: String
    var deviceCode: String? = nil
    var deviceCodePrompt: String? = nil
    var accountBadge: String? = nil
    var inProgressLabel: String = ""
    var connectingLabel: String
    var succeededLabel: String
    var copyLink: ProviderLoginAction? = nil
    var reopen: ProviderLoginAction? = nil
    var onCancel: (() -> Void)? = nil
    var cardMinHeight: CGFloat = 148

    private var showsDeviceCode: Bool {
        guard let deviceCode, !deviceCode.isEmpty else { return false }
        return state.isAwaiting
    }

    /// 失败态不显示绿色账号徽标，避免再出现「绿徽标 + 红错误」的混合信号。
    private var showsAccountBadge: Bool {
        guard let accountBadge, !accountBadge.isEmpty else { return false }
        if case .failed = state { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            infoCard
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIndicator

            Spacer(minLength: 8)

            if state.isAwaiting {
                if let copyLink {
                    actionButton(copyLink.title, action: copyLink.perform)
                }
                if let reopen {
                    actionButton(reopen.title, action: reopen.perform)
                }
                if let onCancel {
                    actionButton(L("Cancel Login", "取消登录"), action: onCancel)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch state {
        case .launching, .awaitingBrowser, .awaitingCompletion:
            ProgressView().controlSize(.small)
            Text(inProgressLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connecting:
            ProgressView().controlSize(.small)
            Text(connectingLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(succeededLabel)
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .controlSize(.small)
    }

    // MARK: Info card

    private var infoCard: some View {
        // 内容驱动布局：卡片随内容生长，避免长文案/本地化时溢出或与相邻视图重叠。
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if showsDeviceCode, let deviceCode {
                deviceCodeBlock(deviceCode)
            } else {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsAccountBadge, let accountBadge {
                Label(accountBadge, systemImage: "person.crop.circle.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: cardMinHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    private func deviceCodeBlock(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let deviceCodePrompt, !deviceCodePrompt.isEmpty {
                Text(deviceCodePrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(code)
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(L("Copy code", "复制验证码"))
            }
        }
    }
}
