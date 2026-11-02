# Integration maintenance

DevHub integrates Android SDK tools, scrcpy, and frameworks supplied by the selected Xcode installation. Before changing an integration, check its current upstream implementation rather than guessing from a screenshot or an old API example.

- [Android emulator configuration](android-emulator-configuration.md): settings, compatibility, defaults, serialization, and SD card creation.
- [Android runtime settings](android-runtime-settings.md): appearance, navigation, accessibility, font/display size, Show Taps, Layout Bounds, compatibility and reset rules.
- [Other upstream integrations](upstream-integrations.md): hardware catalogs, display controls, scrcpy, Apple devices, and simulator settings.
- [Local installation and upgrades](installation.md): source fingerprints, embedded checkout paths, build progress, and safe app replacement/relaunch.

Keep user-facing functionality and setup instructions in the root README. Keep implementation sources, compatibility notes, and maintenance procedures here. Record which upstream revision or installed tool version was checked when changing an integration, and update the relevant regression tests.

The inspector separates read-only device information from runtime settings. Device logs and crash analysis belong in dedicated tools such as Android Studio or Xcode; DevHub has no log/crash viewer or collector.
