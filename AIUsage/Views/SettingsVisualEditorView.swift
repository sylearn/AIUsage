import SwiftUI

// MARK: - Settings Visual Editor View
// Provides a structured UI for editing common settings.json fields
// (model, env, permissions, hooks, general options) without touching raw JSON.

struct SettingsVisualEditorView: View {
    @Binding var settings: [String: Any]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                generalSection
                envSection
                permissionsSection
                hooksSection
                advancedSection
            }
            .padding(20)
        }
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsCard(title: L("General", "通用"), icon: "gearshape") {
            SettingsStringRow(
                label: "model",
                hint: L("Override default model (e.g., claude-sonnet-4-6, opus)", "覆盖默认模型（如 claude-sonnet-4-6、opus）"),
                settings: $settings, key: "model"
            )
            SettingsStringRow(
                label: "language",
                hint: L("Claude's preferred response language", "Claude 的首选回复语言"),
                settings: $settings, key: "language"
            )
            SettingsBoolRow(
                label: "alwaysThinkingEnabled",
                hint: L("Enable extended thinking by default", "默认启用深度思考"),
                settings: $settings, key: "alwaysThinkingEnabled"
            )
            SettingsStringRow(
                label: "agent",
                hint: L("Default agent name from .claude/agents/", "默认使用 .claude/agents/ 下的代理名"),
                settings: $settings, key: "agent"
            )
            SettingsIntRow(
                label: "cleanupPeriodDays",
                hint: L("Days before inactive sessions are deleted (min 1)", "不活跃会话多少天后删除（最少 1）"),
                settings: $settings, key: "cleanupPeriodDays"
            )
        }
    }

    // MARK: - Environment Variables

    private var envSection: some View {
        SettingsCard(title: L("Environment Variables", "环境变量"), icon: "terminal") {
            KeyValueEditor(
                settings: $settings,
                key: "env",
                addLabel: L("Add Variable", "添加变量"),
                keyPlaceholder: L("Variable name", "变量名"),
                valuePlaceholder: L("Value", "值")
            )
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        SettingsCard(title: L("Permissions", "权限"), icon: "lock.shield") {
            PermissionListEditor(
                settings: $settings,
                permKey: "allow",
                label: L("Allow Rules", "允许规则"),
                hint: L("Auto-allow these tools (e.g., Bash(npm run *), Edit(*))", "自动允许这些工具（如 Bash(npm run *), Edit(*)）")
            )

            Divider().padding(.vertical, 4)

            PermissionListEditor(
                settings: $settings,
                permKey: "deny",
                label: L("Deny Rules", "拒绝规则"),
                hint: L("Block these tools (e.g., Read(./.env), Bash(curl *))", "阻止这些工具（如 Read(./.env), Bash(curl *)）")
            )

            Divider().padding(.vertical, 4)

            PermissionListEditor(
                settings: $settings,
                permKey: "additionalDirectories",
                label: L("Additional Directories", "附加目录"),
                hint: L("Extra directories Claude can access", "Claude 可以访问的额外目录")
            )
        }
    }

    // MARK: - Hooks

    private var hooksSection: some View {
        SettingsCard(title: L("Hooks", "钩子"), icon: "arrow.triangle.branch") {
            Text(L("Configure lifecycle hooks (PreToolUse, PostToolUse, etc.) via the JSON tab for full control.",
                   "生命周期钩子（PreToolUse、PostToolUse 等）请通过 JSON 标签页完整配置。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            SettingsBoolRow(
                label: "disableAllHooks",
                hint: L("Disable all hooks", "禁用所有钩子"),
                settings: $settings, key: "disableAllHooks"
            )
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        SettingsCard(title: L("Advanced", "高级"), icon: "wrench.and.screwdriver") {
            SettingsStringRow(
                label: "apiKeyHelper",
                hint: L("Script path for dynamic API key generation", "动态 API Key 生成脚本路径"),
                settings: $settings, key: "apiKeyHelper"
            )
            SettingsBoolRow(
                label: "enableAllProjectMcpServers",
                hint: L("Auto-approve all MCP servers from project .mcp.json", "自动批准项目 .mcp.json 中的所有 MCP 服务器"),
                settings: $settings, key: "enableAllProjectMcpServers"
            )
            SettingsStringRow(
                label: "autoUpdatesChannel",
                hint: L("Release channel: stable or latest", "更新通道：stable 或 latest"),
                settings: $settings, key: "autoUpdatesChannel"
            )
        }
    }
}

// MARK: - Reusable Components

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(title).font(.headline.weight(.bold))
            }
            content
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppSurface.card(colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppStroke.card(colorScheme), lineWidth: 1))
    }
}

private struct SettingsStringRow: View {
    let label: String
    let hint: String
    @Binding var settings: [String: Any]
    let key: String

    private var binding: Binding<String> {
        Binding(
            get: { settings[key] as? String ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    settings.removeValue(forKey: key)
                } else {
                    settings[key] = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(.caption, design: .monospaced).weight(.medium)).foregroundStyle(.secondary)
            TextField(hint, text: binding).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
        }
    }
}

private struct SettingsBoolRow: View {
    let label: String
    let hint: String
    @Binding var settings: [String: Any]
    let key: String

    private var binding: Binding<Bool> {
        Binding(
            get: { settings[key] as? Bool ?? false },
            set: { newValue in
                if !newValue {
                    settings.removeValue(forKey: key)
                } else {
                    settings[key] = newValue
                }
            }
        )
    }

    var body: some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(.caption, design: .monospaced).weight(.medium))
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}

private struct SettingsIntRow: View {
    let label: String
    let hint: String
    @Binding var settings: [String: Any]
    let key: String

    private var binding: Binding<Int> {
        Binding(
            get: { settings[key] as? Int ?? 0 },
            set: { newValue in
                if newValue == 0 {
                    settings.removeValue(forKey: key)
                } else {
                    settings[key] = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(.caption, design: .monospaced).weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("", value: binding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 120)
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Key-Value Editor (for env)

private struct KeyValueEditor: View {
    @Binding var settings: [String: Any]
    let key: String
    let addLabel: String
    let keyPlaceholder: String
    let valuePlaceholder: String

    @State private var newKey: String = ""
    @State private var newValue: String = ""

    private var envDict: [String: String] {
        (settings[key] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(envDict.keys.sorted(), id: \.self) { k in
                HStack(spacing: 8) {
                    Text(k)
                        .font(.system(size: 12, design: .monospaced).weight(.medium))
                        .frame(minWidth: 120, alignment: .trailing)
                        .foregroundStyle(.secondary)

                    TextField(valuePlaceholder, text: Binding(
                        get: { envDict[k] ?? "" },
                        set: { newVal in
                            var dict = settings[key] as? [String: Any] ?? [:]
                            dict[k] = newVal
                            settings[key] = dict
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                    Button(role: .destructive) {
                        var dict = settings[key] as? [String: Any] ?? [:]
                        dict.removeValue(forKey: k)
                        settings[key] = dict.isEmpty ? nil : dict
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                TextField(keyPlaceholder, text: $newKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 200)

                TextField(valuePlaceholder, text: $newValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                Button {
                    guard !newKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    var dict = settings[key] as? [String: Any] ?? [:]
                    dict[newKey.trimmingCharacters(in: .whitespaces)] = newValue
                    settings[key] = dict
                    newKey = ""
                    newValue = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Permission List Editor

private struct PermissionListEditor: View {
    @Binding var settings: [String: Any]
    let permKey: String
    let label: String
    let hint: String

    @State private var newRule: String = ""

    private var rules: [String] {
        let perms = settings["permissions"] as? [String: Any] ?? [:]
        return perms[permKey] as? [String] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline.weight(.semibold))
            Text(hint).font(.caption2).foregroundStyle(.tertiary)

            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                HStack(spacing: 8) {
                    Text(rule)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))

                    Button(role: .destructive) {
                        var perms = settings["permissions"] as? [String: Any] ?? [:]
                        var list = perms[permKey] as? [String] ?? []
                        list.remove(at: index)
                        perms[permKey] = list.isEmpty ? nil : list
                        settings["permissions"] = perms.isEmpty ? nil : perms
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                TextField(L("e.g., Bash(npm run *)", "例如 Bash(npm run *)"), text: $newRule)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { addRule() }

                Button {
                    addRule()
                } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addRule() {
        let trimmed = newRule.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var perms = settings["permissions"] as? [String: Any] ?? [:]
        var list = perms[permKey] as? [String] ?? []
        list.append(trimmed)
        perms[permKey] = list
        settings["permissions"] = perms
        newRule = ""
    }
}
