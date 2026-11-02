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

### Apple colour filters and Liquid Glass

Checked with the selected Xcode's `devicectl` version 651.13.5 on 2026-11-02, its `device settings appearance --help`, and live iOS 17.5, 27.0 and 27.1 simulator results. Use reported customization capability and fields rather than hardcoded OS cutoffs:

- `device info details` reports `com.apple.coredevice.feature.customizeliquidglass` for modern appearance customization on the checked supported runtimes. Require that capability as well as the appearance fields for the new controls. The iOS 17.5 simulator lacks it and returns a placeholder `{ "colorFilter": { "enabled": false } }` despite rejecting colour-filter writes with error 21049. Do not treat that placeholder as proof of support. CoreDevice's native `AppearanceSettingsProtocol.customizableAppearanceElements()` / `CustomizableAppearanceElements.colorFilter` is the more granular private API to inspect if these capabilities diverge in a future Xcode. Details and appearance queries run concurrently; a transient details-query failure retains known cached capability state, while an unknown initial capability hides the new controls.
- Disabled colour filter is `{ "enabled": false }`; enabled additionally reports `filterType.name` (`Grayscale`, `Protanopia`, `Deuteranopia`, `Tritanopia`), and non-grayscale modes can report intensity. Write `--color-filter on --color-filter-type <lowercase-name>` or `--color-filter off`. Do not change intensity when selecting a mode. Keep unknown enabled filters represented as Other instead of reporting None. The old `simctl ui` fallback does not expose these commands.
- `result.liquidGlassOpacity` is a finite value from 0 through 1 when supported. Write `--liquid-glass-opacity <value>`. The iOS 17.5 simulator did not report it; 27.0/27.1 simulators did. The UI commits the slider when editing ends, updates the retained cache optimistically, and reloads actual state after failures. Reset restores 0.5, the observed default on the checked modern simulators, while unsupported runtimes receive no Liquid Glass command.
- Reset includes `--color-filter off` where supported. Maintain cache capabilities and keep missing fields absent after changes and reset. Parsing, command validation, fallback, cache/reset and optional live restoration tests are in `SimulatorSettingsTests.swift` and `SimulatorSettingsCacheTests.swift`.

Physical Apple devices continue to use Xcode's own embedded DeviceKit view and its native controls. DevHub's custom appearance inspector applies to simulators; do not infer support on a disconnected physical device from its OS version.

Existing optional live tests document their environment variables in `Tests/DevHubTests`. Inspect the test before running it: some interact with a real simulator and must restore its original state. Run focused tests and visually check the affected device after a framework/Xcode upgrade. Relaunching DevHub means closing the previous app process first; do not leave multiple copies running.

The simulator XPC endpoint helper `xpc_endpoint_create_mach_port_4sim` takes `(mach_port_t, uint64_t, uint64_t)`. Pass zero for both trailing arguments; a one-argument declaration leaves their values undefined. It returns a retained endpoint and consumes the lookup's Mach send right: declare the retained result for ARC and do not manually deallocate the right after creating the endpoint. These contracts follow Meta idb's [SimulatorXPCConnection.swift at c793afad](https://github.com/meta/idb/blob/c793afad2a31092628f7013cf1aa96f266c85024/FBSimulatorControl/XPC/SimulatorXPCConnection.swift), checked 2026-11-02. Preserve `xpc_connection_enable_sim2host_4sim` before resuming the connection. A successful barrier handshake only confirms that a peer answers; verify actual taps, keys, and Home on multiple runtimes too.

Simulator input also depends on the **guest runtime**, not just the selected Xcode. `AppleSimulator.prefersLegacyInput` selects SimulatorKit's legacy Indigo client before OS 26; OS 26+ and unknown versions try DTUHID with the existing availability fallback. The modern transport's OS 26+ scope is recorded in idb's [SimulatorDigitizerHIDTransport.swift](https://github.com/meta/idb/blob/c793afad2a31092628f7013cf1aa96f266c85024/FBSimulatorControl/HID/SimulatorDigitizerHIDTransport.swift). The compatibility distinction was checked live on iOS 17.5 and 27.0/27.1 with the selected Xcode on 2026-11-02; version-policy tests also cover 18.6 and the 26.0 boundary.

On the checked iOS 17.5 runtime, CoreSimulator advertises the DTUHID service and its barrier replies, but the guest log reports `UniversalHID Framework not available`. Starting that daemon sets `com.apple.coredevice.dtuhidd.active` and suppresses legacy HID services, leaving both DevHub and Apple's DeviceHub unable to control the device. Merely switching clients or restarting the input daemon did not recover input. A full simulator shutdown/boot followed by legacy input restored touch, confirmed by the user. Avoid probing DTUHID on these older runtimes; selecting legacy must happen before creating any modern input channel. An already affected simulator may need one restart. DevHub does not stop another client's input daemon or reboot devices automatically. Read **guest** diagnostics with `xcrun simctl spawn <UDID> log show` for `dtuhidd` and `backboardd`; host `log show` can omit these records. Recheck runtime support and both input paths when updating this policy rather than relying only on service lookup or a barrier response.
