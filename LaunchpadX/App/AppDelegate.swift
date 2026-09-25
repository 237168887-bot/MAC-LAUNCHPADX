import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()
    private var statusItem: NSStatusItem?
    private var statusItemImage: NSImage?
    private var shouldRun = true
    private var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains { $0.localizedCaseInsensitiveContains("xctest") }
            || ProcessInfo.processInfo.arguments.contains("--show-launcher-for-ui-testing")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isRunningUnderXCTest else { return }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let anotherInstance = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let anotherInstance else { return }
        anotherInstance.activate(options: [.activateAllWindows])
        shouldRun = false
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard shouldRun else { return }
        applyApplicationIcon()
        applyActivationPolicy()
        configureStatusItem()
        environment.start()
        if ProcessInfo.processInfo.arguments.contains("--show-launcher-for-ui-testing") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.environment.launcherWindowController.show()
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-switch-to-fullscreen") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.environment.settings.presentationMode = .fullScreen
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-selecting-mode") {
                    self.environment.launcherViewModel.toggleMultiSelecting()
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--show-settings-for-ui-testing") {
            DispatchQueue.main.async { [weak self] in self?.environment.showSettings() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        environment.launcherWindowController.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.stop()
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(.regular)
    }

    private func applyApplicationIcon() {
        if let icon = NSImage(named: NSImage.Name("AppIcon")) {
            NSApp.applicationIconImage = icon
        }
    }

    func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let sourceImage = NSApp.applicationIconImage {
            let image = Self.makeStatusItemImage(from: sourceImage)
            statusItemImage = image
            item.button?.image = image
            item.button?.imagePosition = .imageOnly
            item.button?.imageScaling = .scaleProportionallyDown
        }
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open LaunchpadX"), action: #selector(openLauncher), keyEquivalent: "")
        menu.addItem(withTitle: "编辑布局", action: #selector(editLayout), keyEquivalent: "")
        menu.addItem(withTitle: "选择应用", action: #selector(selectApplications), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Settings"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: String(localized: "Rescan Applications"), action: #selector(rescan), keyEquivalent: "r")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: String(localized: "Quit LaunchpadX"), action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        item.isVisible = environment.settings.showMenuBarIcon
        statusItem = item
        environment.settings.onMenuBarVisibilityChanged = { [weak self] visible in
            self?.statusItem?.isVisible = visible
        }
    }

    static func makeStatusItemImage(from sourceImage: NSImage) -> NSImage {
        let image = (sourceImage.copy() as? NSImage) ?? NSImage(size: sourceImage.size)
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }

    @objc private func openLauncher() { environment.launcherWindowController.show() }
    @objc func editLayout() {
        let viewModel = environment.launcherViewModel
        if viewModel.isMultiSelecting { viewModel.toggleMultiSelecting() }
        environment.launcherWindowController.show()
        viewModel.beginEditing()
    }
    @objc func selectApplications() {
        let viewModel = environment.launcherViewModel
        if viewModel.isEditing { viewModel.endEditing() }
        environment.launcherWindowController.show()
        if !viewModel.isMultiSelecting { viewModel.toggleMultiSelecting() }
    }
    @objc private func openSettings() { environment.showSettings() }
    @objc private func rescan() { Task { await environment.launcherViewModel.rescan() } }
    @objc private func quit() { NSApp.terminate(nil) }
}
