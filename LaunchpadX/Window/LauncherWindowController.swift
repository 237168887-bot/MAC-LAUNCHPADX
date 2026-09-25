import AppKit
import SwiftUI

@MainActor
final class LauncherPointerRouter {
    var gridFrame: CGRect = .zero
    var tileFrames: [CGRect] = []
    var isSuspended: () -> Bool = { false }
    var onBlankClick: () -> Void = {}

    private var blankMouseDown: CGPoint?

    func consume(_ event: NSEvent, in window: NSWindow) -> Bool {
        if let blankMouseDown {
            switch event.type {
            case .leftMouseDragged:
                return true
            case .leftMouseUp:
                self.blankMouseDown = nil
                if let point = contentPoint(for: event, in: window),
                   hypot(point.x - blankMouseDown.x, point.y - blankMouseDown.y) <= 5 {
                    onBlankClick()
                }
                return true
            default:
                break
            }
        }

        guard event.type == .leftMouseDown,
              !isSuspended(),
              !tileFrames.isEmpty,
              let point = contentPoint(for: event, in: window),
              gridFrame.contains(point),
              !tileFrames.contains(where: { $0.contains(point) }) else { return false }
        blankMouseDown = point
        return true
    }

    private func contentPoint(for event: NSEvent, in window: NSWindow) -> CGPoint? {
        guard let contentView = window.contentView else { return nil }
        let local = contentView.convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: contentView.isFlipped ? local.y : contentView.bounds.height - local.y)
    }
}

final class LauncherWindow: NSWindow {
    var pointerRouter: LauncherPointerRouter?

    override func sendEvent(_ event: NSEvent) {
        if pointerRouter?.consume(event, in: self) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class LauncherWindowController: NSWindowController {
    private let viewModel: LauncherViewModel
    private let settings: SettingsStore

    init(viewModel: LauncherViewModel, settings: SettingsStore) {
        self.viewModel = viewModel
        self.settings = settings
        super.init(window: Self.makeWindow(mode: settings.presentationMode,
                                           viewModel: viewModel,
                                           settings: settings))
        viewModel.onDismiss = { [weak self] in self?.hide() }
        settings.onPresentationModeChanged = { [weak self] in self?.synchronizeWindowMode() }
    }

    required init?(coder: NSCoder) { nil }

    func toggle() {
        if window?.isVisible == true { hide() } else { show() }
    }

    func show() {
        synchronizeWindowMode()
        guard let window else { return }
        let screen = selectedScreen()
        if let panel = window as? LauncherPanel {
            panel.setFrame(screen.frame, display: true)
        } else if !window.isVisible {
            let size = NSSize(width: 1_040, height: 760)
            let visible = screen.visibleFrame
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        window.alphaValue = 0
        if window is LauncherPanel { window.orderFrontRegardless() }
        else { window.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        viewModel.prepareForPresentation()
        let duration = motionDuration(normal: 0.22)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel = window else { return }
        viewModel.cancelTransientEditing()
        let duration = motionDuration(normal: 0.16)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }, completionHandler: { Task { @MainActor in panel.orderOut(nil) } })
    }

    private func synchronizeWindowMode() {
        let currentMode: LauncherPresentationMode = window is LauncherPanel ? .fullScreen : .window
        guard currentMode != settings.presentationMode else { return }
        let wasVisible = window?.isVisible == true
        window?.orderOut(nil)
        window = Self.makeWindow(mode: settings.presentationMode, viewModel: viewModel, settings: settings)
        if wasVisible { show() }
    }

    private static func makeWindow(
        mode: LauncherPresentationMode,
        viewModel: LauncherViewModel,
        settings: SettingsStore
    ) -> NSWindow {
        let window: NSWindow
        switch mode {
        case .fullScreen:
            window = LauncherPanel()
        case .window:
            let frame = NSRect(x: 0, y: 0, width: 1_040, height: 760)
            let standard = LauncherWindow(contentRect: frame,
                                    styleMask: [.titled, .resizable, .fullSizeContentView],
                                    backing: .buffered,
                                    defer: false)
            standard.titleVisibility = .hidden
            standard.titlebarAppearsTransparent = true
            standard.backgroundColor = .clear
            standard.isOpaque = false
            standard.standardWindowButton(.closeButton)?.isHidden = true
            standard.standardWindowButton(.miniaturizeButton)?.isHidden = true
            standard.standardWindowButton(.zoomButton)?.isHidden = true
            standard.minSize = NSSize(width: 720, height: 520)
            standard.isReleasedWhenClosed = false
            standard.setFrameAutosaveName("LaunchpadXWindow")
            standard.center()
            window = standard
        }
        window.collectionBehavior = [.canJoinAllApplications, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let pointerRouter = LauncherPointerRouter()
        pointerRouter.isSuspended = { [weak viewModel] in
            guard let viewModel else { return true }
            return viewModel.isDraggingSession || viewModel.openedFolderID != nil
        }
        pointerRouter.onBlankClick = { [weak viewModel] in
            guard let viewModel else { return }
            if viewModel.isEditing { viewModel.endEditing() }
            if viewModel.openedFolderID != nil { viewModel.closeFolder() }
            else { viewModel.onDismiss?() }
        }
        if let panel = window as? LauncherPanel { panel.pointerRouter = pointerRouter }
        if let standard = window as? LauncherWindow { standard.pointerRouter = pointerRouter }
        window.contentView = NSHostingView(rootView: LauncherView(
            viewModel: viewModel, settings: settings, pointerRouter: pointerRouter
        ))
        return window
    }

    private func selectedScreen() -> NSScreen {
        let screens = NSScreen.screens
        let selected: NSScreen?
        switch settings.displayStrategy {
        case .cursor:
            selected = screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        case .primary:
            selected = NSScreen.main
        case .lastUsed:
            selected = screens.first { $0.displayID == settings.lastDisplayID }
        case .fixed:
            selected = screens.first { $0.displayID == settings.fixedDisplayID }
        }
        let screen = selected ?? NSScreen.main ?? screens[0]
        settings.lastDisplayID = screen.displayID
        return screen
    }

    private func motionDuration(normal: TimeInterval) -> TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : normal
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
