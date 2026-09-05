#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REGRESSION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-account-identity.XXXXXX")"
trap 'rm -rf "$REGRESSION_DIR"' EXIT

swift build --package-path "$PROJECT_DIR/QuotaBackend" --target QuotaBackend >/dev/null
BACKEND_BIN="$(swift build --package-path "$PROJECT_DIR/QuotaBackend" --show-bin-path)"
# 使用 SwiftPM 当前编译的对象清单，避免捡到历史重复 .o 文件。
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' \
  "$BACKEND_BIN/description.json" > "$REGRESSION_DIR/backend-objects.txt"

swiftc -parse-as-library -swift-version 5 \
  -I "$BACKEND_BIN/Modules" -Xlinker -filelist -Xlinker "$REGRESSION_DIR/backend-objects.txt" \
  "$PROJECT_DIR/AIUsage/Models/ProviderModels.swift" \
  "$PROJECT_DIR/AIUsage/Models/AccountStore.swift" \
  "$PROJECT_DIR/AIUsage/Models/AccountStore+Persistence.swift" \
  "$PROJECT_DIR/AIUsage/Models/AccountStore+Matching.swift" \
  "$PROJECT_DIR/AIUsage/Services/ProviderAuth/ProviderAuthTypes.swift" \
  "$PROJECT_DIR/AIUsage/Services/ProviderAuth/ProviderAuthParsing.swift" \
  "$PROJECT_DIR/scripts/AccountIdentityRegressionSupport.swift" \
  "$PROJECT_DIR/scripts/AccountIdentityRegression.swift" \
  -o "$REGRESSION_DIR/account-identity-regression"
"$REGRESSION_DIR/account-identity-regression"
