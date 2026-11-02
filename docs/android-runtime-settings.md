# Android runtime settings

This guide covers every live Android setting in the inspector: Appearance (dark theme), Navigation Mode, TalkBack, Select to Speak, Font Size, Display Size, Show Taps and Layout Bounds, plus Reset to Defaults. These are separate from the saved AVD configuration dialog and require a connected, booted Android device. The configuration dialog remains available while an emulator is off.

## Upstream rules

Checked on 2026-11-02 against Android Studio revision `224edb8a5a99071fc2fb02bb7a4f80021723ccf6` in AOSP `platform/tools/adt/idea`. Follow the branch links below to check current behavior, or substitute that commit for `mirror-goog-studio-main` to reproduce the comparison.

| Source | Rules used by DroidHub |
| --- | --- |
| [`EmulatorUiSettingsController.kt`](https://android.googlesource.com/platform/tools/adt/idea/+/mirror-goog-studio-main/streaming/src/com/android/tools/idea/streaming/emulator/EmulatorUiSettingsController.kt) | Appearance via `processDarkMode`/`setDarkMode`, font scale via `processFontScale`/`setFontScale`, Layout Bounds via `processDebugLayout`/`setDebugLayout`, navigation overlays, accessibility services/shortcuts, density commands and reset behavior |
| [`UiSettingsPanel.kt`](https://android.googlesource.com/platform/tools/adt/idea/+/mirror-goog-studio-main/streaming/src/com/android/tools/idea/streaming/uisettings/ui/UiSettingsPanel.kt) | Appearance visibility by device type; Navigation only on handheld devices; Select to Speak and Display Size on handheld/desktop/XR; TalkBack package checks; permission-related font/density visibility; Layout Bounds row |
| [`GoogleDensityRange.kt`](https://android.googlesource.com/platform/tools/adt/idea/+/mirror-goog-studio-main/streaming/src/com/android/tools/idea/streaming/uisettings/ui/GoogleDensityRange.kt) | Display Size slider steps derived from current screen dimensions and default density, rather than a fixed set of percentages |
| [`UiSettingsModel.kt`](https://android.googlesource.com/platform/tools/adt/idea/+/mirror-goog-studio-main/streaming/src/com/android/tools/idea/streaming/uisettings/ui/UiSettingsModel.kt) | `FontScale`/`WearFontScale`, API-dependent font slider ranges, nearest-step selection for font/density overrides and the relationship between UI state and runtime values |

`GoogleDensityRange` names its original Android sources: `frameworks/base/packages/SettingsLib/res/values/dimens.xml` and `DisplayDensityUtils.java` from the `udc-dev` branch. Its constants are a minimum scale of 0.85, maximum scale of 1.5, minimum interval of 0.09, and minimum logical screen width of 320 dp. The algorithm offers at most one smaller and three larger steps, includes default density, and rounds non-default densities down to an even integer. Recheck Studio's current algorithm before changing those values.

## Compatibility and commands

- **Appearance / dark theme:** Read `cmd uimode night`. Light writes `cmd uimode night no`, Dark writes `cmd uimode night yes`, and Automatic writes `cmd uimode night auto`. Studio's `setDarkMode` exposes the Light/Dark behavior through a checkbox; Automatic is an existing DroidHub addition. For reset, DroidHub reads `cmd overlay lookup android android:integer/config_defaultNightMode` and maps `0` to Automatic, `1` to Light and `2` to Dark. Unknown or unreadable defaults fail visibly rather than guessing. Studio hides its dark-theme control on Wear, TV and Automotive, and resets XR to Dark; DroidHub currently shows its Appearance picker for all connected Android device types. Recheck that difference when expanding form-factor-specific support.
- **Navigation Mode:** Studio detects `com.android.internal.systemui.navbar.gestural`. DroidHub additionally requires `com.android.internal.systemui.navbar.threebutton` so both choices can work. It offers Gestures/Buttons on phones, tablets, foldables and Resizables. `cmd overlay enable-exclusive --user current --category <overlay>` changes only the navigation overlay category. Studio uses separate enable/disable calls for the same two packages; category exclusivity also handles an already enabled two-button overlay without disturbing device/cutout overlays.
- **TalkBack:** Studio requires `com.google.android.marvin.talkback` to be installed. DroidHub checks the exact package, then checks declared accessibility services with `cmd package query-services` when supported. Package-name prefixes such as `talkbackoverlay` do not establish support. Older package-manager commands fall back to Studio's package check. The service is `com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService`; compact `.TalkBackService` component notation must compare equal.
- **Select to Speak:** Uses the same installed package and the service `com.google.android.marvin.talkback/com.google.android.accessibility.selecttospeak.SelectToSpeakService`. Studio displays it on handheld, desktop and XR devices, not Wear, TV or Automotive. DroidHub follows the supported families it currently represents. Enabled state requires membership in both `enabled_accessibility_services` and `accessibility_button_targets`.
- **Accessibility mutation:** Read/modify/write the relevant colon-separated secure setting for the current Android user. Preserve all other services and button targets. Delete a key if no entries remain. Studio attempts to grant `android.permission.POST_NOTIFICATIONS` before enabling TalkBack to avoid its notification prompt; DroidHub does the same as an optional step, because older images do not declare that permission. Do not grant permissions to unrelated packages. Shell-quote values read from the device before sending them back through `adb shell`.
- **Font Size:** Read `settings get system font_scale`; write `settings put system font_scale <scale>`, with a locale-independent decimal such as `1.15`. DroidHub's existing slider offers 85%, 100%, 115%, 130%, 150%, 180% and 200%, selecting the nearest step when reading another scale. Commit when slider editing ends. Reset deletes the `font_scale` override and reloads the result. Studio's `FontScale` defines those seven common steps, while `WearFontScale` defines 94%, 100%, 106%, 112%, 118% and 124%. Its `numberOfFontScales` also restricts API 33 to four common steps. DroidHub currently uses its seven common steps for every Android device; do not mistake that existing behavior for implementation of Studio's Wear/API-specific ranges. On physical OEM devices, changing the setting can be denied; surface command errors and reload actual state.
- **Display Size:** Read `wm size` and `wm density`, use the active override dimensions if present, and apply the selected density with `wm density <dpi>`. A normal device's default step removes the override with `wm density reset`. Refresh the mirror's input density after changes so wheel gestures retain their correct scale. Unsupported or unreadable density/size metadata hides this control.
- **Show Taps:** Read `settings get system show_touches`; `1` means enabled. Write `settings put system show_touches 1` or `0`. Reset deletes that override. This is an existing DroidHub Android control, not a setting in Studio's `UiSettingsPanel`; its command and behavior are maintained in DroidHub's `SettingsView`. It marks taps from other tools as well as DroidHub input. Do not confuse it with the separate Pointer Location developer option or assume Apple simulators expose an equivalent.
- **Layout Bounds:** Read `getprop debug.layout`; write `setprop debug.layout true` or `false`, then notify running activities with `service call activity 1599295570`. Studio's `setDebugLayout` uses the same property and `SYSTEM_PROPERTY_UPDATE_COMMAND`; the transaction number is `IBinder.SYSPROPS_TRANSACTION`. Merely setting the property can leave running app bounds stale. Reset clears the property and sends the same notification. The checked Studio controller additionally sends a second notification when resetting previously active bounds, citing `b/492014029`; DroidHub currently sends one. Keep that upstream workaround in view if bounds fail to clear on a newer runtime.
- **Form factors:** Navigation is unavailable for Wear, TV, Automotive and desktop devices. Select to Speak and Display Size are omitted for Wear, TV and Automotive. TalkBack may remain available on those form factors when installed. Missing capabilities hide controls; no Android Studio installation is needed.

## Resizable integration

DroidHub already corrects mismatched density after Quick Boot when synchronizing Resizable form factors. That correction must not undo an intentional Display Size change.

For a Resizable, match the active pixel dimensions to its AVD `hw.resizable.configs` preset and use that preset's density as the default for the slider and reset. A tablet preset at 240 dpi must not reset to a phone's physical 420 dpi. Remember explicit density choices by stable device ID and normalized pixel dimensions, and preserve a matching choice when reconnecting. Keep the form-factor segment selected for that intentional override. Rotation must address the same preference entry; another device or another screen size must not inherit it. Changing form factor still uses the new preset's natural density.

This is a DroidHub integration rule, in addition to Studio's generic density-range algorithm. Relevant upstream emulator mode-change behavior is documented under [display controls](upstream-integrations.md#android-display-controls-folding-and-geometry).

## Reset

Reset affects only options exposed by DroidHub:

- Restore the device-defined appearance using `android:integer/config_defaultNightMode`, including Automatic when that is the device default.
- Delete the `font_scale` override to restore default font size, normally 100%.
- Delete the `show_touches` override to restore Show Taps off.
- Set `debug.layout` to `false` and notify running activities to clear Layout Bounds.
- Restore the default display density, accounting for the active Resizable preset.
- Restore Gestures when the handheld navigation overlays support it, matching Studio's emulator reset. Do not attempt navigation commands on unsupported form factors.
- Remove only TalkBack and Select to Speak from enabled accessibility services, and only Select to Speak from accessibility shortcut targets. Preserve unrelated accessibility entries.

Studio also resets per-app language when it exposes that setting. DroidHub does not expose it, so its reset leaves application languages alone. DroidHub retains its existing device-defined appearance reset rather than adopting Studio's hardcoded Light/XR Dark values.

## Implementation and verification

- `Sources/DroidHub/AndroidUISettings.swift`: capability/state probes, density algorithm, commands, component handling and explicit density preferences.
- `Sources/DroidHub/App.swift`: `SettingsView` owns Appearance, Font Size, Show Taps and Layout Bounds state/commands, integrates the newer runtime controls, and handles inspector refresh, Resizable selection/synchronization and mirror density refresh.
- `Sources/DroidHub/DeviceSettings.swift`: shared appearance/font controls and `AndroidSettingsDefaults`, which resets the complete Android settings list.
- `Sources/DroidHub/DeviceActions.swift`: preserve a known intentional density during Resizable synchronization.
- `Tests/DroidHubTests/AndroidUISettingsTests.swift` and `DeviceSettingsTests.swift`: capability restrictions, density steps, preserving unrelated settings, error handling, reset, Resizable defaults and reconnect behavior.

Run `swift test` and `./build.sh`. The optional live test requires an explicitly named emulator:

```sh
DROIDHUB_TEST_UI_SETTINGS_ANDROID=emulator-5554 swift test
```

It changes navigation, display size and Select to Speak where available, then restores the original density, navigation and exact accessibility settings. It refuses physical-device serials. This live test does not exercise Appearance, Font Size, Show Taps or Layout Bounds; verify those separately when changing their implementation.

For a manual check, first record the original night mode, raw `font_scale`/`show_touches` values (including whether they are unset), and `debug.layout`. Exercise each control, confirm it changes the Android UI or reported value, then check Reset restores the documented defaults. Restore the original values afterward. Confirm Light/Dark/Automatic, the font slider endpoints and default step, taps injected by another tool, and Layout Bounds in an already running app. Use a test emulator, verify restoration, and do not leave TalkBack enabled or replace another accessibility service list as a smoke test. Check unsupported controls are omitted and that a failed command reports an error and reloads actual state.
