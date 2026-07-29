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

command -v curl >/dev/null 2>&1 || die "curl is required"

[ -n "${FLOWZ_TOKEN:-}" ] || die "FLOWZ_TOKEN is not set.
flowz is distributed privately to design partners. Set the access token you were
issued and re-run:
  curl -fsSL <this url> | FLOWZ_TOKEN=<your token> sh"

# --- platform -----------------------------------------------------------------
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

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else die "need sha256sum or shasum to verify the download"; fi
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
# Written inside a subshell umask so it is never briefly world-readable.
mkdir -p "$HOME/.flowz"
(
  umask 077
  printf '{\n  "registry": "%s",\n  "token": "%s"\n}\n' "$PACKAGE" "$FLOWZ_TOKEN" \
    > "$HOME/.flowz/credentials.json"
)

info ""
info "Installed flowz $version to $INSTALL_DIR/flowz"

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
info "Future updates: flowz upgrade"
