# Other upstream integrations

## Android hardware definitions and system images

The bundled catalogs come from [AOSP tools/base's sdklib device resources](https://android.googlesource.com/platform/tools/base/+/mirror-goog-studio-main/sdklib/src/main/resources/com/android/sdklib/devices/). `Sources/DevHub/Android/Resources/device-catalog-NOTICE.txt` records the exact bundled revision. Follow the root README's update instructions and use `scripts/update_device_catalog.py`; do not hand-edit Google's XML.

Look in `NewEmulator.swift` for profile parsing, image discovery and creation compatibility, and `AndroidVersion.swift` for API versions. Installed image `source.properties` and `package.xml` supply API minor versions, tags and ABIs. Do not truncate versions such as 37.2 to 37. Relevant coverage is in `EmulatorTests.swift`, `CreationSelectionTests.swift`, and `AndroidVersionTests.swift`.

## Android display controls, folding, and geometry

For live Navigation Mode, TalkBack, Select to Speak, Display Size and reset rules, see [Android runtime settings](android-runtime-settings.md).

Compare Android Studio's [streaming emulator implementation](https://android.googlesource.com/platform/tools/adt/idea/+/mirror-goog-studio-main/streaming/src/com/android/tools/idea/streaming/emulator/) and the Android emulator's [gRPC service definitions](https://android.googlesource.com/platform/external/qemu/+/emu-master-dev/android/android-grpc/services/). If a path moves, browse the repository tree rather than assuming an old class still owns the feature. Check the installed SDK emulator's own help and gRPC definitions for version compatibility.

DevHub's Android implementation is in `Sources/DevHub/Android/`, including `DeviceActions.swift`, `DisplayController.swift`, `DisplayGeometry.swift`, and `AndroidDeviceView.swift`. Platform tests are in `Tests/DevHubTests/Android/`; shared screenshot and fold-transition tests remain at the test target's top level.

Preserve serialized/queued form-factor transitions and pending selection state. Rotation must work even when Android locks its orientation. Resizable AVDs require the emulator's window agent (`-qt-hide-window`), since fully headless resizing is unsupported by that agent. Screen capture, touch transforms, rounded corners and current-display selection must use the same geometry.

## scrcpy

Use the [official Genymobile/scrcpy repository](https://github.com/Genymobile/scrcpy), its [releases](https://github.com/Genymobile/scrcpy/releases), and the server sources for the exact version being bundled. Protocol changes are not necessarily backward compatible. Check the versioned `server/.../control`, `device`, and `video` packages before changing message encodings or stream handling.

`build.sh` pins the server download; update it together with the client's handshake/version and protocol implementation in `Mirror.swift`. `AndroidMirrorSession.swift`, `DeviceSessionCache.swift`, and `VideoFrameGate.swift` own connection reuse and offscreen decoding behavior. Inspect `ProtocolTests.swift`, `VideoFrameGateTests.swift`, and session/cache coverage. Test real touch, clipboard, rotation and screen capture against the new server; a successful build is not proof of protocol compatibility.

## Apple simulators and physical devices

Apple's private simulator/device frameworks do not have a supported public source distribution. Inspect the frameworks from the **selected full Xcode**, their runtime capabilities, and the installed command help. DeviceHub is useful as a behavior reference, but it does not need to be running. Do not assume a private API is stable between Xcode releases.

Start with:

```sh
xcode-select -p
xcrun simctl help
xcrun simctl help ui
xcrun devicectl help
xcrun devicectl device info --help
xcrun devicectl device settings --help
```

Find the current framework locations relative to that Xcode and the system's CoreSimulator installation; avoid hardcoding a particular `/Applications/Xcode.app` path. Inspect supported JSON results and Objective-C selectors before introducing calls, keep availability checks/fallbacks, and surface errors rather than spinning indefinitely.

| Feature | DevHub files | What to verify upstream/on the installed runtime |
| --- | --- | --- |
| Discovery and filtering unused definitions | `AppleSimulator.swift`, `SimulatorCatalog.swift`, `AppleDevice.swift`, `Sources/DevHub/Apple/SimulatorBridge/` | CoreDevice inventory versus fallback CoreSimulator metadata; do not equate every definition with an actively used simulator |
| Embedded simulator display/input | `AppleSimulator.swift`, `AppleSimulatorView.swift`, `SimulatorFrame.swift`, `SimulatorGestures.swift`, `SimulatorTouchEdge.swift`, `Sources/DevHub/Apple/SimulatorBridge/SimulatorBridge.m` | Display capabilities, reported orientation, native mounting rotation, masks and touch semantics |
| Simulator appearance/accessibility | `Apple/SimulatorAppearance.swift`, `Apple/SimulatorSettingsView.swift`, `Apple/SimulatorSettingsCache.swift` | `devicectl device info appearance`, `device settings appearance`, supported JSON keys; older Xcode `simctl ui` fallback |
| Physical-device sharing | `AppleDevice.swift`, `AppleDeviceView.swift`, `Sources/DevHub/Apple/SimulatorBridge/DeviceKitBridge.m` | Xcode DeviceKit view behavior, OS compatibility, pairing and unlock/error states |
| Simulator creation/deletion | `SimulatorCatalog.swift`, `NewSimulator.swift`, `AppleSimulator.swift` | Installed runtime/model compatibility, shutdown checks, and existing unused definitions |
| File imports | `SimulatorFileTransfer.swift` | Installed Files app's storage group, supported media/contact import commands, duplicate naming |

Apple Swift sources are in `Sources/DevHub/Apple/`, with the native bridge in its `SimulatorBridge/` folder. Apple tests are in `Tests/DevHubTests/Apple/`. Shared UI, coordinate transforms, fold-transition handling, screenshots, and session caching stay at the target's top level. Some source names may change as features are refactored. Use `rg --files Sources` and search for the command/selector to locate the current owner.

For folding/rotation, do not assume every display has the same native mounting angle. The iPhone Duo inner display uses a different angle from its cover display; read per-display capabilities and follow reported framebuffer orientation. Check `SimulatorRotationTests.swift` before changing that mapping.

Simulator settings are prefetched when discovery finds a booted simulator and retained independently of device and inspector views. Reopening Settings uses cached values immediately, coalesces in-flight reads, and refreshes values older than three seconds without hiding the controls. Successful changes and Reset update the cache; a revision check prevents an older query from overwriting them. Shutdown removes the cached state and cancels pending reads. Keep this behavior when changing the backend, and run `SimulatorSettingsCacheTests.swift` for query sharing, stale replies, failed writes, and shutdown.

Existing optional live tests document their environment variables in `Tests/DevHubTests`. Inspect the test before running it: some interact with a real simulator and must restore its original state. Run focused tests and visually check the affected device after a framework/Xcode upgrade. Relaunching DevHub means closing the previous app process first; do not leave multiple copies running.
