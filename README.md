<p align="center">
  <img src="file-provider/branding/AndroidRobot.svg" width="140" height="140" alt="Android Finder logo">
</p>

<h1 align="center">Android Finder</h1>

<p align="center"><b>Native Android MTP inside macOS Finder, with zero third-party bloat.</b><br>
Plug in your Android phone over USB and browse, copy, rename, and create folders directly in Finder<br>
using a sandboxed Apple Silicon File Provider extension powered by <code>libmtp</code> and <code>libusb</code>.</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-macOS%2014%2B-F05138?logo=swift&logoColor=white" alt="Swift on macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-2563EB?logo=apple&logoColor=white" alt="Apple Silicon arm64">
  <a href="https://github.com/Xollow819/Android-Finder/releases"><img src="https://img.shields.io/github/v/release/Xollow819/Android-Finder?color=E2862A&label=release" alt="Latest release"></a>
  <a href="https://github.com/Xollow819/Android-Finder"><img src="https://img.shields.io/github/stars/Xollow819/Android-Finder?style=social" alt="GitHub stars"></a>
</p>

<p align="center">
  <a href="https://github.com/Xollow819/Android-Finder/releases/latest"><img src="https://img.shields.io/badge/Download_v1.0_.pkg-2563EB?style=for-the-badge&logo=apple&logoColor=white" alt="Download v1.0 .pkg"></a>
</p>

<p align="center">
  <b><a href="#quick-start">Install</a></b> · <a href="https://github.com/Xollow819/Android-Finder/releases">Releases</a> · <a href="#how-it-works">How it works</a> · <a href="#build-from-source">Build</a> · <a href="#troubleshooting">Troubleshooting</a> · <a href="#uninstall">Uninstall</a>
</p>

<table>
  <tr>
    <td width="25%" valign="top">
      <b>Detect</b><br>
      A headless LaunchAgent watches IOKit <code>IOUSBHostInterface</code> for MTP devices and known USB product IDs.
    </td>
    <td width="25%" valign="top">
      <b>Verify</b><br>
      Before registering a Finder location, the helper verifies accessible MTP storage so unready phones stay hidden.
    </td>
    <td width="25%" valign="top">
      <b>Mount</b><br>
      A sandboxed <code>NSFileProviderReplicatedExtension</code> exposes the phone directly under <b>Finder → Locations</b>.
    </td>
    <td width="25%" valign="top">
      <b>Transfer</b><br>
      Copy files to and from your Mac, create folders, and rename items in Finder, with busy-USB retry mid-transfer.
    </td>
  </tr>
</table>

**Plug in your Android phone and use Finder natively.** macOS does not ship built-in MTP support in Finder. `android-finder` bridges USB MTP devices straight into macOS's native File Provider framework without background WebDAV servers, FUSE kernel extensions, or a heavy Electron/GUI wrapper.

| Operation in Finder | Supported | Notes |
| --- | :---: | --- |
| Browse storage & folders | Yes | Reads device storage labels (e.g. `Internal storage`) dynamically |
| Copy files from phone to Mac | Yes | Streamed on demand via `libmtp` inside the sandboxed extension |
| Copy new files from Mac to phone | Yes | Inside writable storage folders (device root is a virtual container) |
| Create folders & rename items | Yes | Supported on writable MTP storage |
| Replace contents, move, or delete | No | Currently unsupported by the provider |
| Hot-plug & mode switching | Yes | Automatically removes the location on disconnect or *No data transfer* |

> `android-finder` is an independent open-source project. "Android" is a trademark of Google LLC, and "macOS" and "Finder" are trademarks of Apple Inc.

> [!NOTE]
> The prebuilt installer is unsigned and the local app bundle is ad-hoc signed. If macOS Gatekeeper blocks opening the `.pkg` directly, install it from Terminal using `sudo /usr/sbin/installer` (shown below).

## Quick start

1. Download **`AndroidFinder-FileProvider-1.0.pkg`** from [GitHub Releases](https://github.com/Xollow819/Android-Finder/releases/latest) and install it:

```sh
sudo /usr/sbin/installer -pkg ~/Downloads/AndroidFinder-FileProvider-1.0.pkg -target /
```

2. Unlock your Android phone, connect it with a USB data cable, and select **File transfer** in the USB notification. If macOS prompts to allow the accessory, select **Allow**.
3. If Finder asks to enable the File Provider extension, confirm it. You can also check **System Settings → General → Login Items & Extensions → File Providers** and enable **Android Finder** (on macOS 14, click **Enable** inside the Finder location).
4. Open **Finder → Locations**, select your phone, and open **Internal storage**.

## How it works

`android-finder` runs two lightweight native binaries inside `/Applications/Android Finder.app`:

- **Background Helper (`AndroidFinder`)** — Launched at login via `/Library/LaunchAgents/local.androidfinder.native.plist`. It scans `IOUSBHostInterface` for MTP-capable devices (including explicit MTP interfaces and known product IDs like the Vivo V19), verifies readable storage, and registers or removes `NSFileProviderDomain` entries dynamically.
- **Sandboxed Extension (`AndroidFinderProvider.appex`)** — Implements `NSFileProviderReplicatedExtension` with App Sandbox and USB device entitlements (`com.apple.security.device.usb`). Finder invokes it on demand to enumerate folders, download files, upload new files, create directories, and rename items via statically linked `libmtp` and `libusb`.

### Finder appearance

Each connected device registers its own File Provider domain using its USB product name (`NSFileProviderHideExtensionName` is enabled so Finder displays the phone's name directly in the sidebar). Both the bundle icon and Finder's monochrome sidebar symbol are compiled from the Android robot SVG in [`file-provider/branding/`](file-provider/branding/).

## Build from source

Requires an **Apple Silicon Mac (arm64)** running **macOS 14 Sonoma or later** with **Xcode Command Line Tools** and `pkg-config` installed (`brew install pkgconf`):

```sh
./build.sh
```

On the first run, `./build.sh` downloads, verifies (SHA-256), patches (`file-provider/libmtp-probe.patch`), and statically compiles `libusb-1.0.30` and `libmtp-1.1.23`, builds both Swift/C binaries, generates the app icon, signs the bundle, and outputs `dist/AndroidFinder-FileProvider.pkg`.

For distribution signing with a Developer ID certificate, pass your signing variables:

```sh
SIGN_IDENTITY="Developer ID Application: ..." \
APPLE_TEAM_ID="XXXXXXXXXX" \
APP_PROFILE="/path/to/app.provisionprofile" \
EXTENSION_PROFILE="/path/to/extension.provisionprofile" \
./build.sh
```

## Troubleshooting

Check connected USB MTP detection, storage readiness, and registered Finder domains from Terminal:

```sh
helper=$(plutil -extract ProgramArguments.0 raw /Library/LaunchAgents/local.androidfinder.native.plist)
"$helper" --scan
"$helper" --check-storage
"$helper" --status
```

Inspect live logs from the background helper:

```sh
log show --last 10m --predicate 'subsystem == "local.androidfinder.provider"'
```

## Uninstall

Run these commands as the signed-in user (quit any other active macOS GUI sessions first). Removing domains while the app bundle is still present lets Finder clean up device locations and preserve any unsynced local files:

```sh
agent=/Library/LaunchAgents/local.androidfinder.native.plist
helper=$(plutil -extract ProgramArguments.0 raw "$agent") || exit 1
app=${helper%/Contents/MacOS/AndroidFinder}
launchctl bootout "gui/$(id -u)/local.androidfinder.native" 2>/dev/null || true
"$helper" --remove-domains || exit 1
pluginkit -r "$app/Contents/PlugIns/AndroidFinderProvider.appex"
sudo rm -f "$agent"
sudo rm -rf "$app"
sudo pkgutil --forget local.androidfinder.native
```

## Third-Party & Attribution

- **Android Robot Artwork** — Reproduced/modified from work created and shared by Google under the [Creative Commons 3.0 Attribution License](https://creativecommons.org/licenses/by/3.0/) (see [`file-provider/branding/NOTICE.txt`](file-provider/branding/NOTICE.txt)).
- **libmtp & libusb** — Pinned static builds of `libmtp-1.1.23` and `libusb-1.0.30` (with [`file-provider/libmtp-probe.patch`](file-provider/libmtp-probe.patch)); source archives and licenses are bundled under `/Library/Application Support/Android Finder/Third-Party`.
