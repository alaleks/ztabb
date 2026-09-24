#!/bin/sh
# ztabb installer: fetches the release built for this machine and puts it where
# the platform expects it.
#
#   curl -fsSL https://raw.githubusercontent.com/alaleks/ztabb/master/install.sh | sh
#
# Everything is inside `main`, which is called on the last line. A download that
# is cut off mid-flight therefore defines a function and stops, instead of
# running half an installer -- the one hazard of piping a script into a shell
# that the script itself can do something about.
#
# Environment:
#   ZTABB_VERSION  tag to install (default: the latest release)
#   ZTABB_PREFIX   where to install (default: /Applications on macOS,
#                  /usr/local or ~/.local on Linux)

set -eu

REPO="alaleks/ztabb"

main() {
    tmp=""
    trap cleanup EXIT INT TERM

    need curl
    platform=$(detect_platform)
    say "Platform:  $platform"

    version=${ZTABB_VERSION:-$(latest_version)}
    [ -n "$version" ] || die "could not work out the latest version; set ZTABB_VERSION to a tag"
    say "Version:   $version"

    case $platform in
        *-macos) asset="ztabb-$platform.zip"; need unzip ;;
        *-linux) asset="ztabb-$platform.tar.gz"; need tar ;;
        *) die "unsupported platform: $platform" ;;
    esac

    base="https://github.com/$REPO/releases/download/$version"
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ztabb.XXXXXX")

    say "Fetching:  $asset"
    fetch "$base/$asset" "$tmp/$asset" \
        || die "no $asset in release $version -- see https://github.com/$REPO/releases"

    verify "$base/checksums.txt" "$tmp" "$asset"

    case $platform in
        *-macos) install_macos "$tmp" "$asset" ;;
        *-linux) install_linux "$tmp" "$asset" ;;
    esac
}

# -- platform ---------------------------------------------------------------

detect_platform() {
    os=$(uname -s)
    arch=$(uname -m)

    case $os in
        Darwin) os=macos ;;
        Linux) os=linux ;;
        MINGW* | MSYS* | CYGWIN* | Windows*)
            die "no Windows binary is published yet -- it builds from source: https://github.com/$REPO" ;;
        *) die "unsupported operating system: $os" ;;
    esac

    case $arch in
        arm64 | aarch64) arch=aarch64 ;;
        x86_64 | amd64) arch=x86_64 ;;
        *) die "unsupported architecture: $arch" ;;
    esac

    # The Linux release is x86_64 only; say so rather than 404ing later.
    [ "$os" = linux ] && [ "$arch" != x86_64 ] &&
        die "no Linux build for $arch yet -- build from source: https://github.com/$REPO"

    echo "$arch-$os"
}

# -- fetching ---------------------------------------------------------------

latest_version() {
    curl -fsSL -m 30 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1
}

# Quiet on failure: every caller prints something more useful than curl's own
# "The requested URL returned error: 404".
fetch() {
    curl -fsL --retry 3 --retry-delay 1 -m 300 -o "$2" "$1" 2>/dev/null
}

# Refuses to install anything whose hash is not the one the release published.
verify() {
    checksums_url=$1
    dir=$2
    file=$3

    if ! fetch "$checksums_url" "$dir/checksums.txt"; then
        die "release has no checksums.txt; refusing to install unverified"
    fi

    want=$(sed -n "s/^\([0-9a-f]\{64\}\)[[:space:]][[:space:]]*\*\{0,1\}$file\$/\1/p" \
        "$dir/checksums.txt" | head -n 1)
    [ -n "$want" ] || die "checksums.txt does not mention $file; refusing to install"

    if command -v sha256sum >/dev/null 2>&1; then
        got=$(sha256sum "$dir/$file" | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        got=$(shasum -a 256 "$dir/$file" | cut -d' ' -f1)
    else
        die "need sha256sum or shasum to verify the download"
    fi

    [ "$want" = "$got" ] || die "checksum mismatch for $file
  expected $want
  got      $got"
    say "Checksum:  ok"
}

# -- installing -------------------------------------------------------------

install_macos() {
    dir=$1
    asset=$2
    prefix=${ZTABB_PREFIX:-/Applications}

    unzip -q "$dir/$asset" -d "$dir/unpacked"
    [ -d "$dir/unpacked/ztabb.app" ] || die "the archive holds no ztabb.app"

    # A downloaded bundle is quarantined, and ztabb is ad-hoc signed rather than
    # signed with a Developer ID, so Gatekeeper would refuse it on first launch.
    xattr -dr com.apple.quarantine "$dir/unpacked/ztabb.app" 2>/dev/null || true

    target="$prefix/ztabb.app"
    if [ -d "$target" ]; then
        running "$target" && die "ztabb is running; quit it and run this again"
        say "Replacing: $target"
    fi

    as_needed rm -rf "$target"
    as_needed cp -R "$dir/unpacked/ztabb.app" "$prefix/"
    # A bundle whose signature is unchanged keeps a stale icon in the Finder.
    as_needed touch "$target"

    say ""
    say "Installed $target"
    say "Open it from Launchpad, or: open -a ztabb"
}

install_linux() {
    dir=$1
    asset=$2

    mkdir -p "$dir/unpacked"
    tar xzf "$dir/$asset" -C "$dir/unpacked"
    [ -f "$dir/unpacked/ztabb" ] || die "the archive holds no ztabb binary"

    if [ -n "${ZTABB_PREFIX:-}" ]; then
        bindir="$ZTABB_PREFIX/bin"
    elif [ -w /usr/local/bin ] || [ "$(id -u)" = 0 ]; then
        bindir=/usr/local/bin
    else
        bindir="$HOME/.local/bin"
    fi

    as_needed mkdir -p "$bindir"
    as_needed cp "$dir/unpacked/ztabb" "$bindir/ztabb"
    as_needed chmod 755 "$bindir/ztabb"

    say ""
    say "Installed $bindir/ztabb"

    case ":$PATH:" in
        *":$bindir:"*) ;;
        *) say "Note: $bindir is not on your PATH." ;;
    esac

    # The Linux build links the system SDL3 rather than carrying its own.
    if command -v ldd >/dev/null 2>&1 && ! ldd "$bindir/ztabb" 2>/dev/null | grep -q 'libSDL3.*=> /'; then
        say ""
        say "SDL3 does not look installed, and this build links the system copy."
        say "Install it with your package manager (libsdl3-0, sdl3, or similar)."
    fi
}

# -- helpers ----------------------------------------------------------------

# Runs a command, re-running it under sudo if the location needs root.
as_needed() {
    if "$@" 2>/dev/null; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || die "cannot write there, and sudo is not available: $*"
    say "Needs root: sudo $*"
    sudo "$@"
}

running() {
    pgrep -f "$1/Contents/MacOS/ztabb" >/dev/null 2>&1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

say() {
    printf '%s\n' "$1"
}

die() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    [ -n "${tmp:-}" ] && [ -d "$tmp" ] && rm -rf "$tmp"
    return 0
}

main "$@"
