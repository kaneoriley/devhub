# Android emulator configuration

## Sources to check

Android Studio's current AVD editor is in the AOSP `platform/tools/adt/idea` repository, under [`avd/src/com/android/tools/idea/avd/`](https://android.googlesource.com/platform/tools/adt/idea/+/mirror-goog-studio-main/avd/src/com/android/tools/idea/avd/). The old `android/.../avdmanager/ui` directory is not the current additional-settings dialog.

Start with these files:

| File | What it determines |
| --- | --- |
| `AdditionalSettingsPanel.kt` | Camera choices and visibility, network presets, startup orientations, CPU core choices, graphics, RAM/heap units, preferred ABI choices |
| `VirtualDevice.kt` | Profile-based defaults, unsupported form factors, minimum capacities, mapping to `AvdBuilder` |
| `StorageGroup.kt` | Expanded-storage modes, file validation, warning when custom storage size changes |
| `ConfigureDevicePanelState.kt` | Host CPU limit and preferred ABI compatibility |
| `ISystemImages.kt` | Native and translated application ABI choices from the selected image |
| `GraphicsMode.kt`, `Boot.kt` | Values behind UI labels and the complete boot-mode property set |

The actual disk representation and SD card lifecycle are in AOSP `platform/tools/base`, under [`sdklib/src/main/java/com/android/sdklib/internal/avd/`](https://android.googlesource.com/platform/tools/base/+/mirror-goog-studio-main/sdklib/src/main/java/com/android/sdklib/internal/avd/):

| File | What it determines |
| --- | --- |
| `AvdBuilder.kt`, `ConfigKey.kt` | Editable config keys, storage units, reading existing AVDs |
| `EmulatedProperties.java` | Default CPU, RAM, internal storage, and density/screen-size-dependent VM heap |
| `AvdCamera.java`, `AvdNetworkSpeed.java`, `AvdNetworkLatency.java`, `GpuMode.java` | Exact persisted enum values |
| `BootMode.kt` | Cold, Quick, and chosen-snapshot properties |
| `SdCard.kt`, `AvdManager.kt` | Custom versus external SD cards, limits, image generation and reuse |
| `UserSettingsKey.kt` | Preferred ABI lives in `user-settings.ini` as `abi.type.preferred` |

Also check the [AVD documentation](https://developer.android.com/studio/run/managing-avds) and [emulator command-line reference](https://developer.android.com/studio/run/emulator-commandline). Source is more precise about config serialization and current compatibility rules.

The initial implementation was checked on 2026-11-02 against Studio revision `224edb8a5a99071fc2fb02bb7a4f80021723ccf6` and tools/base revision `45628254f0f8a9bb3755d73f3d30ca78fbb2153d`. These identify the comparison baseline, not a promise that upstream behavior will stay fixed. Use `mirror-goog-studio-main` links above to check later changes; replace the branch with a commit hash to inspect a reproducible snapshot.

## DevHub implementation

- `Sources/DevHub/Android/EmulatorConfiguration.swift`: typed capacities, config loading, compatibility, validation, INI updates, SD image generation, save conflict checks and rollback.
- `Sources/DevHub/Android/EmulatorConfigurationView.swift`: shared dialog, controls, replacement confirmation, editing existing AVDs.
- `Sources/DevHub/Android/NewEmulator.swift`: profile metadata, creation defaults and applying configuration to new AVDs.
- `Sources/DevHub/Android/AndroidDeviceInfoView.swift`: **Edit Configuration** below emulator details in the Info inspector, available offline. Graphics acceleration and boot mode are read from the saved AVD configuration and refreshed when the editor closes.
- `Sources/DevHub/Android/SDK.swift` and `Hub+Android.swift`: AVD directory resolution, boot arguments, and preventing DevHub from booting a device during a save.
- `Tests/DevHubTests/Android/EmulatorConfigurationTests.swift`: serialization, compatibility, file preservation, failure recovery, and SDK-backed SD card test.

## Rules that are easy to miss

- Cameras come from the hardware profile's camera locations. Virtual Scene is a rear-camera option. Orientation choices come from profile states. Wear devices do not get expanded storage.
- ABI choices come from the selected image's `package.xml`, including translated ABIs. Preferred ABI is an application/deployment preference, not permission to rewrite the image's primary `abi.type` or CPU architecture. Store it in `user-settings.ini`; Optimal removes the override.
- UI MB and GB use binary multipliers. RAM and VM heap are persisted as a number of MB. Internal partition size is bytes or a suffixed capacity. SD card sizes use suffixed values such as `512M` or `524288K`.
- `sdcard.size` is descriptive metadata. The emulator needs an actual FAT image. Use the installed SDK's `emulator/mksdcard`, retain an unchanged image, and warn before replacing one. Never resize an external image for the user.
- A boot-mode change must clear the chosen-snapshot overrides as well as set Cold/Quick flags.
- Existing AVDs can have custom values, older limits, or settings supplied by other tools. Preserve unchanged values and unrelated INI entries. Check for external edits and a running emulator again after generating a card, before replacing files.
- Configuration is available without booting the device or having its system image installed. A missing image means fewer ABI metadata choices, not an unavailable configuration dialog.

## Verification after updates

Run `swift test` and `./build.sh`. To exercise the installed SDK tool as well:

```sh
DEVHUB_TEST_AVD_SDCARD=1 swift test
```

That test creates a 10 MB image in a temporary directory, checks its size and FAT signature, and verifies that a later unrelated edit preserves it. It does not edit the user's AVDs.

Visually check a shut-down emulator: Info → Edit Configuration must open without a device connection. Check Camera, Network, Startup, Storage, and Emulated Performance, both SD card modes, validation, and Cancel. Check that a running emulator explains the shutdown requirement. Exercise changes on a disposable AVD and verify them after boot, especially when upgrading the installed emulator. Avoid altering or wiping a user's existing device as a smoke test.
