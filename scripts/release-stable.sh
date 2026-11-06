#!/usr/bin/env bash
# Stable macOS release: sign, notarize, then publish the DMG and Sparkle
# appcast as assets of the GitHub release. Run only by
# .github/workflows/release.yml on a semver tag push.
set -euo pipefail

ASSET_NAME="stable-macos-arm64-RemoteCode.dmg"
TAG="${GITHUB_REF_NAME:-}"
if [ -z "$TAG" ]; then
  echo "GITHUB_REF_NAME is required"
  exit 1
fi
export RELEASE_TAG="$TAG"

git fetch --force --tags origin
git checkout "$TAG"
git lfs pull

VERSION="${TAG#v}"
CODESIGN_P12_BASE64="${MACOS_DEVELOPER_ID_P12_BASE64:-${MACOS_CERTIFICATE:-}}"
CODESIGN_P12_PASSWORD="${MACOS_DEVELOPER_ID_P12_PASSWORD:-${MACOS_CERTIFICATE_PWD:-}}"
EXPECTED_CODESIGN_IDENTITY="${MACOS_DEVELOPER_IDENTITY:-}"
NOTARY_APPLE_ID="${APPLE_ID:-}"
NOTARY_TEAM_ID="${APPLE_TEAM_ID:-}"
NOTARY_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"

test "$(uname -m)" = "arm64"
command -v gh >/dev/null || brew install gh
command -v jq >/dev/null || brew install jq

scripts/release-preflight.sh

if [ -z "$CODESIGN_P12_BASE64" ] || [ -z "$CODESIGN_P12_PASSWORD" ]; then
  echo "Missing Developer ID certificate variables"
  exit 1
fi
if [ -z "$NOTARY_APPLE_ID" ] || [ -z "$NOTARY_TEAM_ID" ] || [ -z "$NOTARY_PASSWORD" ]; then
  echo "Missing notarization variables"
  exit 1
fi
if [ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ] || [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "Missing Sparkle signing variables"
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
KEYCHAIN="$TEMP_DIR/remotecode-signing.keychain-db"
CERTIFICATE="$TEMP_DIR/developer-id.p12"
ORIGINAL_USER_KEYCHAINS="$TEMP_DIR/original-user-keychains.txt"
REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY"
# Sparkle polls the newest published release, so the feed URL never changes.
APPCAST_URL="$REPO_URL/releases/latest/download/appcast.xml"
DMG_URL="$REPO_URL/releases/download/$TAG/$ASSET_NAME"

security list-keychains -d user \
  | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' \
  > "$ORIGINAL_USER_KEYCHAINS"
MOUNT=""
cleanup_release() {
  local exit_code="$1"
  trap - EXIT
  set +e
  if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    rmdir "$MOUNT" >/dev/null 2>&1 || true
  fi
  original_keychains=()
  while IFS= read -r original_keychain; do
    if [ -n "$original_keychain" ]; then
      original_keychains+=("$original_keychain")
    fi
  done < "$ORIGINAL_USER_KEYCHAINS"
  if [ "${#original_keychains[@]}" -gt 0 ]; then
    security list-keychains -d user -s "${original_keychains[@]}"
  fi
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$TEMP_DIR"
  exit "$exit_code"
}
trap 'cleanup_release "$?"' EXIT

printf '%s' "$CODESIGN_P12_BASE64" | base64 --decode > "$CERTIFICATE"
security create-keychain -p "$TEMP_DIR" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$TEMP_DIR" "$KEYCHAIN"
security import "$CERTIFICATE" -P "$CODESIGN_P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
signing_keychains=("$KEYCHAIN")
while IFS= read -r original_keychain; do
  if [ -n "$original_keychain" ]; then
    signing_keychains+=("$original_keychain")
  fi
done < "$ORIGINAL_USER_KEYCHAINS"
security list-keychains -d user -s "${signing_keychains[@]}"
security set-key-partition-list -S apple-tool:,apple: -s -k "$TEMP_DIR" "$KEYCHAIN"

if [ -n "$EXPECTED_CODESIGN_IDENTITY" ]; then
  IDENTITY="$EXPECTED_CODESIGN_IDENTITY"
  if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "\"$IDENTITY\"" >/dev/null; then
    echo "Expected Developer ID identity not found in imported certificate"
    exit 1
  fi
else
  IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -F '"' '/Developer ID Application/ { print $2; exit }')"
fi
if [ -z "$IDENTITY" ]; then
  echo "Developer ID Application identity not found in imported certificate"
  exit 1
fi

export RC2_CODESIGN_IDENTITY="$IDENTITY"
export RC2_VERSION="$VERSION"
export RC2_DMG_NAME="$ASSET_NAME"
export RC2_REQUIRE_SPARKLE_KEY="1"
export RC2_SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY"
export RC2_SPARKLE_FEED_URL="$APPCAST_URL"

scripts/package-dmg.sh
hdiutil verify "dist/$ASSET_NAME"

NOTARY_SUBMIT_JSON="$(mktemp)"
if ! xcrun notarytool submit "dist/$ASSET_NAME" \
  --apple-id "$NOTARY_APPLE_ID" \
  --team-id "$NOTARY_TEAM_ID" \
  --password "$NOTARY_PASSWORD" \
  --wait \
  --output-format json >"$NOTARY_SUBMIT_JSON"
then
  echo "notarytool submit failed; raw output:" >&2
  cat "$NOTARY_SUBMIT_JSON" >&2 || true
  NOTARY_ID="$(jq -r '.id // empty' "$NOTARY_SUBMIT_JSON" 2>/dev/null || true)"
  if [ -n "$NOTARY_ID" ]; then
    xcrun notarytool log "$NOTARY_ID" \
      --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" >&2 || true
  fi
  exit 1
fi
NOTARY_STATUS="$(jq -r '.status // empty' "$NOTARY_SUBMIT_JSON" 2>/dev/null || true)"
NOTARY_ID="$(jq -r '.id // empty' "$NOTARY_SUBMIT_JSON" 2>/dev/null || true)"
echo "notarytool status=${NOTARY_STATUS:-unknown} id=${NOTARY_ID:-unknown}"
if [ "$NOTARY_STATUS" != "Accepted" ]; then
  echo "notarization did not accept the DMG (status=${NOTARY_STATUS:-unknown})" >&2
  cat "$NOTARY_SUBMIT_JSON" >&2 || true
  if [ -n "$NOTARY_ID" ]; then
    xcrun notarytool log "$NOTARY_ID" \
      --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" >&2 || true
  fi
  exit 1
fi
xcrun stapler staple "dist/$ASSET_NAME"
spctl --assess --type open --context context:primary-signature --verbose=4 "dist/$ASSET_NAME"

MOUNT="$(mktemp -d)"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "dist/$ASSET_NAME"
codesign --verify --deep --strict --verbose=4 "$MOUNT/MacCode.app"
spctl --assess --type execute --verbose=4 "$MOUNT/MacCode.app"
bash scripts/orchestrate-launch-smoke.sh "$MOUNT/MacCode.app"
# The smoke app and its helpers can hold the read-only volume briefly after kill.
for attempt in 1 2 3 4 5; do
  hdiutil detach "$MOUNT" && break
  [ "$attempt" -lt 5 ] || hdiutil detach -force "$MOUNT"
  sleep 3
done
rmdir "$MOUNT"
MOUNT=""

SPARKLE_TOOLS=".build/artifacts/sparkle/Sparkle/bin"
SIGN_UPDATE="$SPARKLE_TOOLS/sign_update"
if [ ! -x "$SIGN_UPDATE" ]; then
  echo "Sparkle sign_update tool not found at $SIGN_UPDATE"
  exit 1
fi
KEY_FILE="$TEMP_DIR/sparkle_ed_private_key"
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "dist/$ASSET_NAME")"
mkdir -p dist/pages
cat > dist/pages/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>RemoteCode Updates</title>
    <link>$APPCAST_URL</link>
    <description>RemoteCode macOS updates</description>
    <item>
      <title>RemoteCode $VERSION</title>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <pubDate>$(date -Ru)</pubDate>
      <enclosure url="$DMG_URL" type="application/x-apple-diskimage" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF
grep -F "sparkle:edSignature" dist/pages/appcast.xml
grep -F "$ASSET_NAME" dist/pages/appcast.xml

RELEASE_NOTES="RemoteCode macOS $VERSION

- DMG: $DMG_URL
- Sparkle appcast: $APPCAST_URL"

# gh uploads assets to a draft and publishes it only after every upload
# succeeds, so the latest download and appcast switch together.
if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "GitHub release $TAG already exists; replacing its assets"
  gh release upload "$TAG" "dist/$ASSET_NAME" dist/pages/appcast.xml \
    --repo "$GITHUB_REPOSITORY" --clobber
else
  gh release create "$TAG" "dist/$ASSET_NAME" dist/pages/appcast.xml \
    --repo "$GITHUB_REPOSITORY" \
    --verify-tag \
    --latest \
    --title "RemoteCode $VERSION" \
    --notes "$RELEASE_NOTES"
fi

gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json assets \
  | jq -e --arg dmg "$ASSET_NAME" '[.assets[].name] | index($dmg) and index("appcast.xml")' >/dev/null
curl --fail --silent --show-error --location --retry 5 --retry-all-errors "$APPCAST_URL" | grep -F "$DMG_URL" >/dev/null
echo "published $DMG_URL"
