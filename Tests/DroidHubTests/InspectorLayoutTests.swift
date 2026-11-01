import AppKit
import Testing
@testable import DroidHub

@Test func inspectorAndToolbarUseTheSameProgressWithTheKnownWidthFromTheFirstFrame() {
    let width: CGFloat = 320
    for progress: CGFloat in [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1] {
        let geometry = InspectorGeometry(width: width, progress: progress)
        #expect(geometry.toolbarOffset(inspectorControlsWidth: 112) == 200 * progress)
        #expect(geometry.toolbarOffset(inspectorControlsWidth: 36) == 276 * progress)
    }
    #expect(InspectorGeometry(width: width, progress: 0.1).toolbarOffset(inspectorControlsWidth: 112) > 0)
}

@MainActor @Test func toolbarGroupTracksTheInspectorContinuouslyAndRestoresNativeSpacing() {
    let toolbar = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 52))
    let controls = NSView(frame: NSRect(x: 760, y: 8, width: 112, height: 36))
    let inspector = NSView(frame: NSRect(x: 880, y: 8, width: 112, height: 36))
    let button = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
    toolbar.addSubview(controls); toolbar.addSubview(inspector); controls.addSubview(button)
    #expect(ToolbarAlignmentView.group(containing: button, excluding: [inspector]) === controls)
    for offset: CGFloat in [0, 1, 12, 36, 90, 180, 90, 36, 12, 1, 0] {
        ToolbarAlignmentView.align(controls, before: inspector, offset: offset)
        #expect(controls.frame.maxX == inspector.frame.minX - 8 - offset)
    }
    inspector.setFrameOrigin(NSPoint(x: 900, y: 8))
    ToolbarAlignmentView.align(controls, before: inspector, offset: 180)
    #expect(controls.frame.maxX == 712)
}
