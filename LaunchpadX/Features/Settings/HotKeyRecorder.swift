import AppKit
import SwiftUI

struct HotKeyRecorder: NSViewRepresentable {
    @Binding var hotKey: HotKey
    let requiresModifier: Bool
    var onBegin: () -> Void = {}
    var onCancel: () -> Void = {}
    let onCommit: (HotKey) -> Void

    func makeNSView(context: Context) -> KeyCaptureButton {
        let button = KeyCaptureButton()
        button.onCapture = onCommit
        button.onBegin = onBegin
        button.onCancel = onCancel
        button.requiresModifier = requiresModifier
        button.hotKey = hotKey
        return button
    }

    func updateNSView(_ nsView: KeyCaptureButton, context: Context) {
        nsView.onCapture = onCommit
        nsView.onBegin = onBegin
        nsView.onCancel = onCancel
        if !nsView.isRecording { nsView.hotKey = hotKey }
    }

    static func dismantleNSView(_ nsView: KeyCaptureButton, coordinator: ()) {
        nsView.cancelRecording()
    }
}

final class KeyCaptureButton: NSButton {
    var hotKey: HotKey = .defaultLauncher { didSet { if !isRecording { updateTitle(hotKey.displayString) } } }
    var requiresModifier = true
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCapture: ((HotKey) -> Void)?
    private(set) var isRecording = false
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 170, height: 30))
        bezelStyle = .rounded
        updateTitle(HotKey.defaultLauncher.displayString)
        target = self
        action = #selector(beginRecording)
        setAccessibilityIdentifier("settings.hotKeyRecorder")
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    @objc private func beginRecording() {
        guard !isRecording, let window else { return }
        isRecording = true
        onBegin?()
        updateTitle("请按下快捷键（Esc 取消）")
        guard window.makeFirstResponder(self) else { cancelRecording(); return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, self.isRecording, self.window === window else { return event }
            self.capture(event)
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.cancelRecording() } }
    }

    override func keyDown(with event: NSEvent) {
        capture(event)
    }

    private func capture(_ event: NSEvent) {
        guard isRecording else { return }
        if event.keyCode == 53 { cancelRecording(); return }
        let modifiers = HotKey.carbonModifiers(from: event.modifierFlags)
        guard !requiresModifier || modifiers != 0 else { NSSound.beep(); return }
        let value = HotKey(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
        endRecording()
        onCapture?(value)
    }

    func cancelRecording() {
        guard isRecording else { return }
        endRecording()
        onCancel?()
    }

    private func endRecording() {
        isRecording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        updateTitle(hotKey.displayString)
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    private func updateTitle(_ value: String) {
        title = value
        setAccessibilityLabel(value)
    }

}
