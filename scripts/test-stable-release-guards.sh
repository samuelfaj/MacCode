#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
preflight="$repo_root/scripts/release-preflight.sh"
fixture_root="$(mktemp -d)"
cleanup() {
  rm -rf "$fixture_root"
}
trap cleanup EXIT

fake_bin="$fixture_root/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "rev-parse" ]; then
  printf '%s\n' "${RC2_FAKE_TAG_SHA:-$GITHUB_SHA}"
  exit 0
fi
exec /usr/bin/git "$@"
EOF

chmod +x "$fake_bin/git"

GITHUB_SHA="0123456789abcdef0123456789abcdef01234567"
export GITHUB_SHA
export RELEASE_TAG="v9.8.7"
export GITHUB_REF_TYPE="tag"
export GITHUB_REF_NAME="$RELEASE_TAG"
export GITHUB_RUN_ID="456"
export GITHUB_API_URL="https://api.github.example"
export GITHUB_REPOSITORY="owner/repo"
export GITHUB_TOKEN="job-token"
export PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

"$preflight" >/dev/null

expect_preflight_failure() {
  local label="$1"
  shift
  if ( "$@" ) >/dev/null 2>&1; then
    echo "FAIL: preflight accepted $label" >&2
    exit 1
  fi
}

export RC2_FAKE_TAG_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expect_preflight_failure "wrong tag SHA" "$preflight"
unset RC2_FAKE_TAG_SHA

saved_tag="$GITHUB_REF_NAME"
export GITHUB_REF_NAME="v9.8.8"
expect_preflight_failure "mismatched RELEASE_TAG" "$preflight"
export GITHUB_REF_NAME="$saved_tag"

saved_release_tag="$RELEASE_TAG"
export RELEASE_TAG="v9.8.7-beta"
export GITHUB_REF_NAME="$RELEASE_TAG"
expect_preflight_failure "non-semver tag" "$preflight"
export RELEASE_TAG="$saved_release_tag"
export GITHUB_REF_NAME="$saved_release_tag"

export GITHUB_REF_TYPE="branch"
expect_preflight_failure "branch ref" "$preflight"
export GITHUB_REF_TYPE="tag"

saved_ref_name="$GITHUB_REF_NAME"
unset GITHUB_REF_NAME
expect_preflight_failure "missing GITHUB_REF_NAME" "$preflight"
export GITHUB_REF_NAME="$saved_ref_name"

workflow="$repo_root/.github/workflows/release.yml"
release_script="$repo_root/scripts/release-stable.sh"
stable_rules="$(<"$release_script")"
workflow_jobs="$(awk '
  /^jobs:/ { in_jobs=1; next }
  in_jobs && /^[^[:space:]]/ { exit }
  in_jobs && /^  [A-Za-z0-9_-]+:/ { name=$1; sub(/:.*/, "", name); print name }
' "$workflow")"
if [ "$workflow_jobs" != "stable_macos_arm64_dmg" ]; then
  echo "FAIL: release workflow defines an unexpected job:" >&2
  printf '%s\n' "$workflow_jobs" >&2
  exit 1
fi
if grep -E 'pull_request|workflow_dispatch|branches:|schedule:' "$workflow" >/dev/null; then
  echo "FAIL: release workflow must run only on tag pushes" >&2
  exit 1
fi
if ! grep -F '      - "v*.*.*"' "$workflow" >/dev/null \
  || ! grep -F 'run: bash scripts/release-stable.sh' "$workflow" >/dev/null
then
  echo "FAIL: release workflow is not admitted by a semver tag push" >&2
  exit 1
fi
# shellcheck disable=SC2016
if ! grep -F '[[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]' "$workflow" >/dev/null \
  || ! printf '%s\n' "$stable_rules" | grep -F 'scripts/release-preflight.sh' >/dev/null
then
  echo "FAIL: workflow must admit only stable semver tags" >&2
  exit 1
fi
# shellcheck disable=SC2016
if ! printf '%s\n' "$stable_rules" | grep -F 'bash scripts/orchestrate-launch-smoke.sh "$MOUNT/MacCode.app"' >/dev/null; then
  echo "FAIL: stable publication does not gate on mounted-app launch smoke" >&2
  exit 1
fi
# shellcheck disable=SC2016
if printf '%s\n' "$stable_rules" | grep -F 'orchestrate-launch-smoke.sh "$MOUNT/MacCode.app" ||' >/dev/null; then
  echo "FAIL: stable launch smoke is still non-gating" >&2
  exit 1
fi
if printf '%s\n' "$stable_rules" | grep -E '(^|[[:space:]])aws ' >/dev/null; then
  echo "FAIL: stable publication must not depend on AWS" >&2
  exit 1
fi
if ! printf '%s\n' "$stable_rules" | grep -F 'gh release create "$TAG" "dist/$ASSET_NAME" dist/pages/appcast.xml' >/dev/null; then
  echo "FAIL: stable publication must attach the DMG and appcast to the GitHub release" >&2
  exit 1
fi

echo "stable release guards: PASS"
