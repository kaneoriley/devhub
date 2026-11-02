import AppKit
import SwiftUI

enum NewDeviceKind: String, Identifiable, CaseIterable {
    case android, ios
    var id: Self { self }
    var title: String { self == .android ? "Android Emulator…" : "iOS Simulator…" }
}

struct NewDeviceMenu: View {
    @Binding var selection: NewDeviceKind?
    @State private var presenter = NewDeviceMenuPresenter()

    var body: some View {
        Button { presenter.show(selection: $selection) } label: {
            Label("New Device", systemImage: "plus")
        }
        .background(ToolbarMenuAnchor { presenter.anchor = $0 }.allowsHitTesting(false))
        .help("New device").accessibilityLabel("New Device")
    }
}

@MainActor private final class NewDeviceMenuPresenter: NSObject {
    private let menu = NSMenu()
    weak var anchor: NSView?
    private var choose: ((NewDeviceKind) -> Void)?

    override init() {
        super.init()
        menu.autoenablesItems = false
        for kind in NewDeviceKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(selectKind(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = kind.rawValue
            menu.addItem(item)
        }
    }

    func show(selection: Binding<NewDeviceKind?>) {
        guard let anchor, anchor.window != nil else { return }
        choose = { selection.wrappedValue = $0 }
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.minX, y: anchor.bounds.maxY + 6), in: anchor)
    }

    @objc private func selectKind(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let kind = NewDeviceKind(rawValue: raw) else { return }
        choose?(kind); choose = nil
    }
}
