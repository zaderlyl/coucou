import AppKit
import SwiftUI

/// Separate floating window, at the right of the screen under the island, showing the file the CLI agent is changing.
@MainActor
final class AgentFileWindow {
    static let shared = AgentFileWindow()
    private static let size = NSSize(width: 520, height: 260)
    private var panel: NSPanel?

    func show(state: AppState) {
        let panel = self.panel ?? makePanel(state: state)
        self.panel = panel
        let screen = NSScreen.main ?? NSScreen.screens[0]
        // Right-aligned so it never covers the island, just below its expanded height (160 pt).
        let origin = NSPoint(x: screen.frame.maxX - Self.size.width - 20,
                             y: screen.frame.maxY - 175 - Self.size.height)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel(state: AppState) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: AgentFileView(state: state, onClose: { [weak self] in self?.close() }))
        return panel
    }
}
