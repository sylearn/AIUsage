#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REGRESSION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-claude-desktop.XXXXXX")"
trap 'rm -rf "$REGRESSION_DIR"' EXIT
cd "$PROJECT_DIR"

# 配置样本：只读 scripts/fixtures/claude-desktop，不碰真实 Claude Desktop 配置。
swift scripts/ClaudeDesktopFixtureRegression.swift

# 与正式 ClaudeDesktopProfileStore.swift 一起编译，测试的就是发布版的事务实现。
swiftc -parse-as-library -swift-version 5 \
  scripts/ClaudeDesktopProfileTransactionRegression.swift \
  AIUsage/Services/ClaudeDesktopProfileStore.swift \
  -o "$REGRESSION_DIR/claude-desktop-profile-transaction"
"$REGRESSION_DIR/claude-desktop-profile-transaction"
