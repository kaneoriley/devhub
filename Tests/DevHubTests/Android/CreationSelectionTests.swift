import Foundation
import Testing
@testable import DevHub

private func image(_ api: String, tag: String = "google_apis") -> SystemImage {
    SystemImage(id: "android-\(api)/\(tag)", target: "android-\(api)", api: api, abi: "arm64-v8a", tagIDs: tag, tagDisplays: tag)
}

@Test func androidCreationUsesFormFactorsAndGooglesModelAPIRequirements() async throws {
    let profiles = await DeviceProfile.load()
    let catalog = EmulatorCreationCatalog(devices: profiles, images: [image("37.2"), image("36.1"), image("36"), image("30"), image("37", tag: "android-wear")])
    #expect(catalog.kinds == [.phone, .tablet, .foldable, .resizable])
    let pixel10 = try #require(profiles.first { $0.id == "pixel_10" })
    #expect(!pixel10.supports(image("36")))
    #expect(pixel10.supports(image("36.1")))
    #expect(!pixel10.supports(image("37", tag: "android-wear")))
    let pixel10a = try #require(profiles.first { $0.id == "pixel_10a" })
    #expect(pixel10a.supports(image("37")))
    #expect(catalog.images(for: .resizable).map(\.api) == ["37.2", "36.1", "36"])
    #expect(catalog.models(kind: .tablet, imageID: image("30").id).allSatisfy { $0.kind == .tablet && $0.id != "pixel_tablet" })
}

@Test func androidCreationReplacesInvalidDownstreamChoicesAndKeepsValidOnes() async throws {
    let catalog = EmulatorCreationCatalog(devices: await DeviceProfile.load(), images: [image("37.2"), image("30")])
    var choice = EmulatorCreationSelection()
    choice.reconcile(catalog)
    #expect(choice.modelID == "medium_phone")
    choice.modelID = "pixel_10"
    choice.imageID = image("30").id
    choice.reconcile(catalog)
    #expect(choice.imageID == image("30").id && choice.modelID == "medium_phone")
    choice.kind = .tablet
    choice.reconcile(catalog)
    #expect(choice.imageID == image("30").id)
    #expect(catalog.models(kind: choice.kind, imageID: choice.imageID).contains { $0.id == choice.modelID })
    choice.kind = .resizable
    choice.reconcile(catalog)
    #expect(choice.imageID == image("37.2").id && choice.modelID == "resizable")
    choice.reconcile(catalog)
    #expect(choice.modelID == "resizable")
    let empty = EmulatorCreationCatalog(devices: catalog.devices, images: [])
    choice.reconcile(empty)
    #expect(choice.imageID.isEmpty && choice.modelID.isEmpty)
}
