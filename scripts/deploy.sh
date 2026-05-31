#!/usr/bin/env bash
#
# scripts/deploy.sh — Update and deploy Archon (CLI binary + Web UI) on this machine.
#
# Two modes:
#   (default)              Build from the current local repo checkout (dev tip).
#   --release vX.Y.Z       Install a published release via the canonical curl installer
#                          (https://archon.diy/install).
#
# Both modes target /usr/local/bin/archon — the same path the canonical installer uses —
# so dev-machine updates and fresh-machine installs share one source of truth and there's
# no PATH-shadow second copy. The script also removes a stale ~/.bun/bin/archon symlink
# (the usual culprit on machines that ran `bun install -g @archon/cli` at some point) and
# manages a launchd agent (diy.archon.serve) so `archon serve` autostarts and survives
# reboots/crashes.
#
# Usage:
#   ./scripts/deploy.sh                              # build from current checkout, deploy
#   ./scripts/deploy.sh --ref dev                    # pull latest dev first, then build & deploy
#   ./scripts/deploy.sh --release v0.4.1             # install published v0.4.1
#   ./scripts/deploy.sh --validate                   # run `bun run validate` before building
#   ./scripts/deploy.sh --no-restart                 # build/install but don't kick the service
#   ./scripts/deploy.sh --skip-launchd               # don't touch the launchd plist at all
#   ./scripts/deploy.sh --force                      # don't prompt on destructive cleanup
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults & arg parsing
# -----------------------------------------------------------------------------
MODE="local"            # local | release
RELEASE_VERSION=""
GIT_REF=""
DO_VALIDATE=0
DO_RESTART=1
DO_LAUNCHD=1
FORCE=0

LAUNCHD_LABEL="diy.archon.serve"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
ARCHON_HOME="${ARCHON_HOME:-$HOME/.archon}"
LOG_DIR="${ARCHON_HOME}/logs"
INSTALL_PATH="/usr/local/bin/archon"
BUN_SHADOW="$HOME/.bun/bin/archon"

usage() {
  # Print the leading comment block (everything up to, but not including, the
  # first non-comment/non-blank line).
  awk 'NR>1 && !/^(#|$)/ {exit} NR>1 {print}' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      MODE="release"
      RELEASE_VERSION="${2:?missing version after --release (e.g. v0.4.1)}"
      shift 2 ;;
    --ref)
      GIT_REF="${2:?missing ref after --ref}"
      shift 2 ;;
    --validate)    DO_VALIDATE=1; shift ;;
    --no-restart)  DO_RESTART=0; shift ;;
    --skip-launchd) DO_LAUNCHD=0; shift ;;
    --force)       FORCE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_OFF=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
else
  C_OFF=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi
info() { printf "%s==> %s%s\n" "$C_INFO" "$*" "$C_OFF"; }
ok()   { printf "%s ok %s%s\n" "$C_OK"   "$*" "$C_OFF"; }
warn() { printf "%s !! %s%s\n" "$C_WARN" "$*" "$C_OFF"; }
die()  { printf "%s err %s%s\n" "$C_ERR" "$*" "$C_OFF" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Platform detection
# -----------------------------------------------------------------------------
case "$(uname -s)" in
  Darwin) PLATFORM_OS="darwin" ;;
  Linux)  PLATFORM_OS="linux"  ;;
  *)      die "Unsupported OS: $(uname -s) (this script targets macOS or Linux)" ;;
esac
case "$(uname -m)" in
  arm64|aarch64) PLATFORM_ARCH="arm64" ;;
  x86_64|amd64)  PLATFORM_ARCH="x64"   ;;
  *)             die "Unsupported arch: $(uname -m)" ;;
esac
PLATFORM="${PLATFORM_OS}-${PLATFORM_ARCH}"

if [[ "$DO_LAUNCHD" == "1" && "$PLATFORM_OS" != "darwin" ]]; then
  warn "launchd is macOS-only; --skip-launchd implied on $PLATFORM_OS"
  DO_LAUNCHD=0
fi

# -----------------------------------------------------------------------------
# Repo root (only required in local mode)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# -----------------------------------------------------------------------------
# Shared install steps
# -----------------------------------------------------------------------------
remove_bun_shadow() {
  if [[ -L "$BUN_SHADOW" || -e "$BUN_SHADOW" ]]; then
    if [[ -L "$BUN_SHADOW" ]]; then
      info "Removing PATH-shadowing symlink: $BUN_SHADOW -> $(readlink "$BUN_SHADOW")"
      rm -f "$BUN_SHADOW"
      ok "Removed $BUN_SHADOW"
    else
      warn "$BUN_SHADOW is a regular file (not a symlink). Leaving it alone."
      warn "If it's stale, remove it manually: rm $BUN_SHADOW"
    fi
  fi
}

write_launchd_plist() {
  mkdir -p "$(dirname "$LAUNCHD_PLIST")"
  mkdir -p "$LOG_DIR"

  # Build a PATH the agent can use. launchd's default PATH is minimal — we need
  # bun (for `runtime: bun` script nodes), git, gh, claude, codex, etc.
  local agent_path="$HOME/.bun/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${INSTALL_PATH}</string>
    <string>serve</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>ThrottleInterval</key>
  <integer>10</integer>

  <key>WorkingDirectory</key>
  <string>${ARCHON_HOME}</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${agent_path}</string>
    <key>ARCHON_HOME</key>
    <string>${ARCHON_HOME}</string>
  </dict>

  <key>StandardOutPath</key>
  <string>${LOG_DIR}/serve.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/serve.err.log</string>
</dict>
</plist>
PLIST

  if [[ -f "$LAUNCHD_PLIST" ]] && cmp -s "$tmp" "$LAUNCHD_PLIST"; then
    ok "launchd plist already up to date ($LAUNCHD_PLIST)"
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$LAUNCHD_PLIST"
  ok "Wrote launchd plist: $LAUNCHD_PLIST"
}

restart_launchd_service() {
  local uid; uid="$(id -u)"
  local domain="gui/${uid}"

  # Drop any existing copy of the agent (ignore errors — it may not be loaded).
  launchctl bootout "${domain}/${LAUNCHD_LABEL}" 2>/dev/null || true
  if ! launchctl bootstrap "${domain}" "$LAUNCHD_PLIST"; then
    die "launchctl bootstrap failed for $LAUNCHD_PLIST"
  fi
  # Kickstart -k restarts an already-running agent in place.
  launchctl kickstart -k "${domain}/${LAUNCHD_LABEL}" >/dev/null 2>&1 || true
  ok "launchd agent ${LAUNCHD_LABEL} (re)started"
  info "Tail logs:  tail -F ${LOG_DIR}/serve.out.log ${LOG_DIR}/serve.err.log"
}

# -----------------------------------------------------------------------------
# Mode: release
# -----------------------------------------------------------------------------
deploy_release() {
  command -v curl >/dev/null 2>&1 || die "curl is required for --release mode"
  local v="${RELEASE_VERSION#v}"   # strip optional leading v
  info "Installing published release v${v} via the canonical installer"
  # The installer writes to /usr/local/bin/archon (default INSTALL_DIR) and
  # uses sudo as needed. VERSION env selects the release.
  if ! VERSION="v${v}" bash -c 'curl -fsSL https://archon.diy/install | bash'; then
    die "Canonical installer failed for v${v}"
  fi
  ok "Installed v${v} to ${INSTALL_PATH}"

  # The binary will download its own matching web dist on first `archon serve`.
  # Pre-fetch now so the first user request isn't blocked on a network round-trip.
  info "Pre-staging web UI for v${v}"
  "${INSTALL_PATH}" serve --download-only || warn "Pre-staging web UI failed (will retry at startup)"
}

# -----------------------------------------------------------------------------
# Mode: local build
# -----------------------------------------------------------------------------
deploy_local() {
  command -v bun >/dev/null 2>&1 || die "bun is required (https://bun.sh)"
  cd "$REPO_ROOT"
  [[ -d .git ]] || die "Not a git repo: $REPO_ROOT"

  # Update source
  if [[ -n "$GIT_REF" ]]; then
    info "Fetching and checking out ${GIT_REF}"
    git fetch --tags --prune origin
    git checkout "$GIT_REF"
    # Fast-forward branches, but leave tags/SHAs at detached HEAD.
    if git rev-parse --verify --quiet "refs/heads/${GIT_REF}" >/dev/null; then
      git pull --ff-only origin "$GIT_REF"
    fi
  else
    info "Pulling current branch"
    if ! git diff --quiet || ! git diff --cached --quiet; then
      if [[ "$FORCE" == "1" ]]; then
        warn "Working tree dirty — proceeding because --force"
      else
        die "Working tree has uncommitted changes. Commit/stash first, or pass --force."
      fi
    fi
    git pull --ff-only
  fi

  # Read version from package.json (bare semver, no leading v)
  local version
  version="$(grep '"version"' package.json | head -1 | cut -d'"' -f4)"
  [[ -n "$version" ]] || die "Could not read version from package.json"
  info "Building Archon v${version} for ${PLATFORM}"

  # Install deps + refresh bundled assets
  info "bun install"
  bun install

  info "Regenerating bundled defaults and schema"
  bun run generate:bundled
  bun run generate:bundled-schema

  if [[ "$DO_VALIDATE" == "1" ]]; then
    info "Running full validation (this is slow)"
    bun run validate
  fi

  # Build the binary for THIS platform only (the multi-target default is slow)
  local target_bin out_file
  target_bin="bun-${PLATFORM_OS}-${PLATFORM_ARCH}"
  out_file="dist/binaries/archon-${PLATFORM_OS}-${PLATFORM_ARCH}"
  info "Building CLI binary: ${out_file}"
  mkdir -p dist/binaries
  TARGET="${target_bin}" OUTFILE="${out_file}" bun run build:binaries

  [[ -x "$out_file" ]] || die "Binary missing or not executable: $out_file"

  # Build the web UI
  info "Building web UI"
  bun run build:web
  local web_src="$REPO_ROOT/packages/web/dist"
  [[ -f "$web_src/index.html" ]] || die "Web build missing: $web_src/index.html"

  # Install the binary at the canonical path used by the curl installer.
  info "Installing binary to ${INSTALL_PATH} (sudo may prompt)"
  if [[ -w "$(dirname "$INSTALL_PATH")" ]]; then
    install -m 0755 "$out_file" "$INSTALL_PATH"
  else
    sudo install -m 0755 "$out_file" "$INSTALL_PATH"
  fi
  ok "Installed ${INSTALL_PATH}"

  # Stage the matching web dist into the binary's own cache dir so `archon serve`
  # finds it locally and never tries to download a release that doesn't exist.
  local web_target="${ARCHON_HOME}/web-dist/${version}"
  info "Staging web UI to ${web_target}"
  mkdir -p "${ARCHON_HOME}/web-dist"
  rm -rf "${web_target}.tmp" "${web_target}"
  cp -R "$web_src" "${web_target}.tmp"
  mv "${web_target}.tmp" "${web_target}"
  ok "Web UI staged at ${web_target}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
if [[ "$MODE" == "release" ]]; then
  deploy_release
else
  deploy_local
fi

# Kill the PATH-shadow regardless of mode.
remove_bun_shadow

# Verify the resulting CLI works (smoke test, exit-code only).
if ! "$INSTALL_PATH" version >/dev/null 2>&1; then
  die "Smoke test failed: ${INSTALL_PATH} version returned non-zero"
fi
ok "Smoke test passed: $("$INSTALL_PATH" version | head -1)"

if [[ "$DO_LAUNCHD" == "1" ]]; then
  write_launchd_plist
  if [[ "$DO_RESTART" == "1" ]]; then
    restart_launchd_service
  else
    info "Skipping service restart (--no-restart)"
    info "To restart manually: launchctl kickstart -k gui/$(id -u)/${LAUNCHD_LABEL}"
  fi
else
  info "Skipping launchd setup (--skip-launchd or non-macOS)"
fi

ok "Done."
