#!/bin/sh
# Builds ztabb from this checkout and installs it into /Applications.
#
# `install.sh` at the repository root fetches a published release; this one is
# for the tree in front of you, which is what you want after changing
# something. macOS only: the bundle is what gives the app its icon in the Dock,
# Finder and Launchpad, since a bare executable borrows the terminal's.
#
#   tools/install-macos.sh          build, check, install
#   tools/install-macos.sh --open   and launch it afterwards
#
# ZTABB_PREFIX installs somewhere other than /Applications.
set -eu

main() {
    # Parsed here rather than at the top of the file: a shell only knows a
    # function once it has read past it, and `die` lives below.
    open_after=no
    for arg in "$@"; do
        case $arg in
            --open) open_after=yes ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) die "unknown argument: $arg" ;;
        esac
    done

    [ "$(uname -s)" = Darwin ] || die "macOS only; on Linux build with 'zig build' and run zig-out/bin/ztabb"
    need zig

    # The repository root, whichever directory this was run from.
    root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
    cd "$root"

    prefix=${ZTABB_PREFIX:-/Applications}
    target="$prefix/ztabb.app"

    # Replacing a bundle underneath a running copy leaves it half itself: the
    # process keeps the old executable mapped while its resources are gone.
    if pgrep -f "$target/Contents/MacOS/ztabb" >/dev/null 2>&1; then
        die "ztabb is running from $target -- quit it first"
    fi

    built=$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo "unknown")
    say "Building   $built (ReleaseFast)"
    # Quiet when it works, and everything when it does not. The bundle step
    # rewrites the SDL3 load path and re-signs afterwards, and install_name_tool
    # warns about the signature it is about to invalidate -- which would read
    # like a problem in an installer that is otherwise silent.
    log=$(mktemp "${TMPDIR:-/tmp}/ztabb-build.XXXXXX")
    if ! zig build bundle -Doptimize=ReleaseFast >"$log" 2>&1; then
        cat "$log" >&2
        rm -f "$log"
        die "the bundle failed to build"
    fi
    rm -f "$log"

    app="zig-out/ztabb.app"
    bin="$app/Contents/MacOS/ztabb"
    check "$app" "$bin"

    if [ -d "$target" ]; then
        say "Replacing  $target"
    fi
    as_needed mkdir -p "$prefix"
    as_needed rm -rf "$target"
    as_needed cp -R "$app" "$prefix/"
    # A bundle whose signature is unchanged keeps a stale icon in the Finder's
    # cache; touching it is what makes the new one show up.
    as_needed touch "$target"

    say ""
    say "Installed  $target"
    say "           built from $built"
    say "           open it from Launchpad, or: open -a ztabb"

    if [ "$open_after" = yes ]; then
        say ""
        say "Opening..."
        open -a "$target"
    fi
}

# The comment block at the top of this file, minus the hashes. Taken from the
# file rather than written twice, so it cannot drift from it.
usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

# The same checks release.sh makes before it will tag a build. A bundle that
# fails any of them is not one to install.
check() {
    app=$1
    bin=$2

    [ -f "$bin" ] || die "the bundle has no executable"
    [ -f "$app/Contents/Resources/ztabb.icns" ] || die "the bundle has no icon"

    # A Homebrew path here means the app breaks the moment the formula is
    # upgraded or removed, which is the whole reason the bundle carries SDL3.
    if otool -L "$bin" | grep -qE '/opt/homebrew|/usr/local/Cellar'; then
        otool -L "$bin" >&2
        die "the bundle links a Homebrew path instead of its own copy of SDL3"
    fi

    # Rewriting the load paths invalidates whatever the linker signed, and an
    # unsigned binary will not start on Apple Silicon.
    codesign -v "$app" 2>/dev/null || die "the bundle is not signed"

    say "Checked    own SDL3, icon present, signature valid"
}

# Runs a command, re-running it under sudo only if the location needs root.
as_needed() {
    if "$@" 2>/dev/null; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || die "cannot write there, and sudo is not available: $*"
    say "Needs root: sudo $*"
    sudo "$@"
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

main "$@"
