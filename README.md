<div align="center">
  <img src=".github/icon.png" width="128" alt="DroidHub app icon">
  <h1>🤖 DroidHub</h1>
  <p>Device hub for <strong>macOS</strong>, in the spirit of the Device Hub that ships with Xcode 27. Android emulators, phones, and Apple simulators in one list, with the screen live and clickable inside a normal window.<br>
  <strong>Tiling friendly:</strong> there's no floating toolbar and no custom chrome, so yabai and friends tile it like any other app.<br>
  Written in Swift on top of the <a href="https://github.com/Genymobile/scrcpy">scrcpy</a> server.</p>

  [![release](https://img.shields.io/github/v/release/eduardoborges/droidhub)](https://github.com/eduardoborges/droidhub/releases)
  [![platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue)](#requirements)
  [![swift](https://img.shields.io/badge/Swift-SwiftUI-orange)](Sources/DroidHub/)
  [![scrcpy](https://img.shields.io/badge/scrcpy-5.0.1-green)](https://github.com/Genymobile/scrcpy)
  [![license](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

</div>

---

**[Download](https://github.com/eduardoborges/droidhub/releases/latest)** · **[Changelog](CHANGELOG.md)**

<p align="center"><img src=".github/screenshot.png" width="360" alt="DroidHub mirroring a Pixel emulator"></p>

## Why

The Android emulator draws its own frameless window with a toolbar floating beside it. A tiling window manager can't place that pair properly, and scrcpy's SDL window has no device list or controls. DroidHub boots emulators headless (`-no-window`) and draws the screen in a regular SwiftUI window instead.

## What it does

- 🪟 **A real window.** Sidebar, screen and inspector live in one window. yabai tiles it out of the box, with no rules to add.
- 📱 **Live screen with input.** The device streams H.264 over the scrcpy protocol and the Mac decodes it in hardware. Click and drag become touches, the trackpad scrolls, and a right click goes back.
- ⌨️ **Type on the device.** Text, arrows and delete go straight to Android. Accented characters travel through the device clipboard, because scrcpy can only inject what the device key map knows. Esc is Back and ⌘M opens the React Native dev menu.
- 📋 **Shared clipboard.** Copy something on the device and it lands on the Mac. ⌘V pastes the Mac clipboard into the device.
- 🚀 **Headless emulators.** Boot and shut down AVDs from the sidebar. The emulator's own window never shows up. An emulator started from Android Studio or `react-native run-android` gets its window hidden and shows up here too; its Dock icon brings the window back.
- 🐞 **Logs and crashes.** Logcat streams into the inspector with text and level filters, so `ReactNativeJS` is one word away. Java and native crashes from the device's crash buffer show up as reports you can expand and copy.

And the rest:

- Back, Home and Recents in a floating bar at the bottom, volume and power in the toolbar.
- ⌘S saves the device frame currently shown in DroidHub to the Desktop and copies it to the clipboard, like Simulator does. A thumbnail confirmation above the controls opens the saved file in Finder. Screenshots use the mirrored display at its original resolution, including when a Resizable or foldable emulator changes displays.
- ⌘→ rotates the device.
- Screen corners follow Android's reported per-display radii, including after rotation, resizing, or folding. Displays with no reported rounding keep their full rectangular image.
- Drop an APK onto the device to install it, or drop a base APK and its splits together to install one app. Other files copy to the device's Downloads folder (`/sdcard/Download/`). Drop APKs and other files separately; folders aren't supported. Progress and errors appear in the window.
- Rotate and Phone / Foldable / Tablet share a display-control capsule. Available form factors come from the AVD's configuration and emulator; unsupported segments are disabled. Dedicated foldable emulators also get Opened / Closed controls. The selection follows the device's actual size, density, and committed folding state. DroidHub boots Resizable AVDs with the emulator window hidden rather than fully headless, because resizing requires the window agent. Shut down and boot existing headless Resizable emulators once to enable switching.
- Form-factor changes finish the emulator's transition before applying the latest queued selection, and use each preset's natural orientation. Emulator rotation turns the displayed device even when Android auto-rotate is disabled or an app locks its orientation; touch input and screenshots follow the displayed rotation.
- The inspector uses an appearance picker and text-size slider on Android and Apple simulators. Android also offers Show Taps and Layout Bounds; simulators offer Apple’s Show Borders accessibility setting when supported by Xcode. Apple’s simulator settings do not expose an equivalent to Android’s Show Taps. **Reset to Defaults** restores Android’s device-defined default appearance, 100% font size, and disables Show Taps and Layout Bounds. On simulators it restores Light appearance, Large text size, and disables Show Borders.
- **Edit Configuration** at the top of an Android emulator's settings opens its saved AVD configuration, including while it is off. Configure cameras, network speed and latency, startup orientation and boot mode, internal and expanded storage, CPU cores, graphics, RAM, VM heap, and preferred application ABI. Available camera, orientation, storage, and ABI options follow the hardware profile and installed system image. Shut down a running emulator before saving. Resizing a custom SD card asks before erasing its contents. The same options are available during emulator creation.
- Physical devices connected through adb show up next to the emulators.
- Apple simulators appear in their own sidebar section using Apple's CoreDevice discovery inventory. Unused automatic device definitions stay hidden; explicitly created simulators remain visible even before their first boot. Older toolchains fall back to CoreSimulator's default-device registry and usage metadata.
- Shut-down Apple simulators have **Delete…** in their context menu, like Android emulators. Deletion asks for confirmation and removes the virtual device and its installed apps and data. DroidHub rechecks that the simulator is shut down before deleting it.
- Boot and shut down Apple simulators, interact with their embedded screens using mouse and keyboard, rotate, use Home and App Switcher, and capture screenshots. Drop simulator `.app` bundles to install them. Other files copy to **Files → Browse → On My iPhone/iPad → Downloads**, using the Files app's local-storage group; a compatible simulator Files app must be installed. Existing files are kept, with numbered names for duplicate uploads. Photos, videos, and contacts are also imported into Photos or Contacts. Install apps and copy files in separate drops. Completed transfer notifications dismiss after three seconds, pausing while hovered. On simulators, wheel or two-finger trackpad scrolling swipes under the pointer; trackpad pinch or **Option-scroll** zooms around it. Simulator displays use Apple's own corner and camera masks. The selected full Xcode installation supplies the simulator runtimes and frameworks; DeviceHub does not need to be open.
- Physical iPhones and iPads appear alongside Android devices. Their embedded screen-sharing view comes from the selected Xcode's DeviceKit framework, including Apple's unlock, pairing, compatibility checks, and supported screen-sharing controls. The framework stays in Xcode; DroidHub does not bundle it or launch DeviceHub. Physical screen sharing requires iOS/iPadOS 27 or newer.
- The + menu offers **Android Emulator…** and **iOS Simulator…**. Android creation uses the bundled device catalog and installed system images; Android Studio and SDK cmdline-tools are not required. iOS creation lets you choose a name, installed OS version, and compatible iPhone or iPad model from the selected Xcode installation. New virtual devices start shut down and can be booted from the device list. Virtual devices that are off can be deleted from their context menu.
- Plays well with AI agents. They drive the device through `adb` while you watch in DroidHub, and Show Taps marks every tap they make.

## Keyboard

| Key | Action |
|---|---|
| Hold ⌘, move, then click and drag | Two-finger gesture around the cursor position captured when ⌘ was pressed; release the click to lift both fingers |
| ⌘S | Screenshot |
| ⌘→ | Rotate |
| ⇧⌘H | Home |
| Esc or right click | Back |
| ⌘M | Menu key (React Native dev menu) |
| ⌘C ⌘X ⌘A | Copy, cut and select all on the device |
| ⌘V | Paste the Mac clipboard |

## Requirements

- macOS 26+ (Liquid Glass UI)
- Android SDK with `platform-tools` and `emulator`, in `~/Library/Android/sdk` or wherever `ANDROID_HOME` points
- Android system images installed through `sdkmanager` or Android Studio's SDK Manager; AVDs are read from `~/.android/avd`
- For Apple simulators: a full Xcode installation selected with `xcode-select`, with the desired simulator runtimes installed
- For physical Apple-device screen sharing: Xcode 27+ and a supported iPhone or iPad running iOS/iPadOS 27+
- To build from source: Xcode 26+

## Android device definitions

DroidHub bundles Google's hardware-profile definitions, `nexus.xml` and `devices.xml`, from the Android Open Source Project's [tools/base device catalog](https://android.googlesource.com/platform/tools/base/+/mirror-goog-studio-main/sdklib/src/main/resources/com/android/sdklib/devices/). These are the definitions used by Android Studio's Device Manager. Android Studio does not need to be installed to load the catalog or create an emulator in DroidHub.

The XML files are kept unmodified in [Sources/DroidHub/Resources](Sources/DroidHub/Resources). [device-catalog-NOTICE.txt](Sources/DroidHub/Resources/device-catalog-NOTICE.txt) records the exact upstream commit and source URL. The definitions are distributed under [Apache License 2.0](ThirdParty/android-tools-LICENSE).

To refresh the bundled snapshot from Google's Studio branch, run from the repository root:

```sh
python3 scripts/update_device_catalog.py
swift test
./build.sh
```

The script resolves the branch to a commit, downloads and validates both catalogs, then updates the XML files, license, and provenance notice. Review and commit those changes together. To reproduce a specific snapshot, pass its commit hash with `--revision <commit>`; the notice includes the complete command for the bundled version.

Hardware profiles describe the virtual device; Android SDK tools and system images are installed separately. Updating this catalog does not download system images or alter existing AVDs.

## 🛠 Build

For upstream source locations, compatibility rules, and verification steps when maintaining integrations, see [docs/](docs/README.md).

Install it with Homebrew:

```sh
brew install --cask eduardoborges/tap/droidhub
```

Or grab `DroidHub.dmg` from the [latest release](https://github.com/eduardoborges/droidhub/releases/latest), or build it yourself:

```sh
./build.sh
open build/DroidHub.app
```

`build.sh` downloads the matching scrcpy server into `.build/`, compiles a release build with SwiftPM, wraps it in `build/DroidHub.app` and signs it ad hoc. `./build.sh --dmg` also packages `build/DroidHub.dmg`. Set `SIGN_IDENTITY` to sign with a Developer ID, and the `NOTARY_*` variables to notarize, which is what CD does.

The tests cover H.264 parsing and the control message encoding:

```sh
swift test
```

## Releases

Commits follow [Conventional Commits](https://www.conventionalcommits.org). On every push to `main`, release-please keeps a release PR open with the next version and the changelog. Merging it tags the release, and CD attaches a signed, notarized `DroidHub.dmg` and `DroidHub.zip`.

## How it works

When you select a device, DroidHub pushes `scrcpy-server` to `/data/local/tmp`, opens an `adb forward` tunnel and starts the server with `app_process`. Two sockets come back. The video socket carries H.264 packets, which go into an `AVSampleBufferDisplayLayer`. The control socket carries touches, keys, text and clipboard in scrcpy's binary format, both ways.

DroidHub retains the 12 most recently selected Android connections, so switching back reuses the server, tunnel, and decoder. Offscreen Android sessions drain compressed packets without decoding frames; switching back requests a fresh capture/keyframe over the existing control connection. Only the selected device can update the Mac clipboard. Disconnecting a device or evicting an older session closes its server and tunnel. Apple simulators use a separate cache of 12 sessions and pause offscreen rendering.

The scrcpy version is pinned in `build.sh`. The protocol changes between releases and the server refuses a client from a different version, so bump both together.

## Repository layout

```
Sources/DroidHub/
  App.swift      SwiftUI window: sidebar, device frame, bottom bar, inspector, input
  Hub.swift      device discovery (adb, AVD files), boot, shutdown, screenshots
  Mirror.swift   scrcpy client: sockets, H.264 to CMSampleBuffer, control messages
Tests/           protocol tests
icon/            AppIcon.icon (Icon Composer) and icon.py, the Blender script that renders its layers
.github/         CI (pull requests), CR (release-please), CD (signed dmg)
build.sh         builds, signs and packages DroidHub.app
version.txt      current version, bumped by release-please
```

## License

MIT, see [LICENSE](LICENSE).

The scrcpy server that `build.sh` downloads and bundles is Apache 2.0, by Genymobile. The bugdroid in the icon is based on the Android robot, created and shared by Google under the [Creative Commons Attribution 3.0 License](https://creativecommons.org/licenses/by/3.0/).
