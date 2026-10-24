#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REGRESSION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-common-config.XXXXXX")"
trap 'rm -rf "$REGRESSION_DIR"' EXIT

swift build --build-system native --package-path "$PROJECT_DIR/QuotaBackend" --target QuotaBackend >/dev/null
BACKEND_BIN="$(swift build --build-system native --package-path "$PROJECT_DIR/QuotaBackend" --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' \
  "$BACKEND_BIN/description.json" > "$REGRESSION_DIR/backend-objects.txt"

# 编译真实保存、适配器、合并与文件写入代码；只替换代理进程/账号等边界。
ruby -E UTF-8:UTF-8 - "$PROJECT_DIR" "$REGRESSION_DIR" "${1:-}" <<'RUBY'
root, destination, mode = ARGV
def extract(source, pattern, terminator = /^    }\s*$/)
  lines = source.lines
  starts = lines.each_index.select { |index| lines[index].match?(pattern) }
  abort "Expected one source match: #{pattern}" unless starts.length == 1
  first = starts.first
  last = ((first + 1)...lines.length).find { |index| lines[index].match?(terminator) }
  abort "Missing source terminator: #{pattern}" unless last
  lines[first..last].join
end
read = ->(path) { File.read(File.join(root, path)) }
output = "import Foundation\nimport os.log\nimport QuotaBackend\n"
adapters = read.call('AIUsage/ViewModels/GlobalProxyTrackAdapters.swift')
if mode == '--baseline-adapters'
  adapters = IO.popen(['git', '-C', root, 'show', 'HEAD:AIUsage/ViewModels/GlobalProxyTrackAdapters.swift'], &:read)
end
%w[Codex Claude OpenCode].each do |track|
  source = extract(adapters, /^struct #{track}GlobalProxyAdapter:/, /^}\s*$/)
  method = extract(source, /^    func activateCLIConfig\(/)
  output += "\nextension #{track}GlobalProxyAdapter {\n#{method}}\n"
end
store = read.call('AIUsage/ViewModels/NodeProfileStore.swift')
output += "\nextension NodeProfileStore {\n"
%w[saveGlobalConfig saveCodexGlobalConfig reapplyCommonConfig].each do |method|
  output += extract(store, /^    (private )?func #{method}\(/)
end
output += "}\n"
store = read.call('AIUsage/ViewModels/OpenCodeNodeStore.swift')
output += "\nextension OpenCodeNodeStore {\n"
%w[saveGlobalConfig commonSettings].each do |method|
  output += extract(store, /^    func #{method}\(/)
end
output += "}\n"
codex = read.call('AIUsage/ViewModels/CodexConfigManager.swift')
output += "\nextension CodexConfigManager {\n"
%w[injectManagedConfig stripManagedBlocks normalizeLegacyProviderReferences mergeBaseFragments splitFragment topLevelKeyName normalizedTableHeader firstTableHeader tomlInlineStringValue isManagedHeaderKey isTopLevelKey tomlString writeConfig writeBackup applyRestrictivePermissions].each do |method|
  output += extract(codex, /^    (private )?func #{method}\(/)
end
output += "}\n"
opencode = read.call('AIUsage/ViewModels/OpenCodeConfigManager.swift')
output += "\nextension OpenCodeConfigManager {\n"
%w[activateGlobal mergedBase stripManagedEntries writeManagedRoot writeText writeObject applyRestrictivePermissions].each do |method|
  output += extract(opencode, /^    (private )?func #{method}\(/)
end
output += "}\n"
# 只替换实例路径与测试可见性；业务方法体保持原文。
output = output.gsub('ClaudeSettingsManager.shared', 'fixtureClaude').gsub('private func ', 'func ')
File.write(File.join(destination, 'ProductionMethods.swift'), output)
RUBY

swiftc -parse-as-library -swift-version 5 \
  -I "$BACKEND_BIN/Modules" -Xlinker -filelist -Xlinker "$REGRESSION_DIR/backend-objects.txt" \
  "$PROJECT_DIR/AIUsage/Models/GlobalConfig.swift" \
  "$PROJECT_DIR/AIUsage/Models/CodexGlobalConfig.swift" \
  "$PROJECT_DIR/AIUsage/ViewModels/ClaudeSettingsManager.swift" \
  "$PROJECT_DIR/scripts/CommonConfigRegression.swift" \
  "$REGRESSION_DIR/ProductionMethods.swift" \
  -o "$REGRESSION_DIR/common-config-regression"
if [[ "${1:-}" == '--baseline-adapters' ]]; then
  # 三条旧适配器应各自复现漏传，不能因第一个失败而漏测其它家族。
  for TRACK in codex claude opencode; do
    if "$REGRESSION_DIR/common-config-regression" "$TRACK"; then
      echo "Baseline unexpectedly passed: $TRACK" >&2
      exit 1
    fi
  done
  echo 'All three baseline adapters reproduced the missing-common-config failure.'
else
  "$REGRESSION_DIR/common-config-regression"
fi
