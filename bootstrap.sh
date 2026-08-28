#!/usr/bin/env bash
#
# Hanan Foundation bootstrap installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/liwanagtan/hanan-installer-dist/main/bootstrap.sh | sudo bash
#
# Responsibilities:
#   1. Require root and a supported platform (Ubuntu, linux amd64/arm64).
#   2. Resolve the pinned release versions from version.json.
#   3. Download and checksum-verify the `hanan` CLI binary.
#   4. Download and verify the signed hanan-foundation release
#      (archive checksum, manifest digest, and OpenSSL signature).
#   5. Prompt (from /dev/tty) for deployment type, profile, LAN CIDR and
#      the operator/MQTT passwords, which are written to root-owned 0600 files.
#   6. Run `hanan install --apply --provision --provision-tty ...` so site
#      identity, timezone, and Zigbee discovery reuse the installer's own
#      provisioning logic.
#   7. Print the manual Home Assistant onboarding follow-up.
#
# Environment overrides (for scripted installs):
#   HANAN_INSTALLER_VERSION   pin installer version (default: version.json)
#   HANAN_FOUNDATION_VERSION  pin foundation version  (default: version.json)
#   HANAN_DEPLOYMENT          customer|lab (skip the interactive prompt)
#   HANAN_PROFILE             home|rentals|business|farm|warehouse
#   HANAN_LAN_CIDR            e.g. 192.168.1.0/24
#   HANAN_OPERATOR_PASSWORD   provide instead of prompting
#   HANAN_MQTT_PASSWORD       provide instead of prompting
#
set -euo pipefail

DIST_OWNER="liwanagtan"
DIST_REPO="hanan-installer-dist"
DIST_PATH="${DIST_OWNER}/${DIST_REPO}"
RAW_BASE="https://raw.githubusercontent.com/${DIST_PATH}/main"

# SHA-256 of the DER-encoded release public key. Bumped on key rotation.
EXPECTED_PUB_PEM_FINGERPRINT="176c8f8823289b2ac74483b874395f3e6f84e7e63337c66d39547de6d2546c6f"

SAFE_PASSWORD_RE='^[A-Za-z0-9._@%+,=/!-]+$'
PROFILE_CHOICES="home,rentals,business,farm,warehouse"

fail() { printf 'bootstrap: %s\n' "$*" >&2; exit 1; }
info() { printf 'bootstrap: %s\n' "$*" >/dev/tty; }

ask() {
  # ask VAR "Prompt text" [default]
  local var="$1" prompt="$2" default="${3:-}" answer
  if [ -n "$default" ]; then
    prompt="${prompt} [${default}]"
  fi
  printf '%s: ' "$prompt" >/dev/tty
  IFS= read -r answer </dev/tty || return 1
  if [ -z "$answer" ] && [ -n "$default" ]; then
    answer="$default"
  fi
  printf -v "$var" '%s' "$answer"
}

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "must run as root; use: curl -fsSL ... | sudo bash"
  fi
}

check_platform() {
  if [ "$(uname -s)" != "Linux" ]; then
    fail "unsupported OS: $(uname -s); Hanan requires Linux"
  fi
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
  esac

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi
  if [ "${ID:-}" != "ubuntu" ]; then
    fail "unsupported distribution: ${ID:-unknown}; Hanan requires Ubuntu"
  fi

  case "${VERSION_ID:-}" in
    "26.04") ;;
    2[4-9].*) info "note: ${PRETTY_NAME} is newer than the validated 26.04 baseline" ;;
    *) info "warning: Ubuntu ${VERSION_ID:-unknown} may not be supported by this release" ;;
  esac
}

fetch() {
  local url="$1" dest="$2"
  curl -fsSL --retry 3 --connect-timeout 20 "$url" -o "$dest" ||
    fail "download failed: $url"
}

resolve_versions() {
  local vjson work
  INSTALLER_VERSION="${HANAN_INSTALLER_VERSION:-}"
  FOUNDATION_VERSION="${HANAN_FOUNDATION_VERSION:-}"
  if [ -z "$INSTALLER_VERSION" ] || [ -z "$FOUNDATION_VERSION" ]; then
    work="$(mktemp)"
    fetch "$RAW_BASE/version.json" "$work"
    vjson="$(cat "$work")"
    rm -f "$work"
  fi
  [ -n "$INSTALLER_VERSION" ] ||
    INSTALLER_VERSION="$(printf '%s' "$vjson" | sed -n 's/.*"installer_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$FOUNDATION_VERSION" ] ||
    FOUNDATION_VERSION="$(printf '%s' "$vjson" | sed -n 's/.*"foundation_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$INSTALLER_VERSION" ] && [ "$INSTALLER_VERSION" != "0.0.0" ] ||
    fail "no installer release available yet (version.json unset); publish v* first"
  [ -n "$FOUNDATION_VERSION" ] && [ "$FOUNDATION_VERSION" != "0.0.0" ] ||
    fail "no foundation release available yet (version.json unset); publish v* first"
  REL_BASE="https://github.com/${DIST_PATH}/releases/download/v${INSTALLER_VERSION}"
}

print_plan() {
  cat <<EOF
Hanan Foundation bootstrap
  installer version : $INSTALLER_VERSION  (arch: $ARCH)
  foundation release: $FOUNDATION_VERSION
  binary            : $REL_BASE/hanan-linux-$ARCH
  foundation bundle : $REL_BASE/hanan-foundation-$FOUNDATION_VERSION.tar.gz

The command that will run (interactively, from /dev/tty):

  hanan install --apply --provision --provision-tty \\
    --deployment <customer|lab>                      \\
    --release-archive   .../hanan-foundation-$FOUNDATION_VERSION.tar.gz        \\
    --release-manifest  .../hanan-foundation-$FOUNDATION_VERSION.manifest.json \\
    --release-checksum  .../hanan-foundation-$FOUNDATION_VERSION.tar.gz.sha256 \\
    --release-signature .../hanan-foundation-$FOUNDATION_VERSION.manifest.sig  \\
    --release-public-key .../pub.pem                                           \\
    --operator-password-file <root-owned 0600>                                 \\
    --mqtt-password-file <root-owned 0600>                                     \\
    [--profile <profile>] [--lan-cidr <CIDR>]
EOF
}

verify_public_key() {
  local key="$1" fp
  [ -n "$EXPECTED_PUB_PEM_FINGERPRINT" ] || fail "bootstrap is missing the expected pub.pem fingerprint"
  fp="$(openssl pkey -pubin -in "$key" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  [ -n "$fp" ] && [ "$fp" = "$EXPECTED_PUB_PEM_FINGERPRINT" ] ||
    fail "pub.pem fingerprint mismatch (got ${fp:-empty}); refusing to trust the release"
}

verify_binary() {
  local dir="$1"
  local bin="$dir/hanan-linux-$ARCH"
  local sha="$dir/hanan-linux-$ARCH.sha256"
  local expected actual
  fetch "$REL_BASE/hanan-linux-$ARCH" "$bin"
  fetch "$REL_BASE/hanan-linux-$ARCH.sha256" "$sha"
  expected="$(awk 'NR==1 {print $1}' "$sha")"
  actual="$(sha256sum "$bin" | awk '{print $1}')"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] ||
    fail "hanan binary checksum mismatch"
  chmod 0755 "$bin"
}

verify_foundation() {
  local fdir="$1"
  local fv="$FOUNDATION_VERSION"
  local manifest="$fdir/hanan-foundation-$fv.manifest.json"
  local archive="$fdir/hanan-foundation-$fv.tar.gz"
  local sha_file="$fdir/hanan-foundation-$fv.tar.gz.sha256"
  local sig_file="$fdir/hanan-foundation-$fv.manifest.sig"
  local pubkey="$fdir/pub.pem"
  local archive_sha expected_sha manifest_sha

  fetch "$REL_BASE/hanan-foundation-$fv.tar.gz" "$archive"
  fetch "$REL_BASE/hanan-foundation-$fv.manifest.json" "$manifest"
  fetch "$REL_BASE/hanan-foundation-$fv.tar.gz.sha256" "$sha_file"
  fetch "$REL_BASE/hanan-foundation-$fv.manifest.sig" "$sig_file"
  fetch "$RAW_BASE/pub.pem" "$pubkey"
  verify_public_key "$pubkey"

  archive_sha="$(sha256sum "$archive" | awk '{print $1}')"
  expected_sha="$(awk 'NR==1 {print $1}' "$sha_file")"
  [ -n "$expected_sha" ] && [ "$expected_sha" = "$archive_sha" ] ||
    fail "foundation archive checksum mismatch"
  manifest_sha="$(sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$manifest" | head -n1)"
  [ -n "$manifest_sha" ] && [ "$manifest_sha" = "$archive_sha" ] ||
    fail "foundation manifest digest does not match the archive"
  openssl dgst -sha256 -verify "$pubkey" -signature "$sig_file" "$manifest" >/dev/null 2>&1 ||
    fail "foundation manifest signature verification failed"
  info "foundation release verified: v$fv"
}

validate_password() {
  local label="$1" value="$2"
  [ -n "$value" ] || fail "$label must not be empty"
  [ "${#value}" -ge 16 ] && [ "${#value}" -le 128 ] ||
    fail "$label must contain 16 to 128 characters"
  if ! printf '%s' "$value" | grep -Eq "$SAFE_PASSWORD_RE"; then
    fail "$label contains characters unsafe for Foundation credential files"
  fi
}

prompt_password() {
  local var="$1" label="$2" admin_tty="$3" value confirm
  if [ -n "${!var:-}" ]; then
    validate_password "$label" "${!var}"
    info "$label: using HANAN_*_PASSWORD override"
    return
  fi
  printf 'Generate a strong random %s automatically? [Y/n]: ' "$label" >/dev/tty
  IFS= read -r answer </dev/tty || true
  case "${answer:-y}" in
    [Yy]*)
      value="$(openssl rand -hex 32)" ||
        fail "could not generate $label"
      ;;
    *)
      printf '%s (hidden): ' "$label" >/dev/tty
      IFS= read -rs value </dev/tty || fail "could not read $label"
      printf '%s (confirm): ' "$label" >/dev/tty
      IFS= read -rs confirm </dev/tty || fail "could not read $label confirmation"
      [ "$value" = "$confirm" ] || fail "$label values did not match"
      printf '\n' >/dev/tty
      ;;
  esac
  validate_password "$label" "$value"
  printf '%s' "$value" >"$admin_tty" && chmod 0600 "$admin_tty"
}

write_password_files() {
  local pwdir
  pwdir="$(mktemp -d /root/.hanan-bootstrap-pw.XXXXXX)"
  chmod 0700 "$pwdir"
  OPERATOR_PW_FILE="$pwdir/operator.pw"
  MQTT_PW_FILE="$pwdir/mqtt.pw"
  prompt_password HANAN_OPERATOR_PASSWORD "operator password" "$OPERATOR_PW_FILE"
  prompt_password HANAN_MQTT_PASSWORD "MQTT password" "$MQTT_PW_FILE"
  if [ "$(cat "$OPERATOR_PW_FILE")" = "$(cat "$MQTT_PW_FILE")" ]; then
    fail "operator and MQTT passwords must be unique"
  fi
}

prompt_deployment() {
  if [ -n "${HANAN_DEPLOYMENT:-}" ]; then
    DEPLOYMENT="$HANAN_DEPLOYMENT"
  else
    ask DEPLOYMENT "Deployment type" ""
  fi
  case "$DEPLOYMENT" in
    customer|lab) ;;
    *) fail "deployment must be customer or lab (got: ${DEPLOYMENT:-empty})" ;;
  esac
}

prompt_profile() {
  PROFILE="${HANAN_PROFILE:-}"
  if [ -z "$PROFILE" ]; then
    PROFILE=""
    ask PROFILE "Hanan profile ($PROFILE_CHOICES, Enter to skip)" "" || PROFILE=""
  fi
  if [ -n "$PROFILE" ]; then
    case ",$PROFILE," in
      *,home,*|*,rentals,*|*,business,*|*,farm,*|*,warehouse,*) ;;
      *) fail "invalid profile: $PROFILE (choose one of $PROFILE_CHOICES)" ;;
    esac
  fi
}

prompt_lan_cidr() {
  LAN_CIDR="${HANAN_LAN_CIDR:-}"
  if [ -z "$LAN_CIDR" ]; then
    LAN_CIDR=""
    ask LAN_CIDR "LAN CIDR for firewall scoping, e.g. 192.168.1.0/24 (Enter to skip)" "" || LAN_CIDR=""
  fi
  if [ -n "$LAN_CIDR" ] && \
     ! printf '%s' "$LAN_CIDR" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'; then
    fail "invalid LAN CIDR: $LAN_CIDR"
  fi
}

run_apply() {
  local fdir="$1" args=()
  args=(
    install
    --apply
    --provision
    --provision-tty
    --deployment "$DEPLOYMENT"
    --release-archive "$fdir/hanan-foundation-$FOUNDATION_VERSION.tar.gz"
    --release-manifest "$fdir/hanan-foundation-$FOUNDATION_VERSION.manifest.json"
    --release-checksum "$fdir/hanan-foundation-$FOUNDATION_VERSION.tar.gz.sha256"
    --release-signature "$fdir/hanan-foundation-$FOUNDATION_VERSION.manifest.sig"
    --release-public-key "$fdir/pub.pem"
    --operator-password-file "$OPERATOR_PW_FILE"
    --mqtt-password-file "$MQTT_PW_FILE"
  )
  [ -z "$PROFILE" ] || args+=(--profile "$PROFILE")
  [ -z "$LAN_CIDR" ] || args+=(--lan-cidr "$LAN_CIDR")
  hanan "${args[@]}"
}

print_follow_up() {
  cat >/dev/tty <<EOF

Password files (root-owned 0600, keep them out of backups):
  operator: $OPERATOR_PW_FILE
  mqtt:     $MQTT_PW_FILE
EOF
}

main() {
  check_root
  check_platform
  resolve_versions

  if [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ]; then
    print_plan
    exit 0
  fi

  staging="$(mktemp -d /root/.hanan-bootstrap.XXXXXX)"
  trap 'rm -rf "$staging"' EXIT

  info "downloading hanan v$INSTALLER_VERSION ($ARCH)"
  verify_binary "$staging"
  fdir="$staging/foundation"; mkdir -p "$fdir"
  verify_foundation "$fdir"

  write_password_files
  prompt_deployment
  prompt_profile
  prompt_lan_cidr

  print_plan
  install -m 0755 "$staging/hanan-linux-$ARCH" /usr/local/bin/hanan
  info "installed /usr/local/bin/hanan"

  if run_apply "$fdir"; then
    print_follow_up
  else
    code=$?
    trap - EXIT
    fail "installation failed (exit $code); fix the cause then retry: sudo hanan install --resume"
  fi
}

main "$@"