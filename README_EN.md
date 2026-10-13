# ACU

[简体中文](README.md) | [Changelog](CHANGELOG.md)

ACU (Automation / Agent Continuity Utility) is a macOS menu bar utility
that provides an application-level simulated lock screen while UI automation
clients are running:

- Slightly moves and restores the pointer while idle to reduce automatic
  system locking caused by inactivity.
- Can keep the system awake without displaying a shield or intercepting input.
- Covers every display with a full-screen protection layer.
- Blocks physical input while allowing software-generated input without an
  allowlist.
- Unlocks through native macOS Touch ID or system password authentication.

ACU is not the macOS system lock screen. It does not protect against process
termination, administrator access, or machine restarts.
When macOS enters its real lock screen, ACU automatically dismisses its simulated lock screen so the overlay is gone after system unlock. ACU does not attempt to unlock macOS.

The interface supports English and Simplified Chinese and follows the preferred
language configured in macOS. Restart ACU after changing the language.

## Homebrew Installation

```sh
brew tap rectcircle/acu https://github.com/rectcircle/acu
brew install --cask rectcircle/acu/acu
/usr/bin/xattr -dr com.apple.quarantine /Applications/ACU.app
```

## Manual Installation

Starting with the next release, download
`ACU-<version>-macos-universal.dmg` from the
[GitHub Releases page](https://github.com/rectcircle/acu/releases), then
open it and drag `ACU.app` onto the `Applications` shortcut. Each release will also include the matching `.tar.gz` archive.
The app uses an ad-hoc signature; the disk image is unsigned, and neither
is notarized by Apple. If macOS blocks the installer or app, only allow it after
verifying that you trust the release artifacts. You can remove the app's quarantine with:

```sh
/usr/bin/xattr -dr com.apple.quarantine /Applications/ACU.app
```

Upgrade to the latest version:

```sh
brew upgrade --cask rectcircle/acu/acu
/usr/bin/xattr -dr com.apple.quarantine /Applications/ACU.app
```

Current release builds use an ad-hoc signature and are not notarized by Apple.
The second command explicitly uses the macOS system `/usr/bin/xattr` to
recursively remove quarantine only from ACU, bypassing Gatekeeper's first-launch
assessment for this app. It does not disable Gatekeeper globally or grant
permissions such as Accessibility. The Cask pins both the version and SHA-256
checksum, but this command should still be used only when you trust this
repository and its release artifacts.

If you do not trust the prebuilt artifact, do not remove quarantine. Ask a code
agent to review the source, especially `Casks/acu.rb`, `internal/macos`, and
`scripts/build-app.sh`, then build locally from a fixed tag:

```sh
git clone https://github.com/rectcircle/acu.git
cd acu
git checkout v0.1.3
go test ./...
./scripts/build-app.sh
open "build/ACU.app"
```

A local build regenerates the executable and applies an ad-hoc signature. It
normally does not carry the quarantine attribute applied to downloaded apps.

## Build

Requires macOS 15 or later, Go 1.22 or later, and Xcode Command Line Tools.

```sh
./scripts/build-app.sh
open "build/ACU.app"
```

Build a release archive and drag-and-drop DMG that support both Apple Silicon
and Intel Macs:

```sh
./scripts/package-release.sh 0.1.3
```

Pushing a tag such as `v0.1.5` runs tests, builds
`ACU-<version>-macos-universal.tar.gz`, `ACU-<version>-macos-universal.dmg`,
their SHA-256 files, and creates a **draft release**. This does not publish the
release or update Homebrew. Release notes come from the matching bilingual section in
`CHANGELOG.md`; the build fails if that version is missing.

After the user downloads and verifies the draft's DMG and archive, publish
only with the user's explicit authorization. Then open **Actions → Release → Run
workflow**, select `main`, and enter the tag (for example, `v0.1.5`) in `version`.
The workflow verifies both SHA-256 values, publishes the reviewed assets without
rebuilding, and updates the Homebrew Cask (which uses the `.tar.gz` archive). Tag builds
cannot replace public release assets; fixes need a new version tag. Publishing
an older version does not downgrade the Cask or mark that release as latest.

On first use, grant ACU access under System Settings > Privacy & Security >
Accessibility. This permission normally covers the event monitoring and
posting required by the simulated lock screen. Grant Input Monitoring only if
Permission Diagnostics still reports that input events cannot be monitored.
ACU prompts for an immediate restart after detecting the permission. If the
prompt does not appear, quit and reopen ACU manually.

To prevent only automatic system locking, select "Prevent System Lock Only"
from the menu. This mode does not display the simulated lock screen, intercept
physical input, or require authentication to stop. Select the item again to
disable it. Enabling the simulated lock screen or using its shortcut while this
mode is active temporarily switches to full protection and restores
"Prevent System Lock Only" after the simulated lock screen is dismissed.

Half-closed lid protection is enabled by default. It can be disabled from the
menu, and its trigger angle can be set to `30°`, `45°`, or `60°` (default:
`45°`). Protection starts after the lid remains below the threshold for two
seconds. Opening it to five degrees above the threshold automatically displays
Touch ID or system password authentication. Closing the lid completely while
an external display is connected, or when closing the lid locks the system
session, does not trigger protection. Protection will not trigger later until
the lid has been fully reopened. This feature requires a MacBook with a
compatible hinge-angle sensor. Hold `Option` while opening the menu and select
"Permission Diagnostics" to inspect the current angle or unavailable status.

"Bluetooth Departure Lock" can use a paired device as a presence probe. ACU
initiates a connection when the feature is enabled or a device is selected,
then retries every 20 seconds if needed. A stable connection arms protection;
after a disconnect notification, ACU checks for recovery during a 3-second
grace period before showing the simulated lock screen. After authentication,
connection attempts resume and a stable connection rearms protection. The
device list is deduplicated by Bluetooth address and shows each address to
distinguish devices with the same name. Connection and reconnection support
depends on macOS and the Bluetooth device; ACU must remain running for this
feature.

For initial validation, hold `Option` while clicking the menu bar icon, then
select "Test Simulated Lock Screen (Stops After 15 Seconds)." "Permission
Diagnostics" is also located in this hidden menu. Test mode uses the complete
protection layer and input interception. The shield displays the remaining
time, and Guardian removes it automatically after 15 seconds. During regular
protection, press physical Enter to open native macOS authentication. The
protection ends only after successful authentication.

The simulated lock screen uses the current system wallpaper by default. Select
"Simulated Lock Screen Background" to switch to black. System background mode
supports video and standard image wallpapers, but not generated wallpapers,
which fall back to black. ACU reuses downloaded system videos when available;
otherwise, it displays the first frame while caching the video in the
background. Standard images are displayed directly. The protection message
moves slightly every 60 seconds to avoid leaving static text on the same pixels.

The default global shortcut is `Control+Option+Command+L` and can only enable
the simulated lock screen. Choose another preset or disable it under
"Activation Shortcut." The shortcut cannot unlock protection.

Selecting "Launch at Login" registers ACU as a login item for the current user.
If the item was disabled in System Settings, the menu indicates that system
approval is required and opens General > Login Items & Extensions so it can be
enabled.

If physical input interception cannot be restored, ACU displays an error dialog
above the shield. Use the dialog to authenticate and safely exit protection, or
keep the shield active.

## Development Checks

```sh
go test ./...
go vet ./...
```

See [document](document/README.md) for product requirements and technical
constraints.

## License

[MIT License](LICENSE)

## Logs

ACU writes INFO, WARN, and ERROR JSON records to `~/Library/Logs/ACU/acu.log`. Controller, Guardian, and the native bridge share logs with timestamps, severity, process role, and PID. Files rotate at 5 MiB with three backups. Credentials and IPC tokens are not logged. Use `tail -f ~/Library/Logs/ACU/acu.log` to inspect session notifications, state transitions, and cleanup.
