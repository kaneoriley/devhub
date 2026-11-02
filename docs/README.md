# Integration maintenance

DroidHub integrates Android SDK tools, scrcpy, and frameworks supplied by the selected Xcode installation. Before changing an integration, check its current upstream implementation rather than guessing from a screenshot or an old API example.

- [Android emulator configuration](android-emulator-configuration.md): settings, compatibility, defaults, serialization, and SD card creation.
- [Other upstream integrations](upstream-integrations.md): hardware catalogs, display controls, scrcpy, Apple devices, and simulator settings.

Keep user-facing functionality and setup instructions in the root README. Keep implementation sources, compatibility notes, and maintenance procedures here. Record which upstream revision or installed tool version was checked when changing an integration, and update the relevant regression tests.
