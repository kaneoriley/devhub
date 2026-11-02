import Foundation
import Testing
@testable import DevHub

private let phoneType = "com.apple.CoreSimulator.SimDeviceType.Phone"
private let duoType = "com.apple.CoreSimulator.SimDeviceType.Duo"
private let ios27 = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
private let ios271 = "com.apple.CoreSimulator.SimRuntime.iOS-27-1"

private func creationCatalog(devices: [String: [[String: Any]]]? = nil, defaults: Set<String> = []) throws -> SimulatorCatalog {
    let data = Data(#"""
    {"runtimes":[
      {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-17-5","name":"iOS 17.5","version":"17.5","isAvailable":true},
      {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","name":"iOS 27.0","version":"27.0","isAvailable":true,"supportedDeviceTypes":[
        {"identifier":"com.apple.CoreSimulator.SimDeviceType.Phone","name":"iPhone","productFamily":"iPhone"},
        {"identifier":"com.apple.CoreSimulator.SimDeviceType.Pad","name":"iPad","productFamily":"iPad"}]},
      {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-1","name":"iOS 27.1","version":"27.1","isAvailable":true,"supportedDeviceTypes":[
        {"identifier":"com.apple.CoreSimulator.SimDeviceType.Duo","name":"iPhone Duo","productFamily":"iPhone"}]},
      {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","name":"iOS 18.0","version":"18.0","isAvailable":false},
      {"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-27-0","name":"watchOS 27.0","version":"27.0","isAvailable":true}],
     "devicetypes":[
      {"identifier":"com.apple.CoreSimulator.SimDeviceType.Phone","name":"iPhone","productFamily":"iPhone","minRuntimeVersion":1769472},
      {"identifier":"com.apple.CoreSimulator.SimDeviceType.Duo","name":"iPhone Duo","productFamily":"iPhone","minRuntimeVersion":1769728},
      {"identifier":"legacy","name":"Older iPhone","productFamily":"iPhone","minRuntimeVersion":917504,"maxRuntimeVersion":1179391},
      {"identifier":"pad","name":"iPad","productFamily":"iPad","minRuntimeVersion":1048576},
      {"identifier":"tv","name":"Apple TV","productFamily":"Apple TV"}],
     "devices":{"runtime":[{"name":"iPhone"},{"name":"iPhone (2)"}]}}
    """#.utf8)
    var inventory = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    if let devices { inventory["devices"] = devices }
    return try SimulatorCatalog.parse(JSONSerialization.data(withJSONObject: inventory), defaultDeviceIDs: defaults)
}

@Test func simulatorCreationOffersInstalledIOSVersionsAndCompatibleModels() throws {
    let catalog = try creationCatalog()
    #expect(catalog.runtimes.map(\.version) == ["27.1", "27.0", "17.5"])
    #expect(catalog.models(for: catalog.runtimes[0]).map(\.id) == [duoType])
    #expect(catalog.models(for: catalog.runtimes[1]).map(\.id) == [phoneType, "com.apple.CoreSimulator.SimDeviceType.Pad"])
    // Older Xcodes without runtime-specific model lists use each model's OS bounds.
    #expect(catalog.models(for: catalog.runtimes[2]).map(\.id) == ["legacy", "pad"])
    #expect(catalog.uniqueName(for: catalog.models(for: catalog.runtimes[1])[0]) == "iPhone (3)")
}

private actor SimulatorCreationRecorder {
    var calls: [[String]] = []
    let result: ToolResult
    init(status: Int32 = 0, output: String = "A2E12D33-1CB6-46E8-9EB0-E7BF1C32F8C9\n") { result = ToolResult(status: status, output: output) }
    func run(_ args: [String]) -> ToolResult { calls.append(args); return result }
}

@Test func simulatorCreationPassesTheChosenNameModelAndRuntimeWithoutShellInterpolation() async throws {
    let recorder = SimulatorCreationRecorder(), catalog = try creationCatalog()
    let id = try await catalog.create(name: " My Phone's $name `test` ", modelID: phoneType, runtimeID: ios27) { await recorder.run($0) }
    #expect(id == "A2E12D33-1CB6-46E8-9EB0-E7BF1C32F8C9")
    #expect(await recorder.calls == [["create", "My Phone's $name `test`", phoneType, ios27]])
}

@Test func simulatorCreationRejectsInvalidOrIncompatibleChoicesBeforeCreatingAnything() async throws {
    let recorder = SimulatorCreationRecorder(), catalog = try creationCatalog()
    for (name, model, runtime) in [("   ", phoneType, ios27), ("a\nb", phoneType, ios27),
                                    ("Phone", duoType, ios27), ("Phone", phoneType, ios271),
                                    ("Phone", phoneType, "missing")] {
        await #expect(throws: (any Error).self) {
            _ = try await catalog.create(name: name, modelID: model, runtimeID: runtime) { await recorder.run($0) }
        }
    }
    #expect(await recorder.calls.isEmpty)
}

@Test func simulatorCreationReportsNativeFailuresAndInvalidResponses() async throws {
    let catalog = try creationCatalog()
    for recorder in [SimulatorCreationRecorder(status: 1, output: "Runtime is unavailable"), SimulatorCreationRecorder(output: "not a UUID")] {
        await #expect(throws: (any Error).self) {
            _ = try await catalog.create(name: "Phone", modelID: phoneType, runtimeID: ios27) { await recorder.run($0) }
        }
    }
}

/// Opt in to create and remove a new, never-booted fixture. Existing devices are untouched.
@Test func simulatorCreationAndDeletionRoundTrip() async throws {
    guard ProcessInfo.processInfo.environment["DEVHUB_TEST_SIMULATOR_LIFECYCLE"] == "1" else { return }
    // Do not adopt (and later delete) an existing default device in this fixture.
    let snapshot = try await Simctl.run(["list", "--json"])
    try snapshot.checked()
    let catalog = try SimulatorCatalog.parse(Data(snapshot.output.utf8))
    let runtime = try #require(catalog.runtimes.first)
    let model = try #require(catalog.models(for: runtime).first)
    let id = try await catalog.create(name: "DevHub Lifecycle Test \(UUID().uuidString)", modelID: model.id, runtimeID: runtime.id)
    do {
        let inventory = try await Simctl.run(["list", "devices", "--json"])
        try inventory.checked()
        #expect(inventory.output.contains(id))
        try await Simctl.deleteSimulator(id)
        let remaining = try await Simctl.run(["list", "devices", "--json"])
        try remaining.checked()
        #expect(!remaining.output.contains(id))
    } catch {
        try? await Simctl.deleteSimulator(id)
        throw error
    }
}


@Test func simulatorCreationReconcilesFormFactorVersionAndModelTogether() throws {
    let catalog = try creationCatalog()
    var choice = SimulatorCreationSelection()
    choice.reconcile(catalog)
    #expect(choice.kind == .phone && choice.runtimeID == ios27 && choice.modelID == phoneType)
    choice.kind = .foldable
    choice.reconcile(catalog)
    #expect(choice.runtimeID == ios271 && choice.modelID == duoType)
    choice.kind = .tablet
    choice.reconcile(catalog)
    #expect(choice.runtimeID == ios27 && choice.modelID == "com.apple.CoreSimulator.SimDeviceType.Pad")
    choice.runtimeID = "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
    choice.reconcile(catalog)
    #expect(choice.modelID == "pad")
    choice.kind = .phone
    choice.reconcile(catalog)
    #expect(choice.runtimeID.hasSuffix("17-5") && choice.modelID == "legacy")
    choice.reconcile(catalog)
    #expect(choice.modelID == "legacy")
}

private let unusedID = "B986F114-0057-46E7-9B85-BF1C7AE4B156"
private func unusedDevice(state: String = "Shutdown", lastUsed: String? = nil) -> [String: Any] {
    var device: [String: Any] = ["udid": unusedID, "name": "iPhone", "state": state, "isAvailable": true, "deviceTypeIdentifier": phoneType]
    if let lastUsed { device["lastUsedAt"] = lastUsed }
    return device
}

private actor ReuseRecorder {
    var calls: [[String]] = []
    let devices: [String: [[String: Any]]]
    init(_ devices: [String: [[String: Any]]]) { self.devices = devices }
    func run(_ args: [String]) throws -> ToolResult {
        calls.append(args)
        if args.first == "list" {
            return ToolResult(status: 0, output: String(decoding: try JSONSerialization.data(withJSONObject: ["devices": devices]), as: UTF8.self))
        }
        return ToolResult(status: 0, output: "A2E12D33-1CB6-46E8-9EB0-E7BF1C32F8C9")
    }
}

@Test func simulatorCreationAdoptsUnusedMatchingDefaultWithoutNumberedNameOrDuplicate() async throws {
    let devices = [ios27: [unusedDevice()]]
    let catalog = try creationCatalog(devices: devices, defaults: [unusedID])
    let model = catalog.models(for: catalog.runtimes[1])[0]
    #expect(catalog.uniqueName(for: model, runtimeID: ios27) == "iPhone")
    let recorder = ReuseRecorder(devices)
    let id = try await catalog.create(name: "iPhone", modelID: phoneType, runtimeID: ios27) { try await recorder.run($0) }
    #expect(id == unusedID)
    #expect(await recorder.calls == [["list", "devices", "--json"]])
    let custom = ReuseRecorder(devices)
    _ = try await catalog.create(name: "My Phone", modelID: phoneType, runtimeID: ios27) { try await custom.run($0) }
    #expect(await custom.calls == [["list", "devices", "--json"], ["rename", unusedID, "My Phone"]])
}

@Test func simulatorCreationDoesNotReuseUsedRunningOrExplicitlyCreatedDevicesOrAnotherRuntime() async throws {
    for (devices, defaults) in [([ios27: [unusedDevice(state: "Booted")]], Set([unusedID])),
                                ([ios27: [unusedDevice(lastUsed: "2026-11-01")]], Set([unusedID])),
                                ([ios27: [unusedDevice()]], Set<String>()),
                                ([ios271: [unusedDevice()]], Set([unusedID]))] {
        let catalog = try creationCatalog(devices: devices, defaults: defaults)
        let recorder = ReuseRecorder(devices)
        _ = try await catalog.create(name: "iPhone (2)", modelID: phoneType, runtimeID: ios27) { try await recorder.run($0) }
        #expect(await recorder.calls == [["create", "iPhone (2)", phoneType, ios27]])
    }
}

@Test func simulatorReuseRechecksThatTheDefaultIsStillUnusedAndShutdown() async throws {
    let catalog = try creationCatalog(devices: [ios27: [unusedDevice()]], defaults: [unusedID])
    for current in [unusedDevice(state: "Booted"), unusedDevice(lastUsed: "2026-11-01")] {
        let recorder = ReuseRecorder([ios27: [current]])
        await #expect(throws: (any Error).self) {
            _ = try await catalog.create(name: "iPhone", modelID: phoneType, runtimeID: ios27) { try await recorder.run($0) }
        }
        #expect(await recorder.calls == [["list", "devices", "--json"]])
    }
}
