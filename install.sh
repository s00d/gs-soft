#!/bin/sh
# Gateway Soft installer for macOS and Linux: installs or updates to the latest GitHub release.
#
#   curl -fsSL https://s00d.github.io/gs-soft/install.sh | sh
#
# Environment:
#   GS_VERSION=v0.8.0           a specific release instead of the latest
#   GS_FORMAT=deb|rpm|appimage  Linux package type (default: deb with apt/dpkg, rpm with dnf/yum/zypper,
#                               otherwise the AppImage on x86_64)
#   GS_REPO=owner/name          release repository (default s00d/gs-soft)
set -eu

REPO="${GS_REPO:-s00d/gs-soft}"
VERSION="${GS_VERSION:-}"
FORMAT="${GS_FORMAT:-}"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

has curl || die "curl is required"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if has sudo; then SUDO="sudo"; else SUDO=""; fi
fi

if [ -n "$VERSION" ]; then
  API="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
else
  API="https://api.github.com/repos/$REPO/releases/latest"
fi

say "Reading release info from github.com/$REPO"
JSON="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API")" \
  || die "no published release found (${VERSION:-latest})"

TAG="$(printf '%s' "$JSON" | tr ',' '\n' | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$TAG" ] || die "unexpected answer from the GitHub API"

# One "name|digest|url" line per asset (fields of an asset come in this order in the API answer).
ASSETS="$(printf '%s' "$JSON" | tr ',' '\n' | awk '
  /"name": *"/ { n = $0; sub(/.*"name": *"/, "", n); sub(/".*/, "", n) }
  /"digest": *"/ { d = $0; sub(/.*"digest": *"/, "", d); sub(/".*/, "", d) }
  /"digest": *null/ { d = "" }
  /"browser_download_url": *"/ {
    u = $0; sub(/.*"browser_download_url": *"/, "", u); sub(/".*/, "", u)
    print n "|" d "|" u; d = ""
  }')"

# First asset whose name ends with $1.
pick() { printf '%s\n' "$ASSETS" | awk -F'|' -v s="$1" 'length($1) >= length(s) && substr($1, length($1) - length(s) + 1) == s { print; exit }'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Downloads the asset line $1 into $TMP and checks GitHub's SHA-256; prints the file path.
fetch() {
  name="$(printf '%s' "$1" | cut -d'|' -f1)"
  digest="$(printf '%s' "$1" | cut -d'|' -f2)"
  url="$(printf '%s' "$1" | cut -d'|' -f3)"
  say "Downloading $name" >&2
  curl -fL --progress-bar -o "$TMP/$name" "$url" || die "download failed: $url"
  want="${digest#sha256:}"
  if [ -n "$digest" ] && [ "$want" != "$digest" ]; then
    if has sha256sum; then got="$(sha256sum "$TMP/$name" | cut -d' ' -f1)"
    elif has shasum; then got="$(shasum -a 256 "$TMP/$name" | cut -d' ' -f1)"
    else got=""; fi
    if [ -n "$got" ]; then
      [ "$got" = "$want" ] || die "SHA-256 mismatch for $name"
      say "SHA-256 verified" >&2
    fi
  fi
  printf '%s\n' "$TMP/$name"
}

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)
    line="$(pick "_universal.app.tar.gz")"
    [ -n "$line" ] || die "release $TAG has no macOS build"
    file="$(fetch "$line")"
    dest="/Applications"
    [ -w "$dest" ] || { [ -n "$SUDO" ] || dest="$HOME/Applications"; }
    mkdir -p "$dest" 2>/dev/null || true
    tar -xzf "$file" -C "$TMP"
    app="$(find "$TMP" -maxdepth 1 -name '*.app' | head -n 1)"
    [ -n "$app" ] || die "no .app inside the archive"
    run=""; [ -w "$dest" ] || run="$SUDO"
    $run rm -rf "$dest/$(basename "$app")"
    $run mv "$app" "$dest/"
    say "Installed $TAG to $dest/$(basename "$app")"
    echo "    Open it from Launchpad, or headless: \"$dest/$(basename "$app")/Contents/MacOS/gateway-soft-rs\" --serve"
    ;;
  Linux)
    case "$ARCH" in
      x86_64 | amd64) deb="_amd64.deb"; rpm=".x86_64.rpm"; appimage="_amd64.AppImage" ;;
      aarch64 | arm64) deb="_arm64.deb"; rpm=".aarch64.rpm"; appimage="" ;;
      armv7l | armv7* | armhf) deb="_armhf.deb"; rpm=".armhfp.rpm"; appimage="" ;;
      *) die "unsupported CPU: $ARCH" ;;
    esac
    if [ -z "$FORMAT" ]; then
      if has apt-get || has dpkg; then FORMAT="deb"
      elif has dnf || has yum || has zypper; then FORMAT="rpm"
      else FORMAT="appimage"; fi
    fi
    case "$FORMAT" in
      deb)
        line="$(pick "$deb")"; [ -n "$line" ] || die "release $TAG has no .deb for $ARCH"
        file="$(fetch "$line")"
        if has apt-get; then $SUDO apt-get install -y "$file"
        else $SUDO dpkg -i "$file"; fi
        bin="gateway-soft-rs"
        ;;
      rpm)
        line="$(pick "$rpm")"; [ -n "$line" ] || die "release $TAG has no .rpm for $ARCH"
        file="$(fetch "$line")"
        if has dnf; then $SUDO dnf install -y "$file"
        elif has zypper; then $SUDO zypper --non-interactive install --allow-unsigned-rpm "$file"
        elif has yum; then $SUDO yum install -y "$file"
        else $SUDO rpm -Uvh "$file"; fi
        bin="gateway-soft-rs"
        ;;
      appimage)
        [ -n "$appimage" ] || die "no AppImage for $ARCH; use GS_FORMAT=deb or rpm"
        line="$(pick "$appimage")"; [ -n "$line" ] || die "release $TAG has no AppImage"
        file="$(fetch "$line")"
        mkdir -p "$HOME/.local/bin"
        bin="$HOME/.local/bin/gateway-soft-rs"
        mv "$file" "$bin"
        chmod +x "$bin"
        case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "    Add ~/.local/bin to PATH to run it by name." ;; esac
        ;;
      *) die "GS_FORMAT must be deb, rpm or appimage" ;;
    esac
    say "Installed Gateway Soft $TAG"
    echo "    Desktop: start it from the applications menu. Headless: $bin --serve --print-secret"
    ;;
  *)
    die "unsupported system: $OS (Windows: irm https://s00d.github.io/gs-soft/install.ps1 | iex)"
    ;;
esac
