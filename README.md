# Android Finder — File Provider

A headless Swift helper for Apple Silicon on macOS 14 or later. It discovers MTP interfaces over USB, then queries each device for accessible storage before registering its Finder location. If the phone switches to No data transfer or disconnects, the location is removed. A busy USB interface is retried without hiding the device mid-transfer. Open the device entry to browse its MTP storage and copy files to the Mac. The sandboxed File Provider extension opens the USB session with libmtp when Finder needs it. On writable storage, Finder can create folders, copy new files to the phone, and rename items. The device location itself is a virtual container. Write operations start inside a storage folder such as Internal storage. Replacing file contents, moving items, and deleting items are unsupported.

## Install and use

1. Install `dist/AndroidFinder-FileProvider.pkg`. It installs the headless `Android Finder.app` bundle and a LaunchAgent for the signed-in GUI session. macOS uses the bundle to discover the File Provider extension.
2. Plug in an unlocked Android phone with a data cable and choose **File transfer** on the phone. If the Mac asks whether to allow the USB accessory, select **Allow**.
3. If Finder asks to enable the provider, follow its prompt. On macOS 15 and later, you can also look under **System Settings → General → Login Items & Extensions → File Providers** for **Android Finder**. On macOS 14, check the **Enable** button in the Finder location.
4. Look under **Finder → Locations**, open the phone, then open **Internal storage** (the name comes from the phone). macOS may group the entry under **Android Finder**. Allow a few seconds for the storage check after switching USB modes. Phones that advertise MTP by name are recognized, as is the Vivo V19's known MTP product ID.

The installer is unsigned and the local app bundle is ad-hoc signed. The package contains our own helper and extension; it does not include MtpMount, WebDAV, or a GUI.

## Finder name and icon

Each File Provider domain uses the connected phone's USB name (`NSFileProviderHideExtensionName` is enabled on the extension so Finder shows the connected device's name in the sidebar while keeping the app bundle named `Android Finder.app`). Individual domain names follow whichever Android devices are connected.

The color bundle icon and monochrome sidebar symbol use the Android robot artwork. The attribution and original SVG are in `file-provider/branding`. The build packages the compiled symbol catalog for Finder.

## Build and verify

Run `./build-file-provider.sh` with the macOS Command Line Tools and pkg-config installed. The script builds the pinned libmtp and libusb dependencies on the first build. It compiles and signs both binaries and creates `dist/AndroidFinder-FileProvider.pkg`. For distribution with a Developer ID certificate, the same script accepts `SIGN_IDENTITY`, `APPLE_TEAM_ID`, `APP_PROFILE`, and `EXTENSION_PROFILE`.

After installation, check detection and the domain registered with macOS:

```sh
helper=$(plutil -extract ProgramArguments.0 raw /Library/LaunchAgents/local.androidfinder.native.plist)
"$helper" --scan
"$helper" --check-storage
"$helper" --status
```

To inspect the background helper's logs, use `log show --last 10m --predicate 'subsystem == "local.androidfinder.provider"'`.

## Uninstall

Run these commands as the signed-in user. Quit other active macOS user sessions first. Read the helper path from the installed LaunchAgent before removing either file. Remove the File Provider domains while the app bundle is still present so Finder can remove the device locations and preserve any unsynced local files.

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

## Legacy WebDAV helper

Mount one Android phone's USB file storage in macOS with a background helper. The installer places a LaunchAgent in `/Library/LaunchAgents`. It runs in each logged-in GUI session and mounts the first available MTP device as a read-only WebDAV volume. Its WebDAV listener is bound to loopback and uses a fresh random password for each connection. The helper and its libraries are installed under `/Library/Application Support/Android Finder`.

### Install and use

These steps apply to the original WebDAV package only. Use an Apple Silicon Mac running macOS 14 Sonoma or later. Homebrew is only needed if you are building from source.

1. Open `dist/AndroidFinder.pkg`. This local build has no Developer ID installer signature. If the graphical installer declines it, install the local package from the project directory with `sudo /usr/sbin/installer -pkg dist/AndroidFinder.pkg -target /`.
2. Unlock your Android phone, plug it in with a USB data cable, and choose **File transfer** in its USB notification. Allow the accessory connection if macOS asks. Quit any other app that is using the phone's MTP connection.
3. Open Finder and look under **Locations**, with **Connected servers** also enabled in Finder's sidebar settings. You can always press **Shift–Command–G** and enter `~/Library/Application Support/Android Finder/Android` to go to the volume directly. If the agent did not start during installation, log out and back in.

Copy files from the phone to your Mac. Eject the volume in Finder or disconnect the cable. If you eject it, reconnect the phone to mount it again. The file listing refreshes as Finder requests new listings.

The helper uses partial MTP reads when the device supports them. For devices that require whole-file downloads, it temporarily stages the requested file in the user's private directory and needs enough disk space for that file.

### Troubleshoot

The agent log is at `~/Library/Application Support/Android Finder/agent.log`.

```sh
launchctl print "gui/$(id -u)/local.androidfinder.agent"
```

If the device never appears, check that macOS can see it under **System Information → USB**. Reconnect the unlocked phone and select **File transfer** again. The Finder mount only exposes storage that Android makes available over MTP.

### Remove

If you are removing the original WebDAV package and have not upgraded to File Provider, stop the agent, then remove the installed files and receipt. Log out any other active GUI account first.

```sh
launchctl bootout "gui/$(id -u)/local.androidfinder.agent"
sudo rm -f /Library/LaunchAgents/local.androidfinder.agent.plist
sudo rm -rf '/Library/Application Support/Android Finder'
sudo pkgutil --forget local.androidfinder
```

The private log directory under your home Library can be moved to Trash once the mount has ejected.

### Build and test

Install the Xcode Command Line Tools, Go 1.26 or later, and pkg-config, then run:

```sh
brew install go pkgconf
ANDROID_FINDER_TEST_MOUNT=1 ./build.sh
```

The build script verifies and compiles the pinned libusb and libmtp sources, bundles the libraries and their corresponding source archives, builds the helper, runs tests, and writes `dist/AndroidFinder.pkg`. The native mount test mounts simulated Android storage through macOS, reads a file, verifies that writes are rejected, and unmounts the fixture. The installer and helper require a real Android device in File transfer mode to test the USB path end to end.
