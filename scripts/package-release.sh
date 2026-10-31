#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-AIUsage}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/AIUsage.xcodeproj}"
SCHEME="${SCHEME:-AIUsage}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
INFO_PLIST_PATH="${INFO_PLIST_PATH:-$ROOT_DIR/AIUsage/Info.plist}"
VERSION="${1:-${VERSION:-}}"
REQUIRE_SPARKLE_SIGNING="${REQUIRE_SPARKLE_SIGNING:-0}"
# When set (release/tag builds), a missing stable signing identity is a hard
# error instead of silently falling back to ad-hoc. Ad-hoc signatures change
# fingerprint every build, which voids the user's Keychain "Always Allow" grant
# and re-prompts them on every update (issue #35). Local dev builds leave this
# unset and may still ad-hoc sign.
REQUIRE_STABLE_SIGNING="${REQUIRE_STABLE_SIGNING:-0}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-release.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}

trap cleanup EXIT

if [[ -z "${VERSION}" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_PATH")"
fi

mkdir -p "$OUTPUT_DIR"

strip_bundle_detritus() {
  local target="$1"
  local pass
  local attrs_pattern='com\.apple\.(FinderInfo|ResourceFork|fileprovider\.fpfs#P)'

  for pass in 1 2 3; do
    for attr in com.apple.FinderInfo com.apple.ResourceFork com.apple.fileprovider.fpfs#P; do
      find "$target" -exec xattr -d "$attr" {} + 2>/dev/null || true
      find -H "$target" -type l -exec xattr -ds "$attr" {} + 2>/dev/null || true
    done

    if [[ ! "$(xattr -lr "$target" 2>/dev/null)" =~ $attrs_pattern ]]; then
      return 0
    fi
  done

  echo "Failed to strip all detritus from $target" >&2
  xattr -lr "$target" >&2 || true
  return 1
}

# Fail fast before the (slow) build when a release/tag build lacks the stable
# signing identity, so CI surfaces the misconfiguration immediately instead of
# after a full xcodebuild + staging pass.
if [[ "$REQUIRE_STABLE_SIGNING" == "1" && -z "${MACOS_SIGNING_IDENTITY:-}" ]]; then
  echo "ERROR: REQUIRE_STABLE_SIGNING=1 but no MACOS_SIGNING_IDENTITY is set." >&2
  echo "Release/tag builds must use the stable self-signed certificate so the" >&2
  echo "Keychain 'Always Allow' grant survives updates (issue #35). Provide the" >&2
  echo "MACOS_CERT_P12_BASE64 / MACOS_CERT_PASSWORD secrets, or run a local dev" >&2
  echo "build without REQUIRE_STABLE_SIGNING to allow ad-hoc signing." >&2
  exit 1
fi

echo "Building ${APP_NAME} ${VERSION}..."

# "generic/platform=macOS" builds all standard architectures (arm64 + x86_64)
# for a Universal binary. A concrete "platform=macOS" destination would only
# build the host architecture, silently shipping an arm64-only app.
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  build

SOURCE_APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
ZIP_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}-macOS.zip"
DMG_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}-macOS.dmg"
DMG_STAGING_DIR="$WORK_DIR/dmg-root"
APP_STAGING_ROOT="$WORK_DIR/app-staging"
APP_PATH="$APP_STAGING_ROOT/$APP_NAME.app"
HELPER_PATH="$APP_PATH/Contents/Helpers/QuotaServer"
LEGACY_HELPER_DIR="$APP_PATH/Contents/Resources/Helpers"
LEGACY_HELPER_PATH="$LEGACY_HELPER_DIR/QuotaServer"

if [[ ! -d "$SOURCE_APP_PATH" ]]; then
  echo "Expected app bundle not found at $SOURCE_APP_PATH" >&2
  exit 1
fi

rm -rf "$APP_STAGING_ROOT"
mkdir -p "$APP_STAGING_ROOT"

echo "Creating sanitized app bundle staging copy..."
ditto --norsrc --noextattr --noqtn --noacl "$SOURCE_APP_PATH" "$APP_PATH"
strip_bundle_detritus "$APP_PATH"

# Defensive migration cleanup for incremental DerivedData produced before the
# helper moved into the standard nested-code directory.
if [[ -e "$LEGACY_HELPER_PATH" || -L "$LEGACY_HELPER_PATH" ]]; then
  echo "Removing stale legacy helper copy from Contents/Resources/Helpers..."
  rm -f "$LEGACY_HELPER_PATH"
  rmdir "$LEGACY_HELPER_DIR" 2>/dev/null || true
fi

echo "Injecting custom Sparkle localization strings..."
SPARKLE_RES=$(find "$APP_PATH/Contents/Frameworks" -path "*/Sparkle.framework/*/Resources" -type d 2>/dev/null | head -1)
STRINGS_SRC="$ROOT_DIR/AIUsage/Resources"
if [[ -n "$SPARKLE_RES" && -d "$SPARKLE_RES" ]]; then
  for LOCALE in Base.lproj zh_CN.lproj; do
    SRC_FILE="$STRINGS_SRC/$LOCALE/Sparkle.strings"
    if [[ -f "$SRC_FILE" ]]; then
      mkdir -p "$SPARKLE_RES/$LOCALE"
      cp -f "$SRC_FILE" "$SPARKLE_RES/$LOCALE/Sparkle.strings"
      echo "  Injected $LOCALE/Sparkle.strings"
    fi
  done
else
  echo "  WARNING: Sparkle.framework Resources not found, skipping string injection"
fi

strip_bundle_detritus "$APP_PATH"

# Verify the shipped binaries are Universal (arm64 + x86_64). Guards against
# build-setting regressions that would silently drop Intel support.
verify_universal() {
  local binary="$1"
  local archs
  archs="$(lipo -archs "$binary" 2>/dev/null || true)"
  if [[ "$archs" != *"arm64"* || "$archs" != *"x86_64"* ]]; then
    echo "ERROR: $binary is not a Universal binary (archs: ${archs:-unreadable})." >&2
    echo "Expected both arm64 and x86_64 slices." >&2
    exit 1
  fi
  echo "  $(basename "$binary"): $archs"
}

echo "Verifying Universal binary slices..."
verify_universal "$APP_PATH/Contents/MacOS/$APP_NAME"
verify_universal "$HELPER_PATH"
if [[ -e "$LEGACY_HELPER_PATH" || -L "$LEGACY_HELPER_PATH" ]]; then
  echo "ERROR: legacy helper copy still exists at $LEGACY_HELPER_PATH" >&2
  exit 1
fi

# Signing identity:
#   - When MACOS_SIGNING_IDENTITY is set (release builds in CI), sign with a
#     STABLE certificate. A stable signature keeps the app's designated
#     requirement constant across versions, so a user's Keychain "Always Allow"
#     grant survives updates instead of re-prompting on every release (issue #35).
#   - Otherwise fall back to ad-hoc (local dev builds, or CI without the secret).
SIGN_IDENTITY="${MACOS_SIGNING_IDENTITY:-}"
SIGN_KEYCHAIN="${MACOS_SIGNING_KEYCHAIN:-}"
CODESIGN_ARGS=(--force)
if [[ -n "$SIGN_KEYCHAIN" ]]; then
  CODESIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  HOST_SIGN_IDENTITY="$SIGN_IDENTITY"
  echo "Using stable host signing identity (${SIGN_IDENTITY})."
else
  HOST_SIGN_IDENTITY="-"
  echo "No MACOS_SIGNING_IDENTITY set; using ad-hoc identity for helper and app."
fi

sign_with_host_identity() {
  local target="$1"
  codesign "${CODESIGN_ARGS[@]}" --sign "$HOST_SIGN_IDENTITY" "$target"
}

certificate_leaf_from_dr() {
  # Extract H"..." from `codesign -d -r-` output. Empty if ad-hoc / cdhash-only.
  codesign -d -r- "$1" 2>&1 | sed -n 's/.*certificate leaf = H"\([0-9a-fA-F]*\)".*/\1/p' | head -1
}

SPARKLE_FRAMEWORK="$(find "$APP_PATH/Contents/Frameworks" -maxdepth 2 -type d -name 'Sparkle.framework' -print -quit)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  echo "ERROR: Sparkle.framework not found under Contents/Frameworks." >&2
  exit 1
fi
SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/Current"
if [[ ! -d "$SPARKLE_VERSION_DIR" ]]; then
  SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/B"
fi

# P0 (auto-update): With a self-signed host cert and no Apple Team ID, Sparkle's
# Autoupdate / Installer / Updater / Downloader MUST share the host certificate
# leaf. Leaving them as SPM ad-hoc (or signing only the outer Sparkle.framework)
# breaks XPC from already-installed builds and surfaces as:
#   "An error occurred while running the updater. Please try again later."
# Do NOT use `codesign --deep` on the outer App (blunt and easy to misuse);
# sign these Sparkle tools explicitly, then seal the framework, then helper/App.
# Outer App DR must still pin the stable certificate leaf so Keychain
# "Always Allow" survives updates (issue #35).
echo "Signing Sparkle updater tools with the host identity (P0 auto-update)..."
for SPARKLE_TOOL in \
  "$SPARKLE_VERSION_DIR/Autoupdate" \
  "$SPARKLE_VERSION_DIR/Updater.app" \
  "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" \
  "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
do
  if [[ ! -e "$SPARKLE_TOOL" ]]; then
    echo "ERROR: required Sparkle tool missing: $SPARKLE_TOOL" >&2
    exit 1
  fi
  sign_with_host_identity "$SPARKLE_TOOL"
done

echo "Re-signing Sparkle.framework after nested tools + localization..."
sign_with_host_identity "$SPARKLE_FRAMEWORK"
codesign --verify --deep --strict --verbose=2 "$SPARKLE_FRAMEWORK"

echo "Signing QuotaServer helper with the host identity..."
sign_with_host_identity "$HELPER_PATH"
codesign --verify --strict --verbose=2 "$HELPER_PATH"

echo "Signing ${APP_NAME}.app after all nested code..."
sign_with_host_identity "$APP_PATH"

echo "Verifying nested helper and outer app signatures..."
codesign --verify --strict --verbose=2 "$HELPER_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Guarantee: when a stable identity was requested, the output MUST be
# certificate-signed (designated requirement pins the cert). If it silently fell
# back to ad-hoc, the Keychain "Always Allow" fix would be lost — so fail loudly
# instead of shipping a build that re-prompts users on every update (issue #35).
#
# Also require Sparkle Autoupdate to pin the SAME certificate leaf as the App.
# Ad-hoc Autoupdate under a self-signed host is a P0 auto-update regression.
if [[ -n "$SIGN_IDENTITY" ]]; then
  for SIGNED_TARGET in "$HELPER_PATH" "$APP_PATH" "$SPARKLE_VERSION_DIR/Autoupdate"; do
    DESIGNATED_REQ="$(codesign -d -r- "$SIGNED_TARGET" 2>&1 || true)"
    if ! echo "$DESIGNATED_REQ" | grep -qi 'certificate leaf'; then
      echo "ERROR: stable signing was requested but $SIGNED_TARGET is not certificate-signed." >&2
      echo "Designated requirement:" >&2
      echo "$DESIGNATED_REQ" >&2
      exit 1
    fi
  done
  APP_LEAF="$(certificate_leaf_from_dr "$APP_PATH")"
  AUTOUPDATE_LEAF="$(certificate_leaf_from_dr "$SPARKLE_VERSION_DIR/Autoupdate")"
  if [[ -z "$APP_LEAF" || -z "$AUTOUPDATE_LEAF" || "$APP_LEAF" != "$AUTOUPDATE_LEAF" ]]; then
    echo "ERROR: Sparkle Autoupdate certificate leaf must match the outer App leaf." >&2
    echo "  App leaf:        ${APP_LEAF:-<missing>}" >&2
    echo "  Autoupdate leaf: ${AUTOUPDATE_LEAF:-<missing>}" >&2
    echo "Leaving Autoupdate ad-hoc (or on a different cert) breaks Sparkle auto-update" >&2
    echo "for self-signed builds without an Apple Team ID (P0)." >&2
    exit 1
  fi
  echo "Verified stable certificate-pinned signatures for helper, app, and Sparkle Autoupdate (leaf=$APP_LEAF)."
fi

rm -f "$ZIP_PATH" "$DMG_PATH"
mkdir -p "$DMG_STAGING_DIR"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

cp -R "$APP_PATH" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

DMG_RW_PATH="$WORK_DIR/${APP_NAME}-rw.dmg"

# Let hdiutil account for filesystem overhead instead of a fixed du + 10 MiB.
# Explicit HFS+ keeps image sizing independent of the runner OS default.

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDRW \
  -fs HFS+ \
  "$DMG_RW_PATH" >/dev/null

MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW_PATH" \
  | grep "/Volumes/$APP_NAME" | awk -F'\t' '{print $NF}')

echo "Configuring DMG window layout..."
osascript <<APPLESCRIPT || true
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 640, 400}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set position of item "${APP_NAME}.app" of container window to {140, 150}
    set position of item "Applications" of container window to {400, 150}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force
hdiutil convert "$DMG_RW_PATH" -format UDZO -o "$DMG_PATH" >/dev/null

echo "Created release artifacts:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"

# --- Sparkle appcast generation ---
SPARKLE_SIGN="${SPARKLE_SIGN_TOOL:-}"
SPARKLE_KEY="${SPARKLE_EDDSA_PRIVATE_KEY:-}"

if [[ -n "$SPARKLE_SIGN" && -n "$SPARKLE_KEY" ]]; then
  echo "Signing .zip for Sparkle..."
  TMPKEY=$(mktemp)
  printf '%s' "$SPARKLE_KEY" > "$TMPKEY"
  SIGN_OUTPUT=$("$SPARKLE_SIGN" "$ZIP_PATH" --ed-key-file "$TMPKEY" 2>&1)
  rm -f "$TMPKEY"
  EDDSA_SIG=$(echo "$SIGN_OUTPUT" | grep -oE 'sparkle:edSignature="[^"]+"' | cut -d'"' -f2)
  if [[ -z "$EDDSA_SIG" ]]; then
    echo "Failed to extract Sparkle EdDSA signature from sign_update output" >&2
    echo "$SIGN_OUTPUT" >&2
    exit 1
  fi
  ZIP_LENGTH=$(stat -f%z "$ZIP_PATH" 2>/dev/null || stat --printf="%s" "$ZIP_PATH" 2>/dev/null)

  DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/sylearn/AIUsage/releases/download/v${VERSION}}"
  APPCAST_PATH="$OUTPUT_DIR/appcast.xml"

  PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')

  cat > "$APPCAST_PATH" <<APPCAST_EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <title>AIUsage</title>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure
        url="${DOWNLOAD_URL_PREFIX}/${APP_NAME}-${VERSION}-macOS.zip"
        type="application/octet-stream"
        sparkle:edSignature="${EDDSA_SIG}"
        length="${ZIP_LENGTH}"
      />
    </item>
  </channel>
</rss>
APPCAST_EOF

  echo "  $APPCAST_PATH"
else
  if [[ "$REQUIRE_SPARKLE_SIGNING" == "1" ]]; then
    echo "Sparkle signing is required for release builds, but SPARKLE_SIGN_TOOL or SPARKLE_EDDSA_PRIVATE_KEY is missing" >&2
    exit 1
  fi
  echo "Skipping Sparkle signing (SPARKLE_SIGN_TOOL or SPARKLE_EDDSA_PRIVATE_KEY not set)"
fi

# Remove the freshly built app bundle from DerivedData. The shippable artifacts
# already live in dist/, but macOS LaunchServices auto-registers any .app it
# finds — leaving build products around makes Launchpad/Spotlight show several
# duplicate "AIUsage" entries next to the real /Applications copy. Set
# KEEP_BUILD_APP=1 to keep it (e.g. to debug the raw build product).
if [[ "${KEEP_BUILD_APP:-0}" != "1" && -d "$SOURCE_APP_PATH" ]]; then
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -u "$SOURCE_APP_PATH" 2>/dev/null || true
  rm -rf "$SOURCE_APP_PATH"
  echo "Removed build product app bundle (avoids duplicate LaunchServices registration): $SOURCE_APP_PATH"
fi
