import Foundation
import Testing
@testable import DevHub

@Test func androidDemoNamesComeFromBundledHardwareProfiles() {
    #expect(DeviceProfile.modelName(for: "pixel_5") == "Pixel 5")
    #expect(DeviceProfile.modelName(for: "pixel_9_pro_xl") == "Pixel 9 Pro XL")
    #expect(DeviceProfile.modelName(for: "resizable")?.contains("Resizable") == true)
    #expect(DeviceProfile.modelName(for: "unknown-profile") == nil)
}

// Trimmed from Android Studio's sdklib nexus.xml.
@Test func parsesDeviceProfile() throws {
    let xml = """
    <d:devices xmlns:d="http://schemas.android.com/sdk/devices/7">
      <d:device>
        <d:name>Pixel Tablet</d:name>
        <d:id>pixel_tablet</d:id>
        <d:manufacturer>Google</d:manufacturer>
        <d:playstore-enabled>true</d:playstore-enabled>
        <d:hardware>
          <d:screen>
            <d:pixel-density>xhdpi</d:pixel-density>
            <d:dimensions><d:x-dimension>2560</d:x-dimension><d:y-dimension>1600</d:y-dimension></d:dimensions>
          </d:screen>
          <d:skin>pixel_tablet</d:skin>
        </d:hardware>
        <d:state name="Portrait"><d:screen-orientation>port</d:screen-orientation></d:state>
        <d:state name="Landscape" default="true"><d:screen-orientation>land</d:screen-orientation></d:state>
      </d:device>
    </d:devices>
    """
    let doc = try XMLDocument(data: Data(xml.utf8))
    let node = try #require(try doc.nodes(forXPath: "//*[local-name()='device']").first)
    let profile = try #require(DeviceProfile(node))
    #expect(profile.id == "pixel_tablet")
    #expect(profile.density == 320)
    #expect(profile.width == 2560 && profile.height == 1600)
    #expect(profile.landscape)
    #expect(DeviceProfile.dpi("420dpi") == 420)
}

@Test func writesAvdConfig() {
    let image = SystemImage(id: "system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a/", target: "android-37.0", api: "37.0",
                            abi: "arm64-v8a", tagIDs: "google_apis_playstore,page_size_16kb", tagDisplays: "Google APIs PlayStore,Page Size 16KB")
    let xml = "<d:device xmlns:d=\"x\"><d:name>Pixel 10</d:name><d:id>pixel_10</d:id><d:manufacturer>Google</d:manufacturer><d:playstore-enabled>true</d:playstore-enabled><d:pixel-density>420dpi</d:pixel-density><d:x-dimension>1080</d:x-dimension><d:y-dimension>2424</d:y-dimension></d:device>"
    let node = try! XMLDocument(data: Data(xml.utf8)).rootElement()!
    let config = AVD.config(name: "Pixel 10 (2)", device: DeviceProfile(node)!, image: image, skinPath: nil)
    for line in ["AvdId=Pixel_10__2_", "avd.ini.displayname=Pixel 10 (2)", "hw.lcd.density=420", "hw.cpu.arch=arm64",
                 "PlayStore.enabled=true", "tag.id=google_apis_playstore", "image.sysdir.1=system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a/",
                 "skin.name=1080x2424", "target=android-37.0"] {
        #expect(config.contains(line + "\n"), "missing \(line)")
    }
}
