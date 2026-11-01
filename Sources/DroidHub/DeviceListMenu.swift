import AppKit
import SwiftUI

struct DeviceListMenu: View {
    @State private var presenter = DeviceListMenuPresenter()

    var body: some View {
        Button { presenter.show() } label: {
            Label("Filter and Sort Devices", systemImage: "line.3.horizontal.decrease")
                .imageScale(.large)
        }
        .background(DeviceListMenuAnchor(presenter: presenter).allowsHitTesting(false))
        .help("Filter and sort devices")
        .accessibilityLabel("Filter and Sort Devices")
    }
}

/// AppKit owns menu tracking, independently of SwiftUI's live device updates.
@MainActor final class DeviceListMenuPresenter: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    weak var anchor: NSView?
    private var filters: [(NSMenuItem, DeviceFilter)] = []
    private var sorts: [(NSMenuItem, DeviceSort)] = []
    private let groups = NSMenuItem(title: "Show Groups", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        for filter in DeviceFilter.allCases {
            let item = NSMenuItem(title: filter.title, action: #selector(selectFilter(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = filter.rawValue
            menu.addItem(item); filters.append((item, filter))
        }
        menu.addItem(.separator())
        let sortMenu = NSMenu(title: "Sort By")
        sortMenu.autoenablesItems = false; sortMenu.delegate = self
        for sort in DeviceSort.allCases {
            let item = NSMenuItem(title: sort.title, action: #selector(selectSort(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = sort.rawValue
            sortMenu.addItem(item); sorts.append((item, sort))
            if sort == .availability { sortMenu.addItem(.separator()) }
        }
        sortMenu.addItem(.separator())
        groups.target = self; groups.action = #selector(toggleGroups)
        sortMenu.addItem(groups)
        let submenu = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        submenu.submenu = sortMenu
        menu.addItem(submenu)
    }

    func show() {
        guard let anchor, anchor.window != nil else { return }
        updateChecks()
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.minX, y: anchor.bounds.maxY + 6), in: anchor)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateChecks() }

    private func updateChecks() {
        let defaults = UserDefaults.standard
        let filter = defaults.string(forKey: "deviceList.filter") ?? DeviceFilter.all.rawValue
        let sort = defaults.string(forKey: "deviceList.sort") ?? DeviceSort.availability.rawValue
        for (item, value) in filters { item.state = value.rawValue == filter ? .on : .off }
        for (item, value) in sorts { item.state = value.rawValue == sort ? .on : .off }
        groups.state = (defaults.object(forKey: "deviceList.showGroups") as? Bool ?? true) ? .on : .off
    }

    @objc private func selectFilter(_ item: NSMenuItem) {
        UserDefaults.standard.set(item.representedObject, forKey: "deviceList.filter")
    }
    @objc private func selectSort(_ item: NSMenuItem) {
        UserDefaults.standard.set(item.representedObject, forKey: "deviceList.sort")
    }
    @objc private func toggleGroups() {
        let defaults = UserDefaults.standard
        defaults.set(!(defaults.object(forKey: "deviceList.showGroups") as? Bool ?? true), forKey: "deviceList.showGroups")
    }
}

private struct DeviceListMenuAnchor: NSViewRepresentable {
    let presenter: DeviceListMenuPresenter
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        presenter.anchor = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { presenter.anchor = view }
    private final class AnchorView: NSView {
        override var isFlipped: Bool { true }
    }
}
