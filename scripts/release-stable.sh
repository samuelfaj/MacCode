#!/usr/bin/env bash
# Stable macOS release: sign, notarize, publish the DMG and Sparkle appcast
# to remotecode.io, then create the GitHub release. Run only by
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
CLOUDFRONT_DISTRIBUTION_ID="${REMOTECODE_IO_CLOUDFRONT_DISTRIBUTION_ID:-}"

test "$(uname -m)" = "arm64"
command -v aws >/dev/null || brew install awscli
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
if [ -z "${AWS_RELEASE_UPLOAD_ROLE_ARN:-}" ]; then
  echo "AWS_RELEASE_UPLOAD_ROLE_ARN variable is required for public macOS downloads"
  exit 1
fi
if [ -z "$CLOUDFRONT_DISTRIBUTION_ID" ]; then
  echo "REMOTECODE_IO_CLOUDFRONT_DISTRIBUTION_ID variable is required for release download invalidation"
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
KEYCHAIN="$TEMP_DIR/remotecode-signing.keychain-db"
CERTIFICATE="$TEMP_DIR/developer-id.p12"
ORIGINAL_USER_KEYCHAINS="$TEMP_DIR/original-user-keychains.txt"
# shellcheck source=scripts/release-publication-guard.sh
source scripts/release-publication-guard.sh
RELEASE_API="$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/releases"
export RC2_RELEASE_BACKUP_DIR="$TEMP_DIR/mutable-publication-backup"
export RC2_RELEASE_S3_BUCKET="$S3_BUCKET"
export RC2_RELEASE_LATEST_KEY="$S3_DOWNLOAD_PREFIX/latest/$ASSET_NAME"
export RC2_RELEASE_APPCAST_KEY="$S3_DOWNLOAD_PREFIX/appcast.xml"
export RC2_RELEASE_CLOUDFRONT_DISTRIBUTION_ID="$CLOUDFRONT_DISTRIBUTION_ID"
export RC2_RELEASE_API="$RELEASE_API"
export RC2_RELEASE_TAG="$TAG"
export RC2_RELEASE_TOKEN="$GITHUB_TOKEN"
export RC2_RELEASE_OWNERSHIP_TOKEN="${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}-$(uuidgen | tr '[:upper:]' '[:lower:]')"

EXISTING_RELEASE_RESPONSE="$TEMP_DIR/existing-release.json"
EXISTING_RELEASE_CODE="$(curl --silent --show-error \
  --output "$EXISTING_RELEASE_RESPONSE" \
  --write-out "%{http_code}" \
  --header "Authorization: Bearer $GITHUB_TOKEN" \
  --header "Accept: application/vnd.github+json" \
  "$RELEASE_API/tags/$TAG")"
if [ "$EXISTING_RELEASE_CODE" != "404" ] && [ "$EXISTING_RELEASE_CODE" != "200" ]; then
  echo "Unexpected GitHub release lookup for $TAG; HTTP $EXISTING_RELEASE_CODE" >&2
  cat "$EXISTING_RELEASE_RESPONSE" >&2 || true
  exit 1
fi

security list-keychains -d user \
  | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' \
  > "$ORIGINAL_USER_KEYCHAINS"
MOUNT=""
cleanup_release() {
  local exit_code="$1"
  trap - EXIT
  set +e
  if ! rc2_release_guard_rollback; then
    echo "release guard: rollback did not complete" >&2
    exit_code=1
  fi
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
export RC2_SPARKLE_FEED_URL="$S3_DOWNLOAD_BASE_URL/appcast.xml"

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

OIDC_TOKEN="$(curl --fail --silent --show-error \
  --header "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r '.value')"
AWS_STS_OUTPUT="$(aws sts assume-role-with-web-identity \
  --role-arn "$AWS_RELEASE_UPLOAD_ROLE_ARN" \
  --role-session-name "GitHubActions-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}" \
  --web-identity-token "$OIDC_TOKEN" \
  --duration-seconds 3600 \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
  --output text)"
set -- $AWS_STS_OUTPUT
export AWS_ACCESS_KEY_ID="$1"
export AWS_SECRET_ACCESS_KEY="$2"
export AWS_SESSION_TOKEN="$3"

aws s3 cp "dist/$ASSET_NAME" "s3://$S3_BUCKET/$S3_DOWNLOAD_PREFIX/$TAG/$ASSET_NAME" \
  --content-type "application/x-apple-diskimage" \
  --cache-control "public, max-age=31536000, immutable"

rc2_release_guard_capture
rc2_release_guard_begin_mutation

aws s3 cp "dist/$ASSET_NAME" "s3://$S3_BUCKET/$S3_DOWNLOAD_PREFIX/latest/$ASSET_NAME" \
  --content-type "application/x-apple-diskimage" \
  --cache-control "no-cache, max-age=0"

SPARKLE_TOOLS=".build/artifacts/sparkle/Sparkle/bin"
SIGN_UPDATE="$SPARKLE_TOOLS/sign_update"
if [ ! -x "$SIGN_UPDATE" ]; then
  echo "Sparkle sign_update tool not found at $SIGN_UPDATE"
  exit 1
fi
KEY_FILE="$TEMP_DIR/sparkle_ed_private_key"
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "dist/$ASSET_NAME")"
APPCAST_URL="$S3_DOWNLOAD_BASE_URL/appcast.xml"
DMG_URL="$S3_DOWNLOAD_BASE_URL/$TAG/$ASSET_NAME"
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

aws s3 cp "dist/pages/appcast.xml" "s3://$S3_BUCKET/$S3_DOWNLOAD_PREFIX/appcast.xml" \
  --content-type "application/xml; charset=utf-8" \
  --cache-control "no-cache, max-age=0"
aws cloudfront create-invalidation \
  --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" \
  --paths "/$S3_DOWNLOAD_PREFIX/appcast.xml" "/$S3_DOWNLOAD_PREFIX/latest/$ASSET_NAME" "/$S3_DOWNLOAD_PREFIX/$TAG/$ASSET_NAME"
gh_api() {
  curl --silent --show-error \
    --header "Authorization: Bearer $GITHUB_TOKEN" \
    --header "Accept: application/vnd.github+json" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

RELEASE_NOTES="RemoteCode macOS $VERSION

- DMG: $DMG_URL
- Sparkle appcast: $APPCAST_URL"

PUBLISH_RELEASE_RESPONSE="$TEMP_DIR/publish-release.json"
PUBLISH_RELEASE_CODE="$(gh_api --output "$PUBLISH_RELEASE_RESPONSE" --write-out "%{http_code}" \
  "$RELEASE_API/tags/$TAG")"
if [ "$PUBLISH_RELEASE_CODE" = "200" ]; then
  echo "GitHub release $TAG already exists; attaching download links"
  if ! jq -e --arg dmg_url "$DMG_URL" '(.body // "") | contains($dmg_url)' "$PUBLISH_RELEASE_RESPONSE" >/dev/null; then
    RELEASE_ID="$(jq -r '.id' "$PUBLISH_RELEASE_RESPONSE")"
    UPDATE_PAYLOAD="$(jq --arg notes "$RELEASE_NOTES" \
      '{body: (((.body // "") | if . == "" then "" else . + "\n\n" end) + $notes)}' \
      "$PUBLISH_RELEASE_RESPONSE")"
    gh_api --fail --request PATCH \
      --header "Content-Type: application/json" \
      --data "$UPDATE_PAYLOAD" \
      "$RELEASE_API/$RELEASE_ID" >/dev/null
  fi
elif [ "$PUBLISH_RELEASE_CODE" = "404" ]; then
  RELEASE_PAYLOAD="$(jq -n \
    --arg tag "$TAG" \
    --arg name "RemoteCode $VERSION" \
    --arg body "$RELEASE_NOTES

$(rc2_release_guard_ownership_marker)" \
    '{tag_name: $tag, name: $name, body: $body, draft: false, prerelease: false}')"
  RELEASE_RESPONSE="$TEMP_DIR/github-release-response.json"
  RELEASE_CODE=""
  RELEASE_REQUEST_SUCCEEDED=0
  if RELEASE_CODE="$(gh_api --output "$RELEASE_RESPONSE" --write-out "%{http_code}" \
      --request POST \
      --header "Content-Type: application/json" \
      --data "$RELEASE_PAYLOAD" \
      "$RELEASE_API")"
  then
    RELEASE_REQUEST_SUCCEEDED=1
  fi
  RELEASE_OWNED=0
  if [ "$RELEASE_REQUEST_SUCCEEDED" = "1" ] && [ "$RELEASE_CODE" = "201" ]; then
    RELEASE_OWNED=1
  elif rc2_release_guard_retry rc2_release_guard_confirm_release_ownership; then
    echo "GitHub release creation was reconciled after an ambiguous response"
    RELEASE_OWNED=1
  fi
  if [ "$RELEASE_OWNED" != "1" ]; then
    echo "GitHub release API failed without proof of ownership (HTTP ${RELEASE_CODE:-transport-error})" >&2
    cat "$RELEASE_RESPONSE" >&2 || true
    exit 1
  fi
  rc2_release_guard_note_release_created
else
  echo "Unexpected GitHub release lookup before publish; HTTP $PUBLISH_RELEASE_CODE" >&2
  cat "$PUBLISH_RELEASE_RESPONSE" >&2 || true
  exit 1
fi

RELEASE_READBACK="$TEMP_DIR/github-release-readback.json"
gh_api --fail "$RELEASE_API/tags/$TAG" > "$RELEASE_READBACK"
TAG_COMMIT="$(git rev-parse "$TAG^{commit}")"
jq -e \
  --arg tag "$TAG" \
  --arg dmg_url "$DMG_URL" \
  --arg appcast_url "$APPCAST_URL" \
  '
    .tag_name == $tag
    and ((.body // "") | contains($dmg_url))
    and ((.body // "") | contains($appcast_url))
  ' "$RELEASE_READBACK" >/dev/null
test "$TAG_COMMIT" = "$GITHUB_SHA"

rc2_release_guard_commit
