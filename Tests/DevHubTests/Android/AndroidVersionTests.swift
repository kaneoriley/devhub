import Testing
@testable import DevHub

@Test func avdMinorVersionSurvivesDevicePolling() {
    let path = "system-images/android-37.2/google_apis_ps16k/arm64-v8a/"
    let version = AndroidAPI.imageVersion(path: path)
    #expect(version == "37.2")
    #expect(AndroidAPI.label(properties: ["ro.build.version.sdk": "37"], avdVersion: version) == "API 37.2")
    #expect(AndroidAPI.imageVersion(path: "system-images/android-30/google_apis/arm64-v8a/") == "30")
    #expect(AndroidAPI.imageVersion(path: "android-37", properties: ["AndroidVersion.ApiLevel": "37.2"]) == "37.2")
}

@Test func physicalDeviceVersionUsesFullSDKWhenAvailable() {
    #expect(AndroidAPI.label(properties: ["ro.build.version.sdk": "37", "ro.build.version.sdk_full": "37.2"]) == "API 37.2")
    #expect(AndroidAPI.label(properties: ["ro.build.version.sdk": "37", "ro.build.version.sdk_full": "3700002"]) == "API 37.2")
    #expect(AndroidAPI.label(properties: ["ro.build.version.sdk": "30"]) == "API 30")
    #expect(AndroidAPI.label(properties: [:]) == nil)
}
