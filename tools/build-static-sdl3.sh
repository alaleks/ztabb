#!/bin/sh
# Build the SDL3 archive used by single-binary release builds.
set -eu

SDL_TAG=release-3.4.18
SDL_COMMIT=829a65d769d935c4852f8159e964312c0957260a

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
prefix="$repo/zig-out/sdl3-static"
tmp=$(mktemp -d)
trap 'if [ -n "$tmp" ]; then rm -rf "$tmp"; fi' EXIT HUP INT TERM

for tool in git cmake ninja; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf '%s is required\n' "$tool" >&2
        exit 1
    }
done

sdl_src=
attempt=1
while [ "$attempt" -le 3 ]; do
    sdl_src="$tmp/SDL-$attempt"
    if git -c http.version=HTTP/1.1 clone --quiet --depth 1 --branch "$SDL_TAG" \
        https://github.com/libsdl-org/SDL.git "$sdl_src"; then
        break
    fi
    if [ "$attempt" -eq 3 ]; then
        printf 'SDL3 clone failed after 3 attempts\n' >&2
        exit 1
    fi
    printf 'Retrying SDL3 clone (%s/3)...\n' "$attempt" >&2
    sleep "$attempt"
    attempt=$((attempt + 1))
done
actual=$(git -C "$sdl_src" rev-parse HEAD)
if [ "$actual" != "$SDL_COMMIT" ]; then
    printf 'SDL3 tag moved: expected %s, got %s\n' "$SDL_COMMIT" "$actual" >&2
    exit 1
fi

cmake -S "$sdl_src" -B "$tmp/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON \
    -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF
cmake --build "$tmp/build" --parallel 4
cmake --install "$tmp/build"
test -f "$prefix/lib/libSDL3.a"
printf 'Static SDL3: %s\n' "$prefix/lib/libSDL3.a"
