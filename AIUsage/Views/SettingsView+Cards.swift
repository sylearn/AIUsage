import SwiftUI
import QuotaBackend

// MARK: - Section Views

extension SettingsView {

    // MARK: - General

    var generalSection: some View {
        settingsCard(
            title: L("General", "通用"),
            subtitle: L("Language, appearance, and basic preferences.", "语言、外观和基本偏好设置。")
        ) {
            settingsBlock(title: L("Language", "语言")) {
                CapsuleSegmentedPicker(
                    options: [
                        CapsuleSegmentOption("en", title: "English"),
                        CapsuleSegmentOption("zh", title: "中文")
                    ],
                    selection: $settings.language
                )
            }

            Divider()

            settingsBlock(
                title: L("Theme", "主题"),
                subtitle: L("Choose app appearance: follow system, light, or dark.", "选择外观模式：跟随系统、浅色或深色。")
            ) {
                CapsuleSegmentedPicker(
                    options: [
                        CapsuleSegmentOption("system", title: L("System", "系统")),
                        CapsuleSegmentOption("light", title: L("Light", "浅色")),
                        CapsuleSegmentOption("dark", title: L("Dark", "深色"))
                    ],
                    selection: $settings.themeMode
                )
            }

            Divider()

            settingsBlock(
                title: L("Display Currency", "显示货币"),
                subtitle: L("Currency for cost display across the app.", "应用中费用显示的货币单位。")
            ) {
                CapsuleSegmentedPicker(
                    options: [
                        CapsuleSegmentOption("USD", title: "USD ($)"),
                        CapsuleSegmentOption("CNY", title: "CNY (¥)")
                    ],
                    selection: Binding(
                        get: { UserDefaults.standard.string(forKey: DefaultsKey.displayCurrency) ?? "USD" },
                        set: { UserDefaults.standard.set($0, forKey: DefaultsKey.displayCurrency) }
                    )
                )
            }

            Divider()

            settingsBlock(
                title: L("CNY / USD Rate", "CNY/USD 汇率"),
                subtitle: L(
                    "Approximate rate to convert CNY pricing to USD and to display costs in CNY. Not a real billing rate.",
                    "把人民币定价折算为美元、以及以人民币显示费用时使用的近似汇率，并非真实计费汇率。"
                )
            ) {
                HStack(spacing: 8) {
                    Text("1 USD =")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField(
                        "\(AppSettings.defaultCNYPerUSD)",
                        value: $settings.cnyExchangeRate,
                        format: .number.precision(.fractionLength(0...4))
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    Text("CNY")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            settingsToggleRow(
                title: L("Launch at Login", "开机启动"),
                subtitle: L("Open AIUsage automatically after login.", "登录系统后自动打开 AIUsage。"),
                isOn: $launchAtLogin
            )

            Divider()

            settingsToggleRow(
                title: L("Launch Hidden", "启动后隐藏主窗口"),
                subtitle: L(
                    "Start silently in the menu bar without showing the main window. Reopen it from the menu bar icon.",
                    "启动后不弹出主窗口，仅驻留菜单栏；可从菜单栏图标随时唤起。"
                ),
                isOn: Binding(
                    get: { launchHidden },
                    set: {
                        launchHidden = $0
                        UserDefaults.standard.set($0, forKey: DefaultsKey.launchHidden)
                    }
                )
            )

            Divider()

            settingsToggleRow(
                title: L("Hide Dock Icon", "隐藏 Dock 图标"),
                subtitle: L("Keep AIUsage in the menu bar only.", "让 AIUsage 只出现在菜单栏。"),
                isOn: $hideDockIcon
            )
            .help(L("The app will only appear in the menu bar", "应用将只显示在菜单栏"))

            Divider()

            // issue #39：关闭时最小化到托盘。Dock 可见时关窗即隐藏 Dock 图标、常驻菜单栏，
            // 从菜单栏唤起再恢复 Dock。隐藏 Dock 模式下本就只在菜单栏，故强制显示为开并禁用。
            settingsToggleRow(
                title: L("Minimize to Tray on Close", "关闭时最小化到托盘"),
                subtitle: hideDockIcon
                    ? L(
                        "Always on while the Dock icon is hidden — the app lives in the menu bar.",
                        "隐藏 Dock 图标时始终开启——应用常驻菜单栏。"
                    )
                    : L(
                        "Closing the main window hides the Dock icon and keeps the app in the menu bar. Reopen it from the menu bar icon.",
                        "关闭主窗口时隐藏 Dock 图标并常驻菜单栏；可从菜单栏图标随时唤起。"
                    ),
                isOn: Binding(
                    get: { hideDockIcon ? true : closeToTray },
                    set: {
                        closeToTray = $0
                        UserDefaults.standard.set($0, forKey: DefaultsKey.closeToTray)
                    }
                )
            )
            .disabled(hideDockIcon)

            Divider()

            // issue #31：后台运行与 Dock 显示解耦。隐藏 Dock 或「最小化到托盘」时必须常驻
            // （仅菜单栏入口），故强制显示为开并禁用；否则用户可自由选择关窗是否退出。
            settingsToggleRow(
                title: L("Keep Running in Background", "保持后台运行"),
                subtitle: (hideDockIcon || closeToTray)
                    ? L(
                        "Always on while minimizing to the menu bar.",
                        "最小化到菜单栏时始终开启。"
                    )
                    : L(
                        "Keep the app running after closing the main window. Turn off to quit on close.",
                        "关闭主窗口后继续在后台运行。关闭此项则关窗即退出。"
                    ),
                isOn: Binding(
                    get: { (hideDockIcon || closeToTray) ? true : keepRunningInBackground },
                    set: {
                        keepRunningInBackground = $0
                        UserDefaults.standard.set($0, forKey: DefaultsKey.keepRunningInBackground)
                    }
                )
            )
            .disabled(hideDockIcon || closeToTray)

            Divider()

            sidebarVisibilityBlock
        }
    }

    // MARK: - Data & Refresh

    var dataRefreshSection: some View {
        settingsCard(
            title: L("Data & Refresh", "数据与刷新"),
            subtitle: L("Backend mode and refresh intervals.", "后端模式和数据刷新频率。")
        ) {
            settingsBlock(
                title: L("Backend Mode", "后端模式"),
                subtitle: L(
                    "Local: sign in and fetch quotas on this Mac. Remote: read the quota snapshot shared by AIUsage on another Mac — no sign-in needed here.",
                    "本地：在本机登录并抓取各账号额度。远程：读取另一台 Mac 上 AIUsage 共享的额度快照，本机无需登录账号。"
                )
            ) {
                CapsuleSegmentedPicker(
                    options: [
                        CapsuleSegmentOption("local", title: L("Local", "本地")),
                        CapsuleSegmentOption("remote", title: L("Remote", "远程"))
                    ],
                    selection: $settings.backendMode
                )
                .onChange(of: settings.backendMode) { _, _ in
                    settings.saveSettings()
                    refreshCoordinator.refreshAllProviders()
                }
            }

            if settings.backendMode == "remote" {
                Divider()

                remoteBackendBlock
            } else {
                Divider()

                quotaShareBlock
            }

            Divider()

            settingsBlock(
                title: L("Providers auto-refresh", "服务商自动刷新"),
                subtitle: L("Refresh interval for API-based providers (OpenAI, Anthropic, etc.)", "API 服务商的刷新间隔（OpenAI、Anthropic 等）")
            ) {
                Picker("", selection: $settings.autoRefreshInterval) {
                    ForEach(AppSettings.supportedAutoRefreshIntervals, id: \.self) { interval in
                        Text(autoRefreshTitle(for: interval)).tag(interval)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
            }

            Divider()

            settingsBlock(
                title: L("Local token stats auto-refresh", "本地 Token 统计自动刷新"),
                subtitle: L("Refresh interval for local Claude and Codex token stats (faster intervals available)", "本地 Claude 与 Codex Token 统计的刷新间隔（支持更短间隔）")
            ) {
                Picker("", selection: $settings.claudeCodeRefreshInterval) {
                    ForEach(AppSettings.supportedClaudeCodeRefreshIntervals, id: \.self) { interval in
                        Text(claudeCodeRefreshTitle(for: interval)).tag(interval)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
            }

            Divider()

            settingsBlock(
                title: L("cc-switch Config Directory", "cc-switch 配置目录"),
                subtitle: L(
                    "Used by all three cc-switch sync buttons (Claude / Codex / OpenCode). Leave empty to auto-detect: custom directory from cc-switch's own settings first, then ~/.cc-switch.",
                    "三处「同步 cc-switch」（Claude / Codex / OpenCode）共用。留空则自动探测：优先读取 cc-switch 自身记录的自定义目录，其次 ~/.cc-switch。"
                )
            ) {
                HStack(spacing: 8) {
                    TextField("~/.cc-switch", text: $ccSwitchDirInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { applyCCSwitchDir() }
                    Button(L("Choose…", "选择…")) { chooseCCSwitchDir() }
                    if !ccSwitchDirInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(L("Reset", "清除")) {
                            ccSwitchDirInput = ""
                            applyCCSwitchDir()
                        }
                    }
                }
                Text(ccSwitchResolvedPathHint)
                    .font(.caption2)
                    .foregroundStyle(FileManager.default.fileExists(atPath: CCSwitchLocator.databasePath()) ? Color.secondary : Color.orange)
            }
        }
    }

    /// 当前生效的 cc-switch.db 解析结果（实时反馈手动路径是否有效）。
    private var ccSwitchResolvedPathHint: String {
        let path = CCSwitchLocator.databasePath()
        let exists = FileManager.default.fileExists(atPath: path)
        let abbreviated = (path as NSString).abbreviatingWithTildeInPath
        return exists
            ? L("Database in use: \(abbreviated)", "当前使用的数据库：\(abbreviated)")
            : L("Database not found: \(abbreviated)", "未找到数据库：\(abbreviated)")
    }

    private func applyCCSwitchDir() {
        let trimmed = ccSwitchDirInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.ccSwitchConfigDirOverride)
        } else {
            UserDefaults.standard.set(trimmed, forKey: DefaultsKey.ccSwitchConfigDirOverride)
        }
    }

    private func chooseCCSwitchDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = L("Choose", "选择")
        if panel.runModal() == .OK, let url = panel.url {
            ccSwitchDirInput = (url.path as NSString).abbreviatingWithTildeInPath
            applyCCSwitchDir()
        }
    }

    // MARK: - Menu Bar

    var menuBarSection: some View {
        settingsCard(
            title: L("Menu Bar", "菜单栏"),
            subtitle: L("Configure what appears next to the menu bar icon.", "配置菜单栏图标旁显示的内容。")
        ) {
            menuBarQuotaAccountsPicker

            Divider()

            menuBarCostSourcesPicker

            if totalPinnedCount > StatusBarItemView.recommendedMaxAccounts {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    Text(L(
                        "You have \(totalPinnedCount) items pinned. More than \(StatusBarItemView.recommendedMaxAccounts) may cause the menu bar to be too wide.",
                        "已固定 \(totalPinnedCount) 项。超过 \(StatusBarItemView.recommendedMaxAccounts) 个可能导致菜单栏过长。"
                    ))
                    .font(.caption2)
                }
                .foregroundStyle(.orange)
            }
        }
        .onAppear { pruneStaleMenuBarPins() }
    }

    // MARK: - Card Appearance

    var cardAppearanceSection: some View {
        settingsCard(
            title: L("Card Appearance", "卡片外观"),
            subtitle: L("Adjust how quota cards present information.", "调整额度卡片的呈现方式。")
        ) {
            settingsBlock(title: L("Quota card style", "额度卡片样式")) {
                CapsuleSegmentedPicker(
                    options: CardQuotaIndicatorStyle.allCases.map { CapsuleSegmentOption($0, title: quotaStyleTitle($0)) },
                    selection: $settings.quotaIndicatorStyle
                )
            }

            Divider()

            settingsBlock(title: L("Progress meaning", "进度语义")) {
                CapsuleSegmentedPicker(
                    options: CardQuotaIndicatorMetric.allCases.map { CapsuleSegmentOption($0, title: quotaMetricTitle($0)) },
                    selection: $settings.quotaIndicatorMetric
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(L("Preview", "预览"))
                    .font(.subheadline.weight(.semibold))

                quotaIndicatorPreview

                Text(L("Applies instantly to all provider cards.", "会立即应用到所有服务卡片。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Proxy

    var proxySection: some View {
        settingsCard(
            title: L("Proxy", "代理"),
            subtitle: L("Claude Code / Codex proxy behavior and logging.", "Claude Code / Codex 代理行为和日志管理。")
        ) {
            settingsToggleRow(
                title: L("Auto-restore proxies on launch", "启动时自动恢复代理"),
                subtitle: L(
                    "If enabled, AIUsage restores the last activated Claude Code / Codex node and all proxy-only nodes when the app launches.",
                    "开启后，启动 AIUsage 时会自动恢复上次接入的 Claude Code / Codex 节点，以及所有仅代理运行的节点。"
                ),
                isOn: $settings.proxyAutoRestoreOnLaunch
            )

            Divider()

            settingsToggleRow(
                title: L("Auto-sync models & prices", "自动同步模型与价格"),
                subtitle: L(
                    "Every 6 hours, add newly listed upstream models to API providers and Claude Code / Codex / OpenCode nodes, and fill prices from models.dev. Manual prices and models you removed are never touched.",
                    "每 6 小时检查一次：把上游新上架的模型加入 API 提供商与 Claude Code / Codex / OpenCode 节点，并用 models.dev 补齐价格。手动价格和你删掉的模型不会被改动。"
                ),
                isOn: $settings.modelAutoSyncEnabled
            )

            settingsBlock(
                title: L("Sync status", "同步状态"),
                subtitle: L(
                    "Single nodes can also be synced from their right-click menu.",
                    "也可以在节点卡片的右键菜单里单独同步。"
                )
            ) {
                ModelAutoSyncStatusControl()
            }

            Divider()

            settingsBlock(
                title: L("Proxy Log Retention", "代理日志保留"),
                subtitle: L("Automatically delete proxy request logs older than the specified number of days.", "自动删除超过指定天数的代理请求日志。")
            ) {
                Picker("", selection: $proxyLogRetentionDays) {
                    Text(L("7 days", "7 天")).tag(7)
                    Text(L("14 days", "14 天")).tag(14)
                    Text(L("30 days", "30 天")).tag(30)
                    Text(L("90 days", "90 天")).tag(90)
                    Text(L("180 days", "180 天")).tag(180)
                    Text(L("365 days", "365 天")).tag(365)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
            }
        }
    }

    // MARK: - Notifications

    var notificationsSection: some View {
        settingsCard(
            title: L("Notifications", "通知"),
            subtitle: L("Decide when AIUsage should proactively nudge you.", "设置 AIUsage 在什么情况下主动提醒你。")
        ) {
            settingsToggleRow(
                title: L("Enable Notifications", "启用通知"),
                subtitle: L("Show desktop alerts for low quota and other status changes.", "为低额度和状态变化显示桌面提醒。"),
                isOn: $showNotifications
            )

            Divider()

            settingsBlock(
                title: L("Low Quota Alert", "低额度提醒"),
                subtitle: L("Trigger when remaining quota drops below the selected threshold.", "当剩余额度低于阈值时触发提醒。")
            ) {
                HStack(spacing: 14) {
                    Slider(value: $lowQuotaThreshold, in: 5...50, step: 5)
                    Text("\(Int(lowQuotaThreshold))%")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .trailing)
                }
            }
            .opacity(showNotifications ? 1 : 0.45)
            .disabled(!showNotifications)

            Divider()

            settingsBlock(
                title: L("Claude daily cost alert", "Claude 每日消费提醒"),
                subtitle: L("Get notified when daily spending exceeds threshold (0 = off)", "当每日消费超过阈值时通知（0 = 关闭）")
            ) {
                HStack(spacing: 8) {
                    Text("$")
                        .foregroundStyle(.secondary)
                    TextField("0.00", value: $settings.claudeDailyThreshold, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onChange(of: settings.claudeDailyThreshold) { _, _ in
                            settings.saveSettings()
                        }
                    Text(L("USD", "美元"))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .opacity(showNotifications ? 1 : 0.45)
            .disabled(!showNotifications)
        }
    }

    // MARK: - About

    var aboutSection: some View {
        settingsCard(
            title: L("About", "关于"),
            subtitle: L("Version information and update checks.", "版本信息与更新检查。")
        ) {
            settingsValueRow(title: L("Version", "版本"), value: appVersion)

            Divider()

            settingsToggleRow(
                title: L("Show sponsor recommendation", "显示赞助推荐"),
                subtitle: L(
                    "A small partner card above the version number in the sidebar. Signing up through it supports AIUsage at no extra cost to you.",
                    "侧边栏版本号上方的合作服务商小卡片。通过它注册可以支持 AIUsage 持续开发，你的价格不受影响。"
                ),
                isOn: $settings.showSponsorSpot
            )

            Divider()

            settingsToggleRow(
                title: L("Automatic Updates", "自动检查更新"),
                subtitle: L("Periodically check for new versions in the background.", "后台定期检查是否有新版本。"),
                isOn: Binding(
                    get: { sparkle.automaticallyChecksForUpdates },
                    set: { sparkle.setAutoCheckEnabled($0) }
                )
            )

            Divider()

            HStack(spacing: 10) {
                if let repositoryURL {
                    Link(destination: repositoryURL) {
                        Label("GitHub", systemImage: "link")
                    }
                }

                Button {
                    sparkle.checkForUpdates()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle")
                        Text(L("Check for Updates", "检查更新"))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!sparkle.canCheckForUpdates)
            }
        }
    }

}


// MARK: - Model Auto Sync Status

/// 设置页里的同步状态与「立即同步全部」。单独成 View，只有它订阅协调器，避免整页跟着刷新。
private struct ModelAutoSyncStatusControl: View {
    @ObservedObject private var coordinator = ModelAutoSyncCoordinator.shared

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await coordinator.syncAll(interactive: true) }
            } label: {
                HStack(spacing: 5) {
                    if coordinator.isSyncingAll {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(L("Sync All Now", "立即全部同步"))
                }
            }
            .disabled(coordinator.isSyncingAll)

            // 结果横幅在设置页里改成行内文字：小控件上叠浮层会遮住相邻设置项。
            Text(coordinator.flash?.message ?? lastRunText)
                .font(.caption)
                .foregroundStyle(coordinator.flash?.kind == .error ? Color.red : Color.secondary)
                .lineLimit(2)
                .animation(.easeInOut(duration: 0.2), value: coordinator.flash)

            Spacer(minLength: 0)
        }
    }

    private var lastRunText: String {
        guard let lastRunAt = coordinator.lastRunAt else {
            return L("Not synced yet", "尚未同步")
        }
        let relative = lastRunAt.formatted(.relative(presentation: .named))
        return L("Last synced \(relative)", "上次同步：\(relative)")
    }
}
