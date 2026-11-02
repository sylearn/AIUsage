import QuotaBackend
import SwiftUI

// MARK: - Menu Bar · Recent Sessions
// 菜单栏额度区下方的「最近会话」：最多 4 条，可折叠（状态记住）。
// 点行打开主窗口会话中心并选中；点右侧按钮直接在终端继续。面板打开期间实时更新，会话进行中时显示标记。
// 菜单栏宿主是 transient NSPopover，这里不弹任何嵌套 popover 或原生 Menu。

struct MenuBarRecentSessionsSection: View {
    @ObservedObject private var store = SessionCenterStore.shared
    @ObservedObject private var settings = AppSettings.shared
    let onOpenSessionCenter: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            header
            if settings.menuBarRecentSessionsExpanded {
                rows
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .onAppear { store.beginObserving() }
        .onDisappear { store.endObserving() }
        .task { await store.refresh() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { settings.menuBarRecentSessionsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(settings.menuBarRecentSessionsExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    Text(L("Recent Sessions", "最近会话", key: "menubar.recent_sessions"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if let flash = store.flash {
                Text(flash.message)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(flash.kind == .error ? Color.orange : Color.green)
                    .lineLimit(1)
                    .transition(.opacity)
            } else {
                Button(L("All", "全部", key: "menubar.recent_sessions.all")) {
                    onOpenSessionCenter()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var rows: some View {
        if !store.hasScanned {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 8)
        } else if store.recentSessions.isEmpty {
            Text(L("No local sessions yet", "还没有本机会话", key: "menubar.recent_sessions.empty"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 1) {
                ForEach(store.recentSessions) { session in
                    MenuBarSessionRow(session: session) {
                        store.reveal(session)
                        onOpenSessionCenter()
                    } resume: {
                        Task { await store.resume(session) }
                    }
                }
            }
        }
    }
}

private struct MenuBarSessionRow: View {
    let session: SessionSummary
    let open: () -> Void
    let resume: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: 9) {
                    ProviderIconView(session.tool.rawValue, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if let activity = session.activity {
                                SessionActivityLabel(activity: activity, tool: session.tool)
                                    .fontWeight(.medium)
                                    .foregroundStyle(SessionActivityDot.tint(activity, colorScheme))
                                Text("·")
                            }
                            Text([session.projectName, SessionDateText.short(session.updatedAt)]
                                .compactMap { $0 }.joined(separator: " · "))
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Open in Sessions", "在会话中心查看", key: "menubar.recent_sessions.open"))

            // 平时只露图标，悬停到这一行才出底色，四行并排时不显得重。
            Button(action: resume) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .frame(width: 26, height: 24)
                    .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(session.resumeBlocker != nil)
            .opacity(session.resumeBlocker == nil ? 1 : 0.4)
            .help(session.resumeBlocker == nil
                  ? L("Resume in terminal", "在终端继续", key: "menubar.recent_sessions.resume")
                  : SessionReaderView.blockerText(session.resumeBlocker))
            .accessibilityLabel(L("Resume in terminal", "在终端继续", key: "menubar.recent_sessions.resume"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
    }
}
