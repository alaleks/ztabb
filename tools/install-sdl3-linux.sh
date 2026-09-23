#!/bin/sh
# Gets SDL3 onto a Linux machine for building ztabb.
#
# SDL3 is recent enough that older distributions have no package for it, so
# this tries the package manager first and builds from source when that comes
# up empty. Used by CI and usable by hand.
set -eu

SDL_TAG="${SDL_TAG:-release-3.2.24}"

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists sdl3; then
    echo "SDL3 already present: $(pkg-config --modversion sdl3)"
    exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    if sudo apt-get install -y -qq libsdl3-dev 2>/dev/null; then
        echo "SDL3 from apt: $(pkg-config --modversion sdl3)"
        exit 0
    fi
    echo "no libsdl3-dev package; building from source"
    sudo apt-get install -y -qq cmake ninja-build build-essential git \
        libx11-dev libxext-dev libwayland-dev wayland-protocols \
        libxkbcommon-dev libegl1-mesa-dev
fi

tmp=$(mktemp -d)
git clone --depth 1 --branch "$SDL_TAG" https://github.com/libsdl-org/SDL.git "$tmp/SDL"
cmake -S "$tmp/SDL" -B "$tmp/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DSDL_STATIC=OFF -DSDL_TEST_LIBRARY=OFF
cmake --build "$tmp/build" --parallel
sudo cmake --install "$tmp/build"
sudo ldconfig
echo "SDL3 built from $SDL_TAG: $(pkg-config --modversion sdl3)"
