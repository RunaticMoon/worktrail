#if os(macOS)
import AppKit

/// AppKit screen coordinates put the origin at the lower-left corner.
@MainActor enum FloatingPanelPositioning {
    static func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? panel.screen ?? NSScreen.main else { return }
        let minimumFrame = panel.frameRect(forContentRect: CGRect(origin: .zero, size: panel.contentMinSize)).size
        let preferredSize = CGSize(width: max(panel.frame.width, minimumFrame.width),
                                   height: max(panel.frame.height, minimumFrame.height))
        let target = frame(for: preferredSize, near: pointer, in: screen.visibleFrame)
        let availableContent = panel.contentRect(forFrameRect: target).size
        // Keep resize constraints usable even on a screen smaller than the usual minimum.
        // Callers restore their preferred minimum on each open before placing the panel.
        panel.contentMinSize = NSSize(width: min(panel.contentMinSize.width, availableContent.width),
                                     height: min(panel.contentMinSize.height, availableContent.height))
        panel.setFrame(target, display: false)
    }

    /// Prefer below and to the right of the pointer; flip, then clamp at screen edges.
    static func frame(for size: CGSize, near pointer: CGPoint, in visibleFrame: CGRect) -> CGRect {
        let margin: CGFloat = 12
        let gap: CGFloat = 18
        let bounds = visibleFrame.insetBy(dx: min(margin, visibleFrame.width / 4),
                                         dy: min(margin, visibleFrame.height / 4))
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        var x = pointer.x + gap
        var y = pointer.y - height - gap
        if x + width > bounds.maxX { x = pointer.x - width - gap }
        if y < bounds.minY { y = pointer.y + gap }
        x = min(max(x, bounds.minX), bounds.maxX - width)
        y = min(max(y, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
#endif
