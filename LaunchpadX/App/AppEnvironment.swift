import Foundation
import Carbon
import SwiftData

@MainActor
final class AppEnvironment {
    private enum ScanPolicy {
        static let initialDelay: Duration = .milliseconds(700)
    }

    let container: ModelContainer
    let repository: LayoutRepository
    let settings: SettingsStore
    let discovery: ApplicationDiscoveryService
    let launcher: ApplicationLauncherService
    let icons: IconProvider
    let searchIndex: SearchIndex
    let monitor: ApplicationMonitor
    let launchOSLayoutImporter: LaunchOSLayoutImporter
    let hotKeyManager: HotKeyManager
    let f4HotKeyManager: HotKeyManager
    let trackpadWakeService: TrackpadWakeService
    let hotCornerMonitor: HotCornerMonitor
    let loginItems: LoginItemManager
    let launcherViewModel: LauncherViewModel
    let launcherWindowController: LauncherWindowController
    lazy var settingsWindowController = SettingsWindowController(environment: self)
    private var scheduledScanTask: Task<Void, Never>?

    init() {
        do {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-isolated-data") {
                container = try ModelContainer(
                    for: LauncherSchemaV1.schema,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } else {
                container = try ModelContainer(for: LauncherSchemaV1.schema)
            }
#else
            container = try ModelContainer(for: LauncherSchemaV1.schema)
#endif
        } catch {
            fatalError("Unable to create LaunchpadX data store: \(error)")
        }
        repository = LayoutRepository(container: container)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-isolated-data") {
            let suite = "LaunchpadX.UITesting.\(UUID().uuidString)"
            settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        } else {
            settings = SettingsStore()
        }
#else
        settings = SettingsStore()
#endif
        discovery = ApplicationDiscoveryService()
        launcher = ApplicationLauncherService()
        icons = IconProvider()
        searchIndex = SearchIndex()
        monitor = ApplicationMonitor()
        launchOSLayoutImporter = LaunchOSLayoutImporter()
        hotKeyManager = HotKeyManager()
        f4HotKeyManager = HotKeyManager(identifierID: 2)
        trackpadWakeService = TrackpadWakeService()
        hotCornerMonitor = HotCornerMonitor()
        loginItems = LoginItemManager()
        launcherViewModel = LauncherViewModel(
            repository: repository,
            settings: settings,
            discovery: discovery,
            launcher: launcher,
            icons: icons,
            searchIndex: searchIndex
        )
        launcherWindowController = LauncherWindowController(viewModel: launcherViewModel, settings: settings)

        monitor.onChange = { [weak launcherViewModel] in
            Task { @MainActor in await launcherViewModel?.rescan() }
        }
        hotKeyManager.onPressed = { [weak launcherWindowController] in
            DispatchQueue.main.async { launcherWindowController?.toggle() }
        }
        f4HotKeyManager.onPressed = { [weak launcherWindowController] in
            DispatchQueue.main.async { launcherWindowController?.toggle() }
        }
        trackpadWakeService.onFiveFingerPinch = { [weak launcherWindowController] in
            launcherWindowController?.show()
        }
        hotCornerMonitor.onTrigger = { [weak launcherWindowController] in
            launcherWindowController?.show()
        }
    }

    func start() {
        do { try repository.removeObsoleteLaunchpadXBackupRecords() }
        catch { launcherViewModel.presentError(error) }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-window-mode") {
            settings.presentationMode = .window
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-scroll-grid") {
            settings.gridMode = .verticalScroll
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-option-held") {
            launcherViewModel.setOptionUninstallMode(true)
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-fixtures") {
            let fixtureCount = ProcessInfo.processInfo.arguments.contains("--ui-testing-many-fixtures") ? 160
                : ProcessInfo.processInfo.arguments.contains("--ui-testing-full-folder") ? 30 : 8
            let fixtures = (0..<fixtureCount).map { index in
                InstalledApplication(
                    bundleIdentifier: "com.launchpadx.ui-fixture.\(index)",
                    displayName: "Fixture \(index)",
                    bundleURL: URL(fileURLWithPath: "/Applications/Fixture \(index).app")
                )
            }
            launcherViewModel.loadForUITesting(fixtures)
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-existing-folder") {
                do {
                    let snapshot = try repository.snapshot(discoveredApplications: fixtures)
                    guard snapshot.entries.count >= 3 else { return }
                    if let folderID = try repository.createFolder(
                        draggedEntryID: snapshot.entries[2].id,
                        targetEntryID: snapshot.entries[1].id
                    ) {
                        if ProcessInfo.processInfo.arguments.contains("--ui-testing-full-folder") {
                            for entry in snapshot.entries.dropFirst(3).prefix(23) {
                                try repository.addRootApplication(entry.id, toFolder: folderID)
                            }
                        }
                        try repository.renameFolder(id: folderID, name: "Fixture Folder")
                        try launcherViewModel.reloadSnapshot()
                        if ProcessInfo.processInfo.arguments.contains("--ui-testing-open-folder"),
                           let folder = launcherViewModel.snapshot.entries.first(where: { $0.id == folderID }) {
                            launcherViewModel.open(folder)
                        }
                    }
                } catch {
                    launcherViewModel.presentError(error)
                }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-showcase") {
            Task {
                let applications = await discovery.scan(roots: settings.allScanRoots)
                launcherViewModel.applyScanResults(applications)
            }
            return
        }
#endif
        launcherViewModel.restoreCachedApplications()
        monitor.start(roots: settings.allScanRoots)
        startScheduledScanning()
        do { try refreshInvocationBindings() }
        catch { launcherViewModel.presentError(error) }
    }

    func stop() {
        scheduledScanTask?.cancel()
        scheduledScanTask = nil
        monitor.stop()
        hotKeyManager.unregister()
        f4HotKeyManager.unregister()
        trackpadWakeService.stop()
        hotCornerMonitor.stop()
    }

    func reregisterHotKey() throws {
        try hotKeyManager.register(effectiveLauncherHotKey)
    }

    func suspendLauncherHotKey() { hotKeyManager.unregister() }

    func registerLauncherHotKey(_ candidate: HotKey) throws {
        try hotKeyManager.register(effectiveLauncherHotKey(for: candidate))
    }

    func refreshInvocationBindings() throws {
        try hotKeyManager.register(effectiveLauncherHotKey)
        if settings.f4ShortcutEnabled {
            try f4HotKeyManager.register(HotKey(keyCode: 118, carbonModifiers: 0))
        } else {
            f4HotKeyManager.unregister()
        }
        try hotCornerMonitor.start(at: settings.hotCorner)
        if settings.trackpadWakeEnabled { trackpadWakeService.start() }
        else { trackpadWakeService.stop() }
    }

    func refreshScanRoots() {
        monitor.start(roots: settings.allScanRoots)
        Task { await launcherViewModel.rescan() }
    }

    var usesTemporaryHotKeyForLaunchOSCompatibility: Bool {
        FileManager.default.fileExists(atPath: "/Applications/LaunchOS.app")
            && settings.hotKey == .defaultLauncher
    }

    private var effectiveLauncherHotKey: HotKey {
        effectiveLauncherHotKey(for: settings.hotKey)
    }

    private func effectiveLauncherHotKey(for hotKey: HotKey) -> HotKey {
        guard FileManager.default.fileExists(atPath: "/Applications/LaunchOS.app"),
              hotKey == .defaultLauncher else { return hotKey }
        return HotKey(keyCode: 49, carbonModifiers: UInt32(optionKey | controlKey))
    }

    func showSettings() {
        settingsWindowController.show()
    }

    private func startScheduledScanning() {
        scheduledScanTask?.cancel()
        scheduledScanTask = Task(priority: .background) { [weak self] in
            do {
                try await Task.sleep(for: ScanPolicy.initialDelay)
            } catch {
                return
            }

            guard let self else { return }
            let firstScan = await self.discovery.scan(roots: self.settings.allScanRoots)
            guard !Task.isCancelled else { return }
            do {
                try self.launchOSLayoutImporter.importIfAvailable(
                    discoveredApplications: firstScan,
                    into: self.repository
                )
            } catch {
                self.launcherViewModel.presentError(error)
            }
            self.launcherViewModel.applyScanResults(firstScan)

        }
    }
}
