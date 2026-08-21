import AppKit
import QuotaBackend
import SwiftUI

// MARK: - CPA Runtime Control
// 顶栏运行态控件：状态灯 + 端口摘要，点击展开电源/维护面板（非系统 Menu 三角）。

struct GatewayRuntimeControl: View {
    @ObservedObject var manager: CLIProxyGatewayManager
    @ObservedObject var runtime: CLIProxyRuntimeController
    let onOpenSettings: () -> Void

    @State private var isOpen = false
    @State private var isHovered = false

    private var port: Int { runtime.settings.normalized.port }
    private var tint: Color {
        switch runtime.state {
        case .running: return Color(red: 0.20, green: 0.72, blue: 0.45)
        case .starting, .stopping: return Color(red: 0.95, green: 0.62, blue: 0.18)
        case .failed: return Color(red: 0.92, green: 0.38, blue: 0.32)
        case .stopped: return Color.secondary
        }
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(runtime.state.isRunning ? 0.28 : 0.16))
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    Text(statusTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.92))
                    Text(statusSubtitle)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary.opacity(isHovered || isOpen ? 0.85 : 0.35))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .animation(.easeInOut(duration: 0.18), value: isOpen)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isHovered || isOpen ? 0.07 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(isOpen ? 0.35 : 0.16), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(runtime.state.isTransitioning || manager.operation.isBusy)
        .opacity(runtime.state.isTransitioning || manager.operation.isBusy ? 0.55 : 1)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            panel
        }
        .help(L("CPA runtime actions", "CPA 运行操作"))
        .accessibilityLabel(statusTitle)
        .accessibilityHint(L("Open runtime controls", "打开运行控制"))
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBlock
            Divider().opacity(0.55).padding(.vertical, 6)
            powerSection
            Divider().opacity(0.55).padding(.vertical, 6)
            maintenanceSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: 236)
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(statusTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
                if let version = manager.currentVersion {
                    Text("v\(version)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            Text(detailLine)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if case .failed(let message) = runtime.state, !message.isEmpty {
                Text(SensitiveDataRedactor.redactPaths(in: message))
                    .font(.system(size: 10.5))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }

            if case .running(let pid) = runtime.state {
                Text(L("PID \(pid)", "PID \(pid)"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var powerSection: some View {
        if runtime.state.isRunning {
            panelRow(
                title: L("Stop CPA", "停止 CPA"),
                systemImage: "stop.fill",
                destructive: true
            ) {
                isOpen = false
                Task { await runtime.stop() }
            }
            panelRow(
                title: L("Restart CPA", "重启 CPA"),
                systemImage: "arrow.clockwise"
            ) {
                isOpen = false
                Task { await runtime.restart() }
            }
        } else {
            panelRow(
                title: L("Start CPA", "启动 CPA"),
                systemImage: "play.fill",
                emphasized: true
            ) {
                isOpen = false
                Task { await runtime.start() }
            }
        }
    }

    @ViewBuilder
    private var maintenanceSection: some View {
        panelRow(
            title: L("Refresh Status", "刷新状态"),
            systemImage: "arrow.triangle.2.circlepath"
        ) {
            isOpen = false
            Task { await manager.refresh(checkRemote: false) }
        }
        panelRow(
            title: L("Open Settings", "打开设置"),
            systemImage: "gearshape"
        ) {
            isOpen = false
            onOpenSettings()
        }
    }

    private func panelRow(
        title: String,
        systemImage: String,
        destructive: Bool = false,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        GatewayRuntimePanelRow(
            title: title,
            systemImage: systemImage,
            destructive: destructive,
            emphasized: emphasized,
            accent: tint,
            action: action
        )
    }

    private var statusTitle: String {
        switch runtime.state {
        case .stopped: return L("CPA stopped", "CPA 已停止")
        case .starting: return L("Starting…", "正在启动…")
        case .running: return L("CPA running", "CPA 运行中")
        case .stopping: return L("Stopping…", "正在停止…")
        case .failed: return L("CPA needs attention", "CPA 需要处理")
        }
    }

    private var statusSubtitle: String {
        switch runtime.state {
        case .running:
            return ":\(port)"
        case .failed:
            return L("Action needed", "需要处理")
        case .starting, .stopping:
            return L("Please wait", "请稍候")
        case .stopped:
            return ":\(port)"
        }
    }

    private var detailLine: String {
        let host = runtime.settings.normalized.bindHost
        let displayHost = host.isEmpty || host == "0.0.0.0" || host == "::" ? "127.0.0.1" : host
        return "\(displayHost):\(port)"
    }
}

private struct GatewayRuntimePanelRow: View {
    let title: String
    let systemImage: String
    var destructive = false
    var emphasized = false
    let accent: Color
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(iconBackground)
                    )
                Text(title)
                    .font(.system(size: 12.5, weight: emphasized ? .semibold : .medium))
                    .foregroundStyle(titleColor)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var iconColor: Color {
        if destructive { return .red.opacity(0.9) }
        if emphasized { return accent }
        return .secondary
    }

    private var iconBackground: Color {
        if destructive { return Color.red.opacity(0.10) }
        if emphasized { return accent.opacity(0.14) }
        return Color.primary.opacity(0.05)
    }

    private var titleColor: Color {
        if destructive { return .red.opacity(0.95) }
        return Color.primary.opacity(0.92)
    }
}
