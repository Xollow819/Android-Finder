#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -m)" != arm64 ]]; then
    echo "Build Android Finder on an Apple Silicon Mac." >&2
    exit 1
fi
pkg_config=${PKG_CONFIG:-$(command -v pkg-config)}
build="$PWD/.build"
prefix="$build/prefix"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CGO_ENABLED=1
jobs=$(sysctl -n hw.logicalcpu)
static_flag=--disable-static
if [[ "${1:-}" = "--static-libraries-only" ]]; then
    static_flag=--enable-static
fi
mkdir -p "$build/downloads" "$build/source" "$build/bin" dist

fetch() {
    local archive="$build/downloads/${1##*/}"
    if [[ ! -f "$archive" ]]; then
        curl -fL --retry 2 "$1" -o "$archive.part"
        mv "$archive.part" "$archive"
    fi
    echo "$2  $archive" | shasum -a 256 -c -
    tar -xf "$archive" -C "$build/source"
}

fetch https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2 \
    fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
fetch https://downloads.sourceforge.net/project/libmtp/libmtp/1.1.23/libmtp-1.1.23.tar.gz \
    74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed

build_library() {
    local name=$1
    shift
    echo "Building $name"
    if ! (
        cd "$build/source/$name"
        if [[ -f Makefile ]]; then make clean || exit; fi
        ./configure --prefix="$prefix" "$static_flag" --disable-dependency-tracking "$@" &&
            make -j"$jobs" &&
            make install
    ) >"$build/$name.log" 2>&1; then
        tail -80 "$build/$name.log" >&2
        exit 1
    fi
}

if [[ "${1:-}" = "--static-libraries-only" ]]; then
    patch -d "$build/source/libmtp-1.1.23" -p0 < file-provider/libmtp-probe.patch
fi
build_library libusb-1.0.30
PKG_CONFIG="$pkg_config" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" build_library libmtp-1.1.23 --disable-mtpz

bin="$build/bin"
install -m 0755 "$prefix/lib/libmtp.9.dylib" "$prefix/lib/libusb-1.0.0.dylib" "$bin"
install_name_tool -id @loader_path/libmtp.9.dylib \
    -change "$prefix/lib/libusb-1.0.0.dylib" @loader_path/libusb-1.0.0.dylib "$bin/libmtp.9.dylib"
install_name_tool -id @loader_path/libusb-1.0.0.dylib "$bin/libusb-1.0.0.dylib"
codesign --force --sign - "$bin/libmtp.9.dylib" "$bin/libusb-1.0.0.dylib"
if [[ "${1:-}" = "--static-libraries-only" ]]; then
    exit 0
fi
go_bin=${GO:-$(command -v go)}

export CGO_CFLAGS="-I$prefix/include -I$prefix/include/libusb-1.0"
export CGO_LDFLAGS="$bin/libmtp.9.dylib $bin/libusb-1.0.0.dylib"

"$go_bin" build -trimpath -ldflags='-s -w' -o "$bin/androidfinder" .
codesign --force --sign - "$bin/androidfinder"
"$go_bin" test -c -o "$bin/androidfinder.test" .
"$bin/androidfinder.test" -test.v -test.timeout=45s

root=$(mktemp -d "$build/pkg-root.XXXXXX")
trap 'rm -rf "$root"' EXIT
chmod 0755 "$root"
support="$root/Library/Application Support/Android Finder"
install -d -m 0755 "$support/bin" "$support/Third-Party" "$root/Library/LaunchAgents"
install -m 0755 "$bin/androidfinder" "$bin/libmtp.9.dylib" "$bin/libusb-1.0.0.dylib" "$support/bin"
install -m 0644 package/local.androidfinder.agent.plist "$root/Library/LaunchAgents/"
install -m 0644 "$build/downloads/libusb-1.0.30.tar.bz2" "$build/downloads/libmtp-1.1.23.tar.gz" "$support/Third-Party/"
install -m 0644 "$build/source/libmtp-1.1.23/COPYING" "$support/Third-Party/libmtp-LICENSE"
install -m 0644 "$build/source/libusb-1.0.30/COPYING" "$support/Third-Party/libusb-LICENSE"
net_source=$("$go_bin" list -m -f '{{.Dir}}' golang.org/x/net)
install -m 0644 "$net_source/LICENSE" "$support/Third-Party/golang-x-net-LICENSE"
install -m 0644 "$net_source/PATENTS" "$support/Third-Party/golang-x-net-PATENTS"
xattr -cr "$root"
COPYFILE_DISABLE=1 pkgbuild --root "$root" --ownership recommended --scripts package/scripts \
    --install-location / --identifier local.androidfinder --version 0.1.0 "$build/AndroidFinder-component.pkg"
productbuild --distribution package/Distribution.xml --package-path "$build" dist/AndroidFinder.pkg
