#!/bin/sh
# Flowz CLI installer (ADR-032).
#
#   curl -fsSL https://raw.githubusercontent.com/flowzhq/flowz-install/main/install.sh \
#     | FLOWZ_TOKEN=<your token> sh
#
# Downloads the flowz build for this machine from the private registry, verifies
# its sha256 against the published release metadata, and installs it to
# ~/.flowz/bin/flowz. After this, `flowz upgrade` handles every future update.
#
# Environment:
#   FLOWZ_TOKEN        (required) the access token you were issued
#   FLOWZ_VERSION      install this exact version instead of the latest (e.g. v1.2.3)
#   FLOWZ_INSTALL_DIR  install here instead of ~/.flowz/bin
#   FLOWZ_CLI_PACKAGE  override the registry package (testing)
#
# Local mode (offline bundles): with a flowz binary and a SHA256SUMS file
# beside this script — `flowz_<version>_<os>_<arch>` or `flowz` — the script
# verifies the binary against SHA256SUMS and installs it, with no network, no
# token and no update check. It needs awk, cp, grep and sha256sum or shasum
# (the online path needs only curl and gzip), and applies only to this file run
# as a file (`sh ./install.sh`) with SHA256SUMS beside it, never to `curl | sh`.
#   FLOWZ_LOCAL=1      require local mode (fail if no binary or SHA256SUMS is beside the script)
#   FLOWZ_LOCAL=0      never use local mode
#   FLOWZ_BINARY=<p>   install this binary; SHA256SUMS is read from its directory
#
# flowz-install-script (marker: local mode trusts only a $0 that carries this line)
#
# POSIX sh, and curl is the only hard requirement — deliberately NO jq: every
# artifact this pulls has exactly one layer, so the blob digest is the single
# sha256 in its manifest and `grep` is sufficient. A bootstrap script that needs
# its own dependency installed first isn't a bootstrap script.
set -eu

PACKAGE="${FLOWZ_CLI_PACKAGE:-ghcr.io/flowzhq/flowz-cli}"
REGISTRY="${PACKAGE%%/*}"
REPOSITORY="${PACKAGE#*/}"
INSTALL_DIR="${FLOWZ_INSTALL_DIR:-$HOME/.flowz/bin}"
SCHEME=https
case "$REGISTRY" in localhost:*|127.0.0.1:*|localhost|127.0.0.1) SCHEME=http ;; esac

die() { echo "error: $*" >&2; exit 1; }
info() { echo "$*" >&2; }

# mv onto a directory named flowz moves the binary inside it and succeeds.
[ ! -d "$INSTALL_DIR/flowz" ] || die "$INSTALL_DIR/flowz is a directory, not the flowz binary. Move or delete it and rerun. Nothing was installed."

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else die "need sha256sum or shasum to verify the download"; fi
}

detect_platform() {
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$os" in
    linux|darwin) ;;
    *) die "unsupported OS '$os' — use install.ps1 on Windows" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) die "unsupported architecture '$(uname -m)' (flowz ships amd64 and arm64)" ;;
  esac
  PLATFORM="$os-$arch"
}

print_path_hint() {
  case ":$PATH:" in
    *":$INSTALL_DIR:"*) info "Run: flowz version" ;;
    *)
      info ""
      info "$INSTALL_DIR is not on your PATH. Add it:"
      info "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.zshrc   # or ~/.bashrc"
      info "  export PATH=\"$INSTALL_DIR:\$PATH\""
      info ""
      info "Then run: flowz version"
      ;;
  esac
}

# --- local mode ---------------------------------------------------------------
# Install the binary that came with this script. Nothing below touches the
# network, so this runs before the curl and token checks of the online path.
case "${FLOWZ_LOCAL:-}" in
  ""|0|1) ;;
  *) die "FLOWZ_LOCAL must be 1 or 0, not '$FLOWZ_LOCAL'" ;;
esac
local_bin="${FLOWZ_BINARY:-}"
# $0 names this installer only when it is run as a file (`sh ./install.sh`):
# piped from curl it is the shell itself, whose directory may hold anything.
self=0
if [ -f "$0" ] && grep -q '^# flowz-install-script ' "$0" 2>/dev/null; then self=1; fi
if [ -z "$local_bin" ] && [ "${FLOWZ_LOCAL:-}" != 0 ] && [ "$self" = 1 ] \
   && { [ "${FLOWZ_LOCAL:-}" = 1 ] || [ -f "$(dirname "$0")/SHA256SUMS" ]; }; then
  here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
  detect_platform
  found=""; nfound=0
  for f in "$here"/flowz_*_"$os"_"$arch"; do
    [ -f "$f" ] || continue
    found="$found $f"; nfound=$((nfound + 1))
  done
  if [ "$nfound" -gt 1 ]; then
    die "several flowz_*_${os}_${arch} binaries are beside this script:$found
Keep one, or name it: FLOWZ_BINARY=<path> sh ./install.sh"
  elif [ "$nfound" = 1 ]; then local_bin=${found# }
  elif [ -f "$here/flowz" ]; then local_bin="$here/flowz"
  elif [ "${FLOWZ_LOCAL:-}" = 1 ]; then
    die "FLOWZ_LOCAL=1 but no flowz_*_${os}_${arch} or flowz is beside $0"
  fi
elif [ -z "$local_bin" ] && [ "${FLOWZ_LOCAL:-}" = 1 ]; then
  die "FLOWZ_LOCAL=1 needs this installer run as a file beside the binary (sh ./install.sh), or FLOWZ_BINARY=<path>"
fi

if [ -n "$local_bin" ]; then
  [ -f "$local_bin" ] || die "$local_bin is not a file"
  bin_dir=$(CDPATH='' cd -- "$(dirname -- "$local_bin")" && pwd)
  bin_name=$(basename "$local_bin")
  sums="$bin_dir/SHA256SUMS"
  [ -f "$sums" ] || die "no SHA256SUMS beside $bin_name (looked in $bin_dir). Nothing was installed."
  want_sha=$(awk -v n="$bin_name" '{ gsub(/\r/, ""); f = $2; sub(/^\*/, "", f); if (f == n) { print tolower($1); exit } }' "$sums")
  [ -n "$want_sha" ] || die "SHA256SUMS has no entry for $bin_name. Nothing was installed."
  version=""
  case "$bin_name" in
    flowz_*_*_*) version=${bin_name#flowz_}; version=${version%_*_*} ;;
  esac
  if [ -n "$version" ] && [ -n "${FLOWZ_VERSION:-}" ]; then
    case "$FLOWZ_VERSION" in v*) want_v="$FLOWZ_VERSION" ;; *) want_v="v$FLOWZ_VERSION" ;; esac
    [ "$want_v" = "$version" ] || die "FLOWZ_VERSION=$FLOWZ_VERSION but $bin_name is $version. Nothing was installed."
  fi
  info "Installing flowz${version:+ $version} from $bin_name (local, no network)…"
  mkdir -p "$INSTALL_DIR" || die "could not create $INSTALL_DIR"
  # Verify the copy, not the source: nothing can swap the file between check and install.
  staged="$INSTALL_DIR/.flowz.install.$$"
  trap 'rm -f "$staged"' EXIT INT TERM
  cp "$local_bin" "$staged" || die "could not copy to $INSTALL_DIR"
  got_sha=$(sha256_of "$staged")
  [ "$got_sha" = "$want_sha" ] || die "checksum mismatch for $bin_name
  got:      $got_sha
  expected: $want_sha
The file was corrupted or changed after SHA256SUMS was made. Nothing was installed."
  chmod 0755 "$staged"
  mv -f "$staged" "$INSTALL_DIR/flowz" || die "could not install to $INSTALL_DIR"
  info ""
  info "Installed flowz${version:+ $version} to $INSTALL_DIR/flowz"
  print_path_hint
  info "Updates: install a newer offline bundle."
  exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl is required"

[ -n "${FLOWZ_TOKEN:-}" ] || die "FLOWZ_TOKEN is not set.
flowz is distributed privately to design partners. Set the access token you were
issued and re-run:
  curl -fsSL <this url> | FLOWZ_TOKEN=<your token> sh"

# --- platform -----------------------------------------------------------------
detect_platform

# --- registry helpers ---------------------------------------------------------
# One bearer for the whole run. GHCR ignores the basic-auth username.
# Note: a pipeline's status is its LAST command's, so a curl failure here shows
# up as an empty result rather than a non-zero exit — hence the emptiness check
# carries the real diagnosis.
bearer=$(
  curl -fsL -u "x:$FLOWZ_TOKEN" \
    "$SCHEME://$REGISTRY/token?service=$REGISTRY&scope=repository:$REPOSITORY:pull" \
  | tr ',' '\n' | grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
)
[ -n "$bearer" ] || die "could not authenticate to $REGISTRY.
Check the token hasn't been revoked and that it has read:packages on $PACKAGE."

# manifest_blob_digest <tag> — the one layer digest in a single-layer artifact.
# Everything before "layers" is discarded first, so the config descriptor's own
# digest can't be mistaken for the layer's. Empty output means "not found".
manifest_blob_digest() {
  curl -fsL -H "Authorization: Bearer $bearer" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "$SCHEME://$REGISTRY/v2/$REPOSITORY/manifests/$1" \
  | tr -d '\n' | sed 's/.*"layers"//' \
  | grep -o 'sha256:[0-9a-f]\{64\}' | head -1
}

# Blob fetches keep curl's -S: a mid-download network failure has no better
# diagnosis than curl's own. The token/manifest probes above drop it, because
# this script already turns those failures into an actionable message.
fetch_blob() { # <digest> [output]; no output = stdout
  if [ -n "${2:-}" ]; then
    curl -fsSL -H "Authorization: Bearer $bearer" -o "$2" \
      "$SCHEME://$REGISTRY/v2/$REPOSITORY/blobs/$1"
  else
    curl -fsSL -H "Authorization: Bearer $bearer" \
      "$SCHEME://$REGISTRY/v2/$REPOSITORY/blobs/$1"
  fi
}

# --- resolve the release ------------------------------------------------------
if [ -n "${FLOWZ_VERSION:-}" ]; then
  case "$FLOWZ_VERSION" in v*) meta_tag="$FLOWZ_VERSION-meta" ;; *) meta_tag="v$FLOWZ_VERSION-meta" ;; esac
else
  meta_tag=latest
fi

meta_digest=$(manifest_blob_digest "$meta_tag")
[ -n "$meta_digest" ] || die "$PACKAGE:$meta_tag not found — check the version, or ask for access"

release_json=$(fetch_blob "$meta_digest") || die "could not download release metadata"

# Single-line greps over a known-shape document; see the no-jq note above.
version=$(echo "$release_json" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
[ -n "$version" ] || die "release metadata has no version"
want_sha=$(echo "$release_json" \
  | tr '}' '\n' \
  | grep "\"$PLATFORM\"" \
  | grep -o '"sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]\{64\}"' \
  | head -1 | sed 's/.*"\([0-9a-f]*\)"$/\1/')
[ -n "$want_sha" ] || die "release $version has no build for $PLATFORM"

info "Installing flowz $version ($PLATFORM)…"

# --- download, verify, install ------------------------------------------------
tmpdir=$(mktemp -d) || die "could not create a temp dir"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

bin_digest=$(manifest_blob_digest "$version-$PLATFORM")
[ -n "$bin_digest" ] || die "$PACKAGE:$version-$PLATFORM not found"

fetch_blob "$bin_digest" "$tmpdir/flowz.gz" || die "download failed"
gzip -dc "$tmpdir/flowz.gz" > "$tmpdir/flowz" || die "could not decompress the download"

got_sha=$(sha256_of "$tmpdir/flowz")
[ "$got_sha" = "$want_sha" ] || die "checksum mismatch for $version $PLATFORM
  got:      $got_sha
  expected: $want_sha
The download was corrupted or tampered with. Nothing was installed."

mkdir -p "$INSTALL_DIR" || die "could not create $INSTALL_DIR"
chmod 0755 "$tmpdir/flowz"
# Move into place last, so a failure above never leaves a partial binary on PATH.
mv -f "$tmpdir/flowz" "$INSTALL_DIR/flowz" || die "could not install to $INSTALL_DIR"

# Store the token so `flowz upgrade` works without re-supplying it. The CLI
# always reads ~/.flowz/credentials.json regardless of where the binary lives.
# A new file is written inside a subshell umask so it is never briefly
# world-readable. An existing one may hold more (model registry tokens and
# CAs, flowz's Claude sign-in): the new binary replaces only the token there.
mkdir -p "$HOME/.flowz"
cred="$HOME/.flowz/credentials.json"
if [ -s "$cred" ]; then
  if ! login_out=$(printf '%s\n' "$FLOWZ_TOKEN" | "$INSTALL_DIR/flowz" login downloads --yes 2>&1); then
    info "$login_out"
    info "warning: $cred was kept as it was, without this token; store it with: flowz login downloads"
  fi
else
  (
    umask 077
    printf '{\n  "registry": "%s",\n  "token": "%s"\n}\n' "$PACKAGE" "$FLOWZ_TOKEN" > "$cred"
  )
fi

info ""
info "Installed flowz $version to $INSTALL_DIR/flowz"

print_path_hint
info "Future updates: flowz upgrade"
