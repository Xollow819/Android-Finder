#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -m)" != arm64 ]]; then
    echo "Build Android Finder on an Apple Silicon Mac." >&2
    exit 1
fi

version=1.0.0
location_name="Android Finder"
bundle_id=local.androidfinder.native
extension_id="$bundle_id.fileprovider"
identity=${SIGN_IDENTITY:--}
team=${APPLE_TEAM_ID:-}
group="group.$bundle_id"

if [[ "$identity" != - ]]; then
    : "${APP_PROFILE:?Provide a macOS provisioning profile for the app}"
    : "${EXTENSION_PROFILE:?Provide a macOS provisioning profile for the extension}"
    if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "Set APPLE_TEAM_ID to your Apple Developer team ID." >&2
        exit 1
    fi
    group="$team.$bundle_id"
fi

pkg_config=${PKG_CONFIG:-$(command -v pkg-config || command -v /opt/homebrew/bin/pkg-config || true)}
build="$PWD/.build"
prefix="$build/prefix"
export MACOSX_DEPLOYMENT_TARGET=14.0
jobs=$(sysctl -n hw.logicalcpu)

mkdir -p "$build/downloads" "$build/source" dist

fetch() {
    local archive="$build/downloads/${1##*/}"
    if [[ ! -f "$archive" ]]; then
        curl -fL --retry 2 "$1" -o "$archive.part"
        mv "$archive.part" "$archive"
    fi
    echo "$2  $archive" | shasum -a 256 -c -
    tar -xf "$archive" -C "$build/source"
}

build_library() {
    local name=$1
    shift
    echo "Building $name"
    if ! (
        cd "$build/source/$name"
        if [[ -f Makefile ]]; then make clean || exit; fi
        ./configure --prefix="$prefix" --enable-static --disable-shared --disable-dependency-tracking "$@" &&
            make -j"$jobs" &&
            make install
    ) >"$build/$name.log" 2>&1; then
        tail -80 "$build/$name.log" >&2
        exit 1
    fi
}

probe_hash=$(shasum -a 256 file-provider/libmtp-probe.patch | cut -d ' ' -f 1)
if [[ ! -f "$prefix/lib/libmtp.a" || ! -f "$prefix/lib/libusb-1.0.a" || "$(cat "$build/native-mtp-probe.hash" 2>/dev/null || :)" != "$probe_hash" ]]; then
    : "${pkg_config:?Install pkg-config (brew install pkgconf) to build libmtp from source}"
    fetch https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2 \
        fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
    fetch https://downloads.sourceforge.net/project/libmtp/libmtp/1.1.23/libmtp-1.1.23.tar.gz \
        74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed

    patch -d "$build/source/libmtp-1.1.23" -p0 < file-provider/libmtp-probe.patch
    build_library libusb-1.0.30
    PKG_CONFIG="$pkg_config" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" build_library libmtp-1.1.23 --disable-mtpz
    echo "$probe_hash" > "$build/native-mtp-probe.hash"
fi

work=$(mktemp -d "$build/native-provider.XXXXXX")
trap 'rm -rf "$work"' EXIT
root="$work/root"
app="$root/Applications/$location_name.app"
extension="$app/Contents/PlugIns/AndroidFinderProvider.appex"
install -d -m 0755 "$root" "$app/Contents/MacOS" "$extension/Contents/MacOS" \
    "$app/Contents/Resources" "$extension/Contents/Resources" "$work/AndroidRobot.iconset"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleExecutable</key><string>AndroidFinder</string>
    <key>CFBundleName</key><string>Android Finder</string>
    <key>CFBundleIconFile</key><string>AndroidRobot.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>11</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST

cat > "$extension/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>$extension_id</string>
    <key>CFBundleExecutable</key><string>AndroidFinderProvider</string>
    <key>CFBundleName</key><string>Android Finder</string>
    <key>CFBundleIconFile</key><string>AndroidRobot.icns</string>
    <key>CFBundleIcons</key><dict>
        <key>CFBundlePrimaryIcon</key><dict>
            <key>CFBundleSymbolName</key><string>AndroidRobot</string>
        </dict>
    </dict>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleVersion</key><string>11</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSExtension</key><dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.fileprovider-nonui</string>
        <key>NSExtensionPrincipalClass</key><string>AndroidFinderProvider</string>
        <key>NSExtensionFileProviderDocumentGroup</key><string>$group</string>
        <key>NSExtensionFileProviderSupportsEnumeration</key><true/>
        <key>NSFileProviderHideExtensionName</key><true/>
    </dict>
</dict></plist>
PLIST

for bundle in "$app" "$extension"; do
    plutil -insert CFBundleDisplayName -string "$location_name" "$bundle/Contents/Info.plist"
    plutil -replace CFBundleName -string "$location_name" "$bundle/Contents/Info.plist"
    install -m 0644 file-provider/branding/NOTICE.txt "$bundle/Contents/Resources/AndroidRobot-NOTICE.txt"
done
xcrun swift file-provider/branding/RenderIcon.swift file-provider/branding/AndroidRobot.svg "$work/AndroidRobot.iconset"
iconutil -c icns "$work/AndroidRobot.iconset" -o "$work/AndroidRobot.icns"
for bundle in "$app" "$extension"; do
    install -m 0644 "$work/AndroidRobot.icns" file-provider/branding/Assets.car "$bundle/Contents/Resources/"
done

# PlistBuddy handles literal dots in entitlement names.
entitlements() {
    local file="$1" identifier="$2" sandbox="$3"
    local plist=/usr/libexec/PlistBuddy
    "$plist" -c 'Add :com.apple.security.application-groups array' \
        -c "Add :com.apple.security.application-groups:0 string $group" "$file" >/dev/null
    if [[ "$sandbox" = yes ]]; then
        "$plist" -c 'Add :com.apple.security.app-sandbox bool true' \
            -c 'Add :com.apple.security.device.usb bool true' "$file"
    fi
    if [[ "$identity" != - ]]; then
        "$plist" -c "Add :com.apple.application-identifier string $team.$identifier" \
            -c "Add :com.apple.developer.team-identifier string $team" "$file"
    fi
}

mtp_flags=(-import-objc-header file-provider/MTPBridge.h -I "$prefix/include")
mtp_libraries=("$prefix/lib/libmtp.a" "$prefix/lib/libusb-1.0.a"
    -liconv -framework IOKit -framework Security -framework CoreFoundation)
xcrun swiftc -O -target arm64-apple-macos14 -parse-as-library "${mtp_flags[@]}" \
    file-provider/Helper.swift file-provider/USB.swift file-provider/Storage.swift \
    "${mtp_libraries[@]}" -o "$app/Contents/MacOS/AndroidFinder"
xcrun clang -target arm64-apple-macos14 -c file-provider/ExtensionMain.c -o "$work/provider-entry.o"
xcrun swiftc -O -target arm64-apple-macos14 -parse-as-library -application-extension -emit-executable \
    "${mtp_flags[@]}" file-provider/Provider.swift file-provider/Storage.swift file-provider/USB.swift \
    "$work/provider-entry.o" "${mtp_libraries[@]}" \
    -o "$extension/Contents/MacOS/AndroidFinderProvider"
license="$root/Library/Application Support/Android Finder/Third-Party"
install -d -m 0755 "$license"
install -m 0644 "$build/downloads/libmtp-1.1.23.tar.gz" "$build/downloads/libusb-1.0.30.tar.bz2" file-provider/libmtp-probe.patch "$license/"
install -m 0644 "$build/source/libmtp-1.1.23/COPYING" "$license/libmtp-LICENSE"
install -m 0644 "$build/source/libusb-1.0.30/COPYING" "$license/libusb-LICENSE"

entitlements "$work/helper.entitlements" "$bundle_id" no
entitlements "$work/provider.entitlements" "$extension_id" yes
if [[ "$identity" != - ]]; then
    install -m 0644 "$APP_PROFILE" "$app/Contents/embedded.provisionprofile"
    install -m 0644 "$EXTENSION_PROFILE" "$extension/Contents/embedded.provisionprofile"
fi
codesign --force --options runtime --sign "$identity" --entitlements "$work/provider.entitlements" "$extension"
codesign --force --options runtime --sign "$identity" --entitlements "$work/helper.entitlements" "$app"
codesign --verify --strict --deep "$app"

install -d -m 0755 "$root/Library/LaunchAgents"
agent="$root/Library/LaunchAgents/$bundle_id.plist"
install -m 0644 package/LaunchAgent.plist "$agent"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 /Applications/$location_name.app/Contents/MacOS/AndroidFinder" "$agent"
test "$(plutil -extract ProgramArguments.1 raw "$agent")" = --agent
if plutil -extract ProgramArguments.2 raw "$agent" >/dev/null 2>&1; then
    echo "Unexpected extra LaunchAgent argument." >&2
    exit 1
fi
pkgbuild --analyze --root "$root" "$work/components.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$work/components.plist"
component=AndroidFinder-FileProvider-component.pkg
pkgbuild --root "$root" --component-plist "$work/components.plist" --ownership recommended \
    --install-location / --scripts package/scripts --identifier "$bundle_id" --version "$version" "$work/$component"
productbuild --distribution package/Distribution.xml --package-path "$work" dist/AndroidFinder-FileProvider.pkg
