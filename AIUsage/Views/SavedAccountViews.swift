import SwiftUI
import AppKit

struct SavedAccountCard: View {
    let account: ProviderAccountEntry
    var onReconnect: (() -> Void)?

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingDetail = false
    @State private var showingNoteEditor = false
    @State private var isRefreshing = false
    @State private var pendingAccountDeletion = false
    private var hasSecureCredential: Bool {
        account.storedAccount?.credentialId != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ProviderIconView(account.providerId, size: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(account.cardTitle)
                        .font(.headline)
                        .bold()

                    if let accountLabel = account.footerAccountLabel {
                        Label(accountLabel, systemImage: accountIdentityIcon(for: accountLabel))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    if hasSecureCredential {
                        Text(L("Offline", "离线"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.10))
                            .clipShape(Capsule())
                    } else {
                        Text(L("Saved", "已保存"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(
                    hasSecureCredential
                        ? L("Credential may have expired", "凭证可能已过期")
                        : L("Awaiting a live session", "等待在线会话")
                )
                    .font(.title3)
                    .bold()

                if let note = account.accountNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(
                    hasSecureCredential
                        ? L("The stored credential could not fetch live data. Try refreshing or reconnecting.", "已存储的凭证未能获取实时数据。可尝试刷新或重新连接。")
                        : L("Account saved locally. Will auto-match when the app session appears.", "账号已保存到本地。对应应用出现在线会话后会自动匹配。")
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                if hasSecureCredential {
                    Button {
                        guard !isRefreshing, let credentialId = account.storedAccount?.credentialId else { return }
                        isRefreshing = true
                        refreshCoordinator.refreshAccount(credentialId: credentialId, providerId: account.providerId)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isRefreshing = false }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(L("Retry", "重试"), systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRefreshing)

                    if let onReconnect {
                        Button(action: onReconnect) {
                            Label(L("Reconnect", "重新连接"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                Spacer()

                if let lastSeen = account.storedAccount?.lastSeenAt,
                   let date = parseISO8601(lastSeen) {
                    Text(formatRelativeTimeFromDate(date, language: appState.language))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 148)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
        .onTapGesture { showingDetail = true }
        .contextMenu {
            Button {
                showingDetail = true
            } label: {
                Label(L("Open Details", "查看详情"), systemImage: "doc.text.magnifyingglass")
            }

            Button {
                showingNoteEditor = true
            } label: {
                Label(L("Edit Note", "编辑注释"), systemImage: "square.and.pencil")
            }

            if let accountLabel = account.footerAccountLabel {
                Button {
                    copyToPasteboard(accountLabel)
                } label: {
                    Label(L("Copy Account", "复制账号"), systemImage: "doc.on.doc")
                }
            }

            SubscriptionAccountDestructiveMenuItems(
                onHide: { appState.hideAccount(account) },
                onRequestDelete: { pendingAccountDeletion = true }
            )
        }
        .subscriptionAccountDeleteConfirmation(isPresented: $pendingAccountDeletion) {
            appState.deleteAccount(account)
        }
        .sheet(isPresented: $showingDetail) {
            SavedAccountDetailView(account: account, onReconnect: onReconnect)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingNoteEditor) {
            AccountNoteEditorView(
                providerTitle: account.providerTitle,
                accountLabel: account.accountPrimaryLabel,
                note: account.accountNote
            ) { updatedNote in
                appState.updateAccountNote(for: account, note: updatedNote)
            }
            .environmentObject(appState)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct SavedAccountDetailView: View {
    let account: ProviderAccountEntry
    var onReconnect: (() -> Void)?

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingNoteEditor = false
    @State private var showingRemovalAlert = false
    @State private var isRefreshing = false
    private var hasSecureCredential: Bool {
        account.storedAccount?.credentialId != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProviderIconView(account.providerId, size: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(account.cardTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if let accountLabel = account.footerAccountLabel {
                        Text(accountLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Text(hasSecureCredential ? L("Offline", "离线") : L("Saved", "已保存"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(hasSecureCredential ? .orange : .blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((hasSecureCredential ? Color.orange : Color.blue).opacity(0.12), in: Capsule())

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Account Note", "账号注释"))
                        .font(.subheadline.weight(.semibold))
                    Text(account.accountNote?.nilIfBlank ?? L("No note yet.", "当前还没有注释。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppSurface.card(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppStroke.subtle(colorScheme), lineWidth: 1)
                )

                Label(
                    hasSecureCredential
                        ? L("Credential stored in Keychain", "凭证已存入钥匙串")
                        : L("Account record stored locally", "账号记录已保存到本地"),
                    systemImage: hasSecureCredential ? "lock.shield" : "tray.full"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let lastSeen = account.storedAccount?.lastSeenAt,
                   let date = parseISO8601(lastSeen) {
                    Text(formatRelativeTimeFromDate(date, language: appState.language))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    if hasSecureCredential {
                        Button {
                            guard !isRefreshing, let credentialId = account.storedAccount?.credentialId else { return }
                            isRefreshing = true
                            refreshCoordinator.refreshAccount(credentialId: credentialId, providerId: account.providerId)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isRefreshing = false }
                        } label: {
                            if isRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(L("Retry", "重试"), systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRefreshing)

                        if let onReconnect {
                            Button {
                                onReconnect()
                                dismiss()
                            } label: {
                                Label(L("Reconnect", "重新连接"), systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    Menu {
                        Button {
                            showingNoteEditor = true
                        } label: {
                            Label(L("Edit Note", "编辑注释"), systemImage: "square.and.pencil")
                        }
                        Button {
                            appState.hideAccount(account)
                            dismiss()
                        } label: {
                            Label(SubscriptionAccountActionCopy.hideTitle, systemImage: "eye.slash")
                        }
                        Button(role: .destructive) {
                            showingRemovalAlert = true
                        } label: {
                            Label(SubscriptionAccountActionCopy.deleteTitle, systemImage: "trash")
                        }
                    } label: {
                        Label(L("More", "更多"), systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)

                    Spacer()

                    Button(L("Done", "完成")) { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 400, height: 320)
        .appPageChrome(colorScheme)
        .sheet(isPresented: $showingNoteEditor) {
            AccountNoteEditorView(
                providerTitle: account.providerTitle,
                accountLabel: account.accountPrimaryLabel,
                note: account.accountNote
            ) { updatedNote in
                appState.updateAccountNote(for: account, note: updatedNote)
            }
            .environmentObject(appState)
        }
        .subscriptionAccountDeleteConfirmation(isPresented: $showingRemovalAlert) {
            appState.deleteAccount(account)
            dismiss()
        }
    }
}
