import SwiftUI
import AppKit

enum Panel: String, CaseIterable {
    case info, settings
    var title: String { rawValue.capitalized }
    var icon: String { self == .info ? "info" : "slider.horizontal.3" }
}

struct InspectorGeometry {
    var width: CGFloat
    var progress: CGFloat
    func toolbarOffset(inspectorControlsWidth: CGFloat) -> CGFloat { max(0, width - inspectorControlsWidth - 8) * progress }
}

/// One animation clock lays out the sidebar and moves the actual native toolbar
/// items. The sidebar's full width is known before either transition starts.
struct DeviceInspector<Sidebar: View>: ViewModifier, Animatable {
    @Binding var panel: Panel?
    @Binding var width: Double
    let connected: Bool
    let volumeDown: () -> Void
    let volumeUp: () -> Void
    let power: () -> Void
    var progress: CGFloat
    @ViewBuilder var sidebar: (Panel) -> Sidebar
    @State private var lastPanel = Panel.settings
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let geometry = InspectorGeometry(width: CGFloat(width), progress: progress)
        content
            .inspector(isPresented: Binding(get: { panel != nil }, set: { if !$0 { panel = nil } })) {
                sidebar(panel ?? lastPanel)
                    .inspectorColumnWidth(CGFloat(width))
            }
            .toolbar {
                DeviceToolbar(panel: $panel, geometry: geometry,
                              connected: connected, volumeDown: volumeDown, volumeUp: volumeUp, power: power)
            }
            .onChange(of: panel, initial: true) { _, selected in if let selected { lastPanel = selected } }
    }
}

struct DeviceToolbar: ToolbarContent {
    @Binding var panel: Panel?
    let geometry: InspectorGeometry
    let connected: Bool
    let volumeDown: () -> Void
    let volumeUp: () -> Void
    let power: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if connected {
                Button("Volume Down", systemImage: "speaker.wave.1", action: volumeDown)
                Button("Volume Up", systemImage: "speaker.wave.3", action: volumeUp)
                Button("Power", systemImage: "power", action: power)
                    .background { NativeToolbarAlignment(geometry: geometry).frame(width: 0, height: 0) }
            }
        }
        if connected {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ForEach(Panel.allCases, id: \.self) { item in
                Button(item.title, systemImage: item.icon) {
                    withAnimation(.easeInOut(duration: 0.24)) { panel = panel == item ? nil : item }
                }
                .buttonBorderShape(.circle)
                .modifier(InspectorSelectionStyle(selected: panel == item))
                .accessibilityAddTraits(panel == item ? .isSelected : [])
            }
        }
    }
}

/// Reserve a square toolbar slot and inset selection like the native hover fill.
private struct InspectorSelectionStyle: ViewModifier {
    let selected: Bool
    @Environment(\.controlActiveState) private var activeState
    func body(content: Content) -> some View {
        content
            .frame(minWidth: 36, minHeight: 36)
            .background {
                Circle()
                    .fill(.primary.opacity(activeState == .inactive ? 0.12 : 0.18))
                    .padding(4)
                    .opacity(selected ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}

/// SwiftUI's toolbar spacer cannot be resized continuously. Align the existing
/// native button group with the inspector instead, preserving system styling.
private struct NativeToolbarAlignment: NSViewRepresentable {
    let geometry: InspectorGeometry
    func makeNSView(context: Context) -> ToolbarAlignmentView { ToolbarAlignmentView() }
    func updateNSView(_ view: ToolbarAlignmentView, context: Context) { view.setGeometry(geometry) }
}

final class ToolbarAlignmentView: NSView {
    private var geometry = InspectorGeometry(width: 300, progress: 0)
    private weak var controls: NSView?
    private weak var anchor: NSView?
    private var aligning = false

    override var intrinsicContentSize: NSSize { NSSize(width: 0, height: 0) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        discoverGroups()
        DispatchQueue.main.async { [weak self] in self?.discoverGroups() }
    }

    func setGeometry(_ geometry: InspectorGeometry) {
        self.geometry = geometry
        if controls == nil { discoverGroups() }
        alignGroups()
    }

    private func discoverGroups() {
        NotificationCenter.default.removeObserver(self)
        controls = nil; anchor = nil
        guard let items = window?.toolbar?.items,
              let index = items.firstIndex(where: { $0.view.map { self.isDescendant(of: $0) } == true }),
              index >= 2, let host = items[index].view,
              let next = items.dropFirst(index + 1).first(where: { $0.view != nil })?.view else { return }
        let volumeViews = items[(index - 2)...index].compactMap(\.view)
        let remainingViews = items.dropFirst(index + 1).compactMap(\.view)
        let otherViews = items.compactMap(\.view).filter { view in !volumeViews.contains(where: { $0 === view }) }
        controls = Self.group(containing: host, excluding: otherViews)
        anchor = Self.group(containing: next, excluding: items.compactMap(\.view).filter { view in
            !remainingViews.contains(where: { $0 === view })
        })
        for view in [controls, anchor].compactMap({ $0 }) {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(alignGroups), name: NSView.frameDidChangeNotification, object: view)
        }
        alignGroups()
    }

    /// Find the group's outer container without depending on private AppKit classes.
    static func group(containing member: NSView, excluding others: [NSView]) -> NSView {
        var group = member
        while let parent = group.superview,
              !others.contains(where: { $0 === parent || $0.isDescendant(of: parent) }) {
            group = parent
        }
        return group
    }

    static func align(_ controls: NSView, before anchor: NSView, offset: CGFloat) {
        guard let parent = controls.superview else { return }
        let right = anchor.convert(anchor.bounds, to: parent).minX - 8 - offset
        let origin = NSPoint(x: right - controls.frame.width, y: controls.frame.minY)
        if abs(controls.frame.minX - origin.x) > 0.001 { controls.setFrameOrigin(origin) }
    }

    @objc private func alignGroups() {
        guard !aligning, let controls, let anchor else { return }
        aligning = true
        Self.align(controls, before: anchor, offset: geometry.toolbarOffset(inspectorControlsWidth: anchor.frame.width))
        aligning = false
    }
}
