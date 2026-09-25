import AppKit
import ApplicationServices

@MainActor
final class HotCornerMonitor {
    var onTrigger: (() -> Void)?
    private var eventMonitor: Any?
    private var location: HotCornerLocation = .off
    private var wasInside = false

    func start(at location: HotCornerLocation) throws {
        stop()
        guard location != .off else { return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw HotCornerMonitorError.accessibilityPermissionRequired
        }
        self.location = location
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.checkPointer() }
        }
    }

    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        location = .off
        wasInside = false
    }

    private func checkPointer() {
        guard location != .off,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { return }
        let point = NSEvent.mouseLocation
        let edge: CGFloat = 3
        let inside: Bool
        switch location {
        case .off: inside = false
        case .topLeft: inside = point.x <= screen.frame.minX + edge && point.y >= screen.frame.maxY - edge
        case .topRight: inside = point.x >= screen.frame.maxX - edge && point.y >= screen.frame.maxY - edge
        case .bottomLeft: inside = point.x <= screen.frame.minX + edge && point.y <= screen.frame.minY + edge
        case .bottomRight: inside = point.x >= screen.frame.maxX - edge && point.y <= screen.frame.minY + edge
        }
        if inside && !wasInside { onTrigger?() }
        wasInside = inside
    }
}

enum HotCornerMonitorError: LocalizedError {
    case accessibilityPermissionRequired

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            String(localized: "Hot corners need Accessibility permission. Enable LaunchpadX in Privacy & Security, then select a corner again.")
        }
    }
}
