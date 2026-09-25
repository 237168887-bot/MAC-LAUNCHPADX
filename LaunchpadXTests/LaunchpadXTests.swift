//
//  LaunchpadXTests.swift
//  LaunchpadXTests
//
//  Created by 张航 on 2026/7/29.
//

import AppKit
import Carbon
import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import LaunchpadX

struct LaunchpadXTests {
    @MainActor
    @Test func pointerRouterClosesOnlyOnStationaryBlankClick() {
        let window = LauncherWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let router = LauncherPointerRouter()
        router.gridFrame = CGRect(x: 10, y: 10, width: 80, height: 80)
        router.tileFrames = [CGRect(x: 20, y: 20, width: 10, height: 10)]
        var dismissCount = 0
        router.onBlankClick = { dismissCount += 1 }

        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: NSPoint(x: point.x, y: 100 - point.y),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )!
        }

        #expect(router.consume(event(.leftMouseDown, at: CGPoint(x: 25, y: 25)), in: window) == false)
        #expect(router.consume(event(.leftMouseDown, at: CGPoint(x: 40, y: 40)), in: window))
        #expect(router.consume(event(.leftMouseUp, at: CGPoint(x: 40, y: 40)), in: window))
        #expect(dismissCount == 1)
        #expect(router.consume(event(.leftMouseDown, at: CGPoint(x: 40, y: 40)), in: window))
        #expect(router.consume(event(.leftMouseDragged, at: CGPoint(x: 55, y: 55)), in: window))
        #expect(router.consume(event(.leftMouseUp, at: CGPoint(x: 55, y: 55)), in: window))
        #expect(dismissCount == 1)
    }

    @MainActor
    @Test func applicationScanKeepsCurrentBundleAndResolvesDuplicatePaths() {
        let currentURL = URL(fileURLWithPath: "/Applications/LaunchpadX.app")
        let applications = [
            InstalledApplication(bundleIdentifier: "com.LaunchpadX.LaunchpadX", displayName: "Old LaunchpadX", bundleURL: URL(fileURLWithPath: "/Applications/LaunchpadX.previous.app")),
            InstalledApplication(bundleIdentifier: "com.LaunchpadX.LaunchpadX", displayName: "LaunchpadX", bundleURL: currentURL),
            InstalledApplication(bundleIdentifier: "com.apple.Safari", displayName: "Safari", bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")),
            InstalledApplication(bundleIdentifier: "com.apple.Safari", displayName: "Safari", bundleURL: URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications/Safari.app"))
        ]

        let unique = ApplicationDiscoveryService.deduplicated(applications, currentApplicationURL: currentURL)

        #expect(unique.count == 2)
        #expect(unique.first { $0.bundleIdentifier == "com.LaunchpadX.LaunchpadX" }?.bundleURL == currentURL)
        #expect(unique.filter { $0.bundleIdentifier == "com.apple.Safari" }.count == 1)
    }

    @Test func narrowWindowReducesGridColumnsFor72PointIcons() {
        #expect(LauncherView.responsiveColumnCount(availableWidth: 956, iconSize: 72, requested: 7) == 7)
        #expect(LauncherView.responsiveColumnCount(availableWidth: 636, iconSize: 72, requested: 7) == 4)
    }

    @MainActor
    @Test func obsoleteLaunchpadXRecordsAreRemovedWithoutTouchingCurrentApplication() throws {
        let container = try ModelContainer(
            for: ApplicationRecord.self, LayoutItemRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = LayoutRepository(container: container)
        let applications = [
            InstalledApplication(bundleIdentifier: "com.LaunchpadX.LaunchpadX", displayName: "LaunchpadX", bundleURL: URL(fileURLWithPath: "/Applications/LaunchpadX.app")),
            InstalledApplication(bundleIdentifier: "com.LaunchpadX.LaunchpadX", displayName: "Old LaunchpadX", bundleURL: URL(fileURLWithPath: "/Applications/LaunchpadX.obsolete-test.app"))
        ]
        try repository.reconcile(discovered: applications)

        #expect(try repository.removeObsoleteLaunchpadXBackupRecords() == 1)
        let remaining = try repository.snapshot(discoveredApplications: applications)
        #expect(remaining.entries.count == 1)
        #expect(remaining.entries.first?.application?.bundleURL.path == "/Applications/LaunchpadX.app")
    }

    @MainActor
    @Test func returningToOriginalCellRestoresPreviewBeforeReleaseAndAvoidsDuplicateImage() throws {
        let container = try ModelContainer(for: ApplicationRecord.self, LayoutItemRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repository = LayoutRepository(container: container)
        let model = LauncherViewModel(repository: repository, settings: SettingsStore(),
                                      discovery: ApplicationDiscoveryService(), launcher: ApplicationLauncherService(),
                                      icons: IconProvider(), searchIndex: SearchIndex())
        model.loadForUITesting((0..<3).map {
            InstalledApplication(bundleIdentifier: "return.\($0)", displayName: "Return \($0)",
                                 bundleURL: URL(fileURLWithPath: "/Applications/Return\($0).app"))
        })
        let entries = model.snapshot.entries
        let source = entries[0]
        model.rootGridFrame = CGRect(x: 50, y: 100, width: 900, height: 600)
        model.rootEntryFrames = [source.id: CGRect(x: 0, y: 0, width: 130, height: 120)]
        model.beginEditing()
        model.beginDraggingFromPress(source)
        model.moveDraggedEntry(toOriginalSlotOf: entries[2].id)
        #expect(model.currentPageEntries.map(\.id) != entries.map(\.id))
        model.updateRootDragLocation(CGPoint(x: 115, y: 640),
                                     windowFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(model.currentPageEntries.map(\.id) == entries.map(\.id))
        // A displaced neighbour must not steal the original cell's preview or drop.
        model.dragMoved(over: entries[1], grouping: true)
        #expect(model.currentPageEntries.map(\.id) == entries.map(\.id))
        #expect(model.performDrop(on: entries[1]))
        #expect(model.snapshot.entries.map(\.id) == entries.map(\.id))
        #expect(model.isDragging(source))
        model.completeDraggingFromSourceIfNeeded()
        #expect(!model.isDragging(source))
    }

    @MainActor
    @Test func droppingApplicationOnAnotherApplicationsIconCreatesFolderImmediately() throws {
        let container = try ModelContainer(
            for: ApplicationRecord.self, LayoutItemRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let model = LauncherViewModel(
            repository: LayoutRepository(container: container), settings: SettingsStore(),
            discovery: ApplicationDiscoveryService(), launcher: ApplicationLauncherService(),
            icons: IconProvider(), searchIndex: SearchIndex()
        )
        model.loadForUITesting((0..<3).map {
            InstalledApplication(
                bundleIdentifier: "folder-drop.\($0)", displayName: "Folder Drop \($0)",
                bundleURL: URL(fileURLWithPath: "/Applications/FolderDrop\($0).app")
            )
        })
        let entries = model.snapshot.entries
        model.beginEditing()
        model.beginDraggingFromPress(entries[0])

        #expect(model.performDrop(on: entries[1], grouping: true))

        let folder = try #require(model.snapshot.entries.first(where: { $0.kind == .folder }))
        #expect(folder.childApplicationRecordIDs.count == 2)
        #expect(Set(folder.childApplicationRecordIDs) == Set([
            try #require(entries[0].applicationRecordID),
            try #require(entries[1].applicationRecordID)
        ]))
        #expect(model.openedFolderID == folder.id)
        #expect(model.renamingFolderID == folder.id)
        #expect(!model.isEditing)
    }

    @MainActor
    @Test func draggingIntoExistingFolderAndBackOutPreservesApplications() async throws {
        let container = try ModelContainer(
            for: ApplicationRecord.self, LayoutItemRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = LayoutRepository(container: container)
        let model = LauncherViewModel(
            repository: repository, settings: SettingsStore(),
            discovery: ApplicationDiscoveryService(), launcher: ApplicationLauncherService(),
            icons: IconProvider(), searchIndex: SearchIndex()
        )
        model.loadForUITesting((0..<3).map {
            InstalledApplication(bundleIdentifier: "existing-folder.\($0)", displayName: "App \($0)",
                                 bundleURL: URL(fileURLWithPath: "/Applications/ExistingFolder\($0).app"))
        })
        let initial = model.snapshot.entries
        let folderID = try repository.createFolder(draggedEntryID: initial[1].id, targetEntryID: initial[0].id)
        try model.reloadSnapshot()
        let folder = try #require(model.snapshot.entries.first(where: { $0.id == folderID }))
        let source = try #require(model.snapshot.entries.first(where: { $0.id == initial[2].id }))
        let sourceRecordID = try #require(source.applicationRecordID)

        model.beginEditing()
        model.beginDraggingFromPress(source)
        #expect(model.performDrop(on: folder))
        #expect(model.snapshot.entries.allSatisfy { $0.id != source.id })
        let updatedFolder = try #require(model.snapshot.entries.first(where: { $0.id == folderID }))
        #expect(updatedFolder.childApplicationRecordIDs.contains(sourceRecordID))

        model.open(updatedFolder)
        _ = model.folderDragProvider(recordID: sourceRecordID)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.performFolderDropOutside())
        #expect(model.snapshot.entries.contains(where: { $0.applicationRecordID == sourceRecordID }))
        #expect(model.snapshot.entries.first(where: { $0.id == folderID })?.childApplicationRecordIDs.contains(sourceRecordID) == false)
    }

    @MainActor
    @Test func verticalScrollModeDoesNotInterpretDismissOrPageGestures() throws {
        let container = try ModelContainer(
            for: ApplicationRecord.self, LayoutItemRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = SettingsStore(defaults: defaults)
        settings.gridMode = .verticalScroll
        let model = LauncherViewModel(
            repository: LayoutRepository(container: container), settings: settings,
            discovery: ApplicationDiscoveryService(), launcher: ApplicationLauncherService(),
            icons: IconProvider(), searchIndex: SearchIndex()
        )
        var dismissed = false
        model.onDismiss = { dismissed = true }

        #expect(!model.handleTrackpadGesture(.dismiss))
        #expect(!model.handleTrackpadGesture(.previousPage))
        #expect(!model.handleTrackpadGesture(.nextPage))
        #expect(!dismissed)
        #expect(model.selectedPage == 0)
    }

    @MainActor
    @Test func cachedStartupRestoresLayoutAndExcludesMissingApplications() throws {
        let container = try ModelContainer(
            for: ApplicationRecord.self, LayoutItemRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = LayoutRepository(container: container)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchpadX-Cached-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = (0..<3).map {
            InstalledApplication(bundleIdentifier: "fixture.\($0)", displayName: "应用\($0)",
                                 bundleURL: root.appendingPathComponent("Fixture\($0).app", isDirectory: true))
        }
        for app in apps { try FileManager.default.createDirectory(at: app.bundleURL, withIntermediateDirectories: true) }
        try repository.reconcile(discovered: apps)
        let before = try repository.snapshot(discoveredApplications: apps)
        let folderID = try repository.createFolder(draggedEntryID: before.entries[1].id, targetEntryID: before.entries[0].id)
        try repository.reconcile(discovered: Array(apps.prefix(2)))
        let cached = try repository.cachedApplications()
        #expect(cached.count == 2)
        #expect(Set(cached.map(\.displayName)) == ["应用0", "应用1"])
        let restored = try repository.snapshot(discoveredApplications: cached)
        #expect(restored.entries.count == 1)
        #expect(restored.entries.first?.id == folderID)
        #expect(restored.entries.first?.childApplicationRecordIDs.count == 2)
    }

    @MainActor
    @Test func iconLookupReturnsPlaceholderThenReusesLoadedImage() async {
        let provider = IconProvider()
        let app = InstalledApplication(bundleIdentifier: nil, displayName: "Fixture",
                                       bundleURL: URL(fileURLWithPath: "/Applications/Fixture.app"))
        let placeholder = provider.icon(for: app)
        #expect(provider.icon(for: app) === placeholder)
        await provider.prewarm([app])
        let loaded = provider.icon(for: app)
        #expect(loaded !== placeholder)
        #expect(provider.icon(for: app) === loaded)
    }

    @MainActor
    @Test func statusItemImageHasStableSizeWithoutMutatingApplicationIcon() {
        let source = NSImage(size: NSSize(width: 1_024, height: 1_024))
        let statusImage = AppDelegate.makeStatusItemImage(from: source)

        #expect(source.size == NSSize(width: 1_024, height: 1_024))
        #expect(statusImage !== source)
        #expect(statusImage.size == NSSize(width: 18, height: 18))
    }

    @MainActor
    @Test func editingLongPressDurationIsExactlyOneSecond() {
        #expect(LaunchpadTheme.editingLongPressDuration == 1.0)
    }

    @MainActor
    @Test func unchangedApplicationScanDoesNotRequireGridRefresh() {
        let original = InstalledApplication(
            bundleIdentifier: "com.example.launcher",
            displayName: "Launcher",
            bundleURL: URL(fileURLWithPath: "/Applications/Launcher.app"),
            version: "1.0"
        )
        let rediscovered = InstalledApplication(
            bundleIdentifier: original.bundleIdentifier,
            displayName: original.displayName,
            bundleURL: original.bundleURL,
            version: original.version
        )
        let updated = InstalledApplication(
            bundleIdentifier: original.bundleIdentifier,
            displayName: original.displayName,
            bundleURL: original.bundleURL,
            version: "1.1"
        )

        #expect(LauncherViewModel.hasSameDiscoveredApplications([original], [rediscovered]))
        #expect(!LauncherViewModel.hasSameDiscoveredApplications([original], [updated]))
    }

    @MainActor
    @Test func searchPrioritizesExactNameAndMatchesBundleID() {
        let calculator = makeRecord(name: "Calculator", bundleID: "com.apple.calculator")
        let calendar = makeRecord(name: "Calendar", bundleID: "com.apple.calendar")
        let index = SearchIndex()

        let exact = index.search(query: "Calculator", records: [calculator, calendar], sort: .relevance)
        #expect(exact.first?.application.displayName == "Calculator")

        let bundle = index.search(query: "apple.calendar", records: [calculator, calendar], sort: .relevance)
        #expect(bundle.first?.application.displayName == "Calendar")
    }

    @MainActor
    @Test func searchRecognizesChinesePinyinInitials() {
        let music = makeRecord(name: "网易云音乐", bundleID: "com.example.music")
        let results = SearchIndex().search(query: "wyyy", records: [music], sort: .relevance)
        #expect(results.count == 1)
    }

    @MainActor
    @Test func chineseSearchExcludesUsageOnlyMatches() {
        let wechat = makeRecord(name: "微信", bundleID: "com.tencent.xinWeChat")
        let developerTools = makeRecord(name: "微信开发者工具", bundleID: "com.tencent.wechat.devtools")
        let enterpriseWechat = makeRecord(name: "企业微信", bundleID: "com.tencent.WeWorkMac")
        let dictionary = makeRecord(name: "词典", bundleID: "com.apple.Dictionary", launchCount: 80)
        let diskUtility = makeRecord(name: "磁盘工具", bundleID: "com.apple.DiskUtility", launchCount: 70)
        let bluetooth = makeRecord(name: "蓝牙文件交换", bundleID: "com.apple.BluetoothFileExchange", launchCount: 60)

        let results = SearchIndex().search(
            query: "微信",
            records: [dictionary, diskUtility, bluetooth, enterpriseWechat, developerTools, wechat],
            sort: .relevance
        )

        #expect(results.map(\.application.displayName) == ["微信", "微信开发者工具", "企业微信"])
    }

    @MainActor
    @Test func usageOnlyBreaksTiesBetweenTextualMatches() {
        let exact = makeRecord(name: "微信", bundleID: "com.tencent.xinWeChat")
        let unrelated = makeRecord(name: "词典", bundleID: "com.apple.Dictionary", launchCount: 1_000)
        let results = SearchIndex().search(query: "微信", records: [unrelated, exact], sort: .relevance)

        #expect(results.map(\.application.displayName) == ["微信"])
    }

    @MainActor
    @Test func trackpadClassifierMapsPhysicalLeftSwipeToNextPage() {
        var classifier = TrackpadGestureClassifier()
        #expect(classifier.consume(horizontal: 12, vertical: 0) == nil)
        #expect(classifier.consume(horizontal: 12, vertical: 0) == .nextPage)
        #expect(classifier.consume(horizontal: 200, vertical: 0) == nil)
        classifier.reset()
        #expect(classifier.consume(horizontal: -24, vertical: 0) == .previousPage)
        classifier.reset()
        #expect(classifier.consume(horizontal: 0, vertical: -24) == .dismiss)
    }

    @MainActor
    @Test func trackpadClassifierResetsAfterCancelledGesture() {
        var classifier = TrackpadGestureClassifier()
        #expect(classifier.consume(horizontal: 18, vertical: 0) == nil)
        classifier.reset()
        #expect(classifier.consume(horizontal: 12, vertical: 0) == nil)
        #expect(classifier.consume(horizontal: 12, vertical: 0) == .nextPage)
    }

    @MainActor
    @Test func optionModifierStateReportsPressAndReleaseOnce() {
        var state = OptionModifierState()
        #expect(state.update(modifiers: [.option]) == true)
        #expect(state.update(modifiers: [.option]) == nil)
        #expect(state.update(modifiers: []) == false)
        #expect(state.update(modifiers: []) == nil)
    }

    @MainActor
    @Test func trackpadClassifierSupportsReversedPageDirection() {
        var classifier = TrackpadGestureClassifier()
        #expect(classifier.consume(horizontal: 47, vertical: 0, reversesPageDirection: true) == .previousPage)
        classifier.reset()
        #expect(classifier.consume(horizontal: -47, vertical: 0, reversesPageDirection: true) == .nextPage)
    }

    @MainActor
    @Test func reversedPageDirectionSettingPersists() {
        let suiteName = "LaunchpadXTests.pageDirection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = SettingsStore(defaults: defaults)
        #expect(initial.reversePageDirection == false)
        initial.reversePageDirection = true
        #expect(SettingsStore(defaults: defaults).reversePageDirection == true)
    }

    @Test func systemApplicationsCannotBeMovedToTrash() {
        let systemApplication = InstalledApplication(
            bundleIdentifier: "com.apple.finder",
            displayName: "Finder",
            bundleURL: URL(fileURLWithPath: "/System/Applications/Finder.app"),
            isSystemApplication: true
        )
        let userApplication = InstalledApplication(
            bundleIdentifier: "com.example.app",
            displayName: "Example",
            bundleURL: URL(fileURLWithPath: "/Applications/Example.app")
        )
        #expect(!systemApplication.canMoveToTrash)
        #expect(userApplication.canMoveToTrash)
    }

    @MainActor
    @Test func optionUninstallModeTracksPressAndReleaseAndClearsWhenDismissed() throws {
        let container = try ModelContainer(
            for: ApplicationRecord.self, LayoutItemRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let model = LauncherViewModel(
            repository: LayoutRepository(container: container),
            settings: SettingsStore(), discovery: ApplicationDiscoveryService(),
            launcher: ApplicationLauncherService(), icons: IconProvider(), searchIndex: SearchIndex()
        )
        model.setOptionUninstallMode(true)
        #expect(model.isOptionUninstallMode)
        model.setOptionUninstallMode(false)
        #expect(!model.isOptionUninstallMode)
        model.setOptionUninstallMode(true)
        model.cancelTransientEditing()
        #expect(!model.isOptionUninstallMode)
    }

    @MainActor
    @Test func shortTextDoesNotMatchAppleBundleIdentifier() {
        let bluetoothFileExchange = makeRecord(name: "Bluetooth File Exchange", bundleID: "com.apple.BluetoothFileExchange")
        let results = SearchIndex().search(query: "app", records: [bluetoothFileExchange], sort: .relevance)
        #expect(results.isEmpty)
    }

    @MainActor
    @Test func droppingOneRootApplicationOnAnotherCreatesFolderAtTargetPosition() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ApplicationRecord.self,
            LayoutItemRecord.self,
            configurations: configuration
        )
        let repository = LayoutRepository(container: container)
        let first = InstalledApplication(
            bundleIdentifier: "com.example.first",
            displayName: "First",
            bundleURL: URL(fileURLWithPath: "/Applications/First.app")
        )
        let second = InstalledApplication(
            bundleIdentifier: "com.example.second",
            displayName: "Second",
            bundleURL: URL(fileURLWithPath: "/Applications/Second.app")
        )
        let third = InstalledApplication(
            bundleIdentifier: "com.example.third",
            displayName: "Third",
            bundleURL: URL(fileURLWithPath: "/Applications/Third.app")
        )

        let applications = [first, second, third]
        try repository.reconcile(discovered: applications)
        let before = try repository.snapshot(discoveredApplications: applications)
        let folderID = try repository.createFolder(
            draggedEntryID: before.entries[2].id,
            targetEntryID: before.entries[1].id
        )
        let after = try repository.snapshot(discoveredApplications: applications)

        #expect(after.entries.count == 2)
        #expect(after.entries[1].id == folderID)
        #expect(after.entries[1].kind == .folder)
        #expect(after.entries[1].childApplicationRecordIDs.count == 2)
    }

    @MainActor
    @Test func droppingRootApplicationIntoExistingFolderKeepsFolderPosition() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ApplicationRecord.self,
            LayoutItemRecord.self,
            configurations: configuration
        )
        let repository = LayoutRepository(container: container)
        let applications = (0..<4).map { index in
            InstalledApplication(
                bundleIdentifier: "com.example.folder.\(index)",
                displayName: "Application \(index)",
                bundleURL: URL(fileURLWithPath: "/Applications/Application \(index).app")
            )
        }

        try repository.reconcile(discovered: applications)
        let initial = try repository.snapshot(discoveredApplications: applications)
        let sourceRecordID = try #require(initial.entries[0].applicationRecordID)
        let createdFolderID = try repository.createFolder(
            draggedEntryID: initial.entries[2].id,
            targetEntryID: initial.entries[1].id
        )
        let folderID = try #require(createdFolderID)

        try repository.addRootApplication(initial.entries[0].id, toFolder: folderID)
        let after = try repository.snapshot(discoveredApplications: applications)

        #expect(after.entries.map(\.id) == [folderID, initial.entries[3].id])
        #expect(after.entries[0].childApplicationRecordIDs == [
            initial.entries[1].applicationRecordID,
            initial.entries[2].applicationRecordID,
            sourceRecordID,
        ])
    }

    @MainActor
    @Test func renamingFolderPersistsItsNewName() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ApplicationRecord.self,
            LayoutItemRecord.self,
            configurations: configuration
        )
        let repository = LayoutRepository(container: container)
        let applications = (0..<2).map { index in
            InstalledApplication(
                bundleIdentifier: "com.example.folder-rename.\(index)",
                displayName: "Rename \(index)",
                bundleURL: URL(fileURLWithPath: "/Applications/Rename \(index).app")
            )
        }

        try repository.reconcile(discovered: applications)
        let initial = try repository.snapshot(discoveredApplications: applications)
        let createdFolderID = try repository.createFolder(
            draggedEntryID: initial.entries[1].id,
            targetEntryID: initial.entries[0].id
        )
        let folderID = try #require(createdFolderID)

        try repository.renameFolder(id: folderID, name: "Renamed Folder")
        let renamed = try repository.snapshot(discoveredApplications: applications)

        #expect(renamed.entries.first?.title == "Renamed Folder")
    }

    @MainActor
    @Test func reorderingApplicationsInsideFolderPersistsExactOrder() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ApplicationRecord.self,
            LayoutItemRecord.self,
            configurations: configuration
        )
        let repository = LayoutRepository(container: container)
        let applications = (0..<4).map { index in
            InstalledApplication(
                bundleIdentifier: "com.example.folder-reorder.\(index)",
                displayName: "Folder Reorder \(index)",
                bundleURL: URL(fileURLWithPath: "/Applications/Folder Reorder \(index).app")
            )
        }
        try repository.reconcile(discovered: applications)
        let initial = try repository.snapshot(discoveredApplications: applications)
        let createdFolderID = try repository.createFolder(
            draggedEntryID: initial.entries[2].id,
            targetEntryID: initial.entries[1].id
        )
        let folderID = try #require(createdFolderID)
        try repository.addRootApplication(initial.entries[0].id, toFolder: folderID)
        let before = try repository.snapshot(discoveredApplications: applications)
        let requestedOrder = Array(before.entries[0].childApplicationRecordIDs.reversed())

        try repository.reorderFolderApplications(
            folderID: folderID,
            orderedRecordIDs: requestedOrder
        )
        let after = try repository.snapshot(discoveredApplications: applications)

        #expect(after.entries[0].childApplicationRecordIDs == requestedOrder)
    }

    @MainActor
    @Test func draggingApplicationOutOfFolderPlacesItBesideFolder() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ApplicationRecord.self,
            LayoutItemRecord.self,
            configurations: configuration
        )
        let repository = LayoutRepository(container: container)
        let applications = (0..<4).map { index in
            InstalledApplication(
                bundleIdentifier: "com.example.folder-extract.\(index)",
                displayName: "Folder Extract \(index)",
                bundleURL: URL(fileURLWithPath: "/Applications/Folder Extract \(index).app")
            )
        }
        try repository.reconcile(discovered: applications)
        let initial = try repository.snapshot(discoveredApplications: applications)
        let extractedEntryID = initial.entries[0].id
        let extractedRecordID = try #require(initial.entries[0].applicationRecordID)
        let trailingEntryID = initial.entries[3].id
        let createdFolderID = try repository.createFolder(
            draggedEntryID: initial.entries[2].id,
            targetEntryID: initial.entries[1].id
        )
        let folderID = try #require(createdFolderID)
        try repository.addRootApplication(extractedEntryID, toFolder: folderID)

        try repository.removeFromFolder(recordID: extractedRecordID)
        let after = try repository.snapshot(discoveredApplications: applications)

        #expect(after.entries.map(\.id) == [folderID, extractedEntryID, trailingEntryID])
        #expect(after.entries[0].childApplicationRecordIDs.count == 2)
    }

    @MainActor
    @Test func draggingOutOfTwoItemFolderDissolvesFolderAtSamePosition() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ApplicationRecord.self,
            LayoutItemRecord.self,
            configurations: configuration
        )
        let repository = LayoutRepository(container: container)
        let applications = (0..<3).map { index in
            InstalledApplication(
                bundleIdentifier: "com.example.folder-dissolve.\(index)",
                displayName: "Folder Dissolve \(index)",
                bundleURL: URL(fileURLWithPath: "/Applications/Folder Dissolve \(index).app")
            )
        }
        try repository.reconcile(discovered: applications)
        let initial = try repository.snapshot(discoveredApplications: applications)
        let remainingEntryID = initial.entries[1].id
        let extractedEntryID = initial.entries[2].id
        let extractedRecordID = try #require(initial.entries[2].applicationRecordID)
        _ = try repository.createFolder(
            draggedEntryID: extractedEntryID,
            targetEntryID: remainingEntryID
        )

        try repository.removeFromFolder(recordID: extractedRecordID)
        let after = try repository.snapshot(discoveredApplications: applications)

        #expect(after.entries.map(\.id) == [
            initial.entries[0].id,
            remainingEntryID,
            extractedEntryID,
        ])
        #expect(after.entries.allSatisfy { $0.kind == .application })
    }

    @MainActor
    @Test func folderDragOrderUsesTargetOriginalSlot() {
        let ids = (0..<5).map { _ in UUID() }

        #expect(LauncherViewModel.reorderedRecordIDs(
            moving: ids[1],
            toOriginalSlotOf: ids[3],
            in: ids
        ) == [ids[0], ids[2], ids[3], ids[1], ids[4]])
        #expect(LauncherViewModel.reorderedRecordIDs(
            moving: ids[4],
            toOriginalSlotOf: ids[1],
            in: ids
        ) == [ids[0], ids[4], ids[1], ids[2], ids[3]])
    }

    @MainActor
    @Test func liftingDraggedEntryCompactsGridWithoutLeavingPlaceholder() {
        let entries = (0..<4).map { _ in
            LauncherEntry(
                id: UUID(),
                kind: .application,
                applicationRecordID: UUID(),
                application: nil,
                folderName: nil,
                childApplicationRecordIDs: []
            )
        }
        let liftedID = entries[1].id
        let compacted = LauncherViewModel.compactedEntries(afterLifting: liftedID, from: entries)

        #expect(compacted.map(\.id) == [entries[0].id, entries[2].id, entries[3].id])
        #expect(!compacted.contains { $0.id == liftedID })
    }

    @MainActor
    @Test func dropCenterGroupsWhileDropEdgeReorders() {
        let iconSize = 94.0
        let center = CGPoint(x: iconSize / 2, y: iconSize / 2)

        #expect(LauncherEntryDropDelegate.isGroupingLocation(center, iconSize: iconSize, tileWidth: iconSize))
        #expect(!LauncherEntryDropDelegate.isGroupingLocation(CGPoint(x: 2, y: 2), iconSize: iconSize, tileWidth: iconSize))
    }

    @MainActor
    @Test func dragPreviewReordersBeforeAndAfterTarget() {
        let entries = (0..<4).map { _ in
            LauncherEntry(
                id: UUID(),
                kind: .application,
                applicationRecordID: UUID(),
                application: nil,
                folderName: nil,
                childApplicationRecordIDs: []
            )
        }
        let before = LauncherViewModel.reorderedEntries(
            moving: entries[0].id,
            relativeTo: entries[2].id,
            insertAfter: false,
            in: entries
        )
        let after = LauncherViewModel.reorderedEntries(
            moving: entries[0].id,
            relativeTo: entries[2].id,
            insertAfter: true,
            in: entries
        )

        #expect(before.map(\.id) == [entries[1].id, entries[0].id, entries[2].id, entries[3].id])
        #expect(after.map(\.id) == [entries[1].id, entries[2].id, entries[0].id, entries[3].id])
    }

    @MainActor
    @Test func movingToAnotherApplicationOccupiesItsOriginalSlot() {
        let entries = (0..<5).map { _ in
            LauncherEntry(
                id: UUID(),
                kind: .application,
                applicationRecordID: UUID(),
                application: nil,
                folderName: nil,
                childApplicationRecordIDs: []
            )
        }

        let movingForward = LauncherViewModel.reorderedEntries(
            moving: entries[1].id,
            toOriginalSlotOf: entries[3].id,
            in: entries
        )
        let movingBackward = LauncherViewModel.reorderedEntries(
            moving: entries[4].id,
            toOriginalSlotOf: entries[1].id,
            in: entries
        )

        #expect(movingForward.map(\.id) == [
            entries[0].id,
            entries[2].id,
            entries[3].id,
            entries[1].id,
            entries[4].id,
        ])
        #expect(movingBackward.map(\.id) == [
            entries[0].id,
            entries[4].id,
            entries[1].id,
            entries[2].id,
            entries[3].id,
        ])
    }

    @MainActor
    @Test func droppingLiftedEntryOnBlankGridPersistsItAtEnd() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ApplicationRecord.self,
            LayoutItemRecord.self,
            configurations: configuration
        )
        let repository = LayoutRepository(container: container)
        let applications = (0..<3).map { index in
            InstalledApplication(
                bundleIdentifier: "com.example.move.\(index)",
                displayName: "Move \(index)",
                bundleURL: URL(fileURLWithPath: "/Applications/Move \(index).app")
            )
        }
        try repository.reconcile(discovered: applications)
        let before = try repository.snapshot(discoveredApplications: applications)
        let sourceID = before.entries[0].id
        let compactedPreview = LauncherViewModel.compactedEntries(
            afterLifting: sourceID,
            from: before.entries
        )
        let destinationID = LauncherViewModel.dropDestinationID(
            sourceID: sourceID,
            previewEntries: compactedPreview,
            fallbackDestinationID: nil
        )

        try repository.moveRootEntry(from: sourceID, before: destinationID)
        let after = try repository.snapshot(discoveredApplications: applications)

        #expect(after.entries.map(\.id) == [before.entries[1].id, before.entries[2].id, sourceID])
    }

    @MainActor
    @Test func droppingReorderedPreviewPersistsItsExactPosition() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ApplicationRecord.self,
            LayoutItemRecord.self,
            configurations: configuration
        )
        let repository = LayoutRepository(container: container)
        let applications = (0..<4).map { index in
            InstalledApplication(
                bundleIdentifier: "com.example.exact-move.\(index)",
                displayName: "Exact Move \(index)",
                bundleURL: URL(fileURLWithPath: "/Applications/Exact Move \(index).app")
            )
        }
        try repository.reconcile(discovered: applications)
        let before = try repository.snapshot(discoveredApplications: applications)
        let sourceID = before.entries[0].id
        let reorderedPreview = LauncherViewModel.reorderedEntries(
            moving: sourceID,
            relativeTo: before.entries[2].id,
            insertAfter: true,
            in: before.entries
        )
        let destinationID = LauncherViewModel.dropDestinationID(
            sourceID: sourceID,
            previewEntries: reorderedPreview,
            fallbackDestinationID: before.entries[2].id
        )

        try repository.moveRootEntry(from: sourceID, before: destinationID)
        let after = try repository.snapshot(discoveredApplications: applications)

        #expect(after.entries.map(\.id) == reorderedPreview.map(\.id))
    }

    @MainActor
    @Test func liftingLastApplicationOnPageDoesNotPullFromNextPage() {
        let entries = (0..<8).map { index in
            LauncherEntry(
                id: UUID(),
                kind: .application,
                applicationRecordID: UUID(),
                application: nil,
                folderName: nil,
                childApplicationRecordIDs: [],
                layoutIndex: index
            )
        }

        let compacted = LauncherViewModel.compactedEntries(
            afterLifting: entries[3].id,
            from: entries,
            capacity: 4
        )

        #expect(compacted.filter { $0.layoutIndex < 4 }.map(\.id) == [
            entries[0].id,
            entries[1].id,
            entries[2].id,
        ])
        #expect(compacted.first(where: { $0.id == entries[4].id })?.layoutIndex == 4)
    }

    @MainActor
    @Test func movingRootApplicationIntoFolderPreservesNextPageBoundary() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ApplicationRecord.self,
            LayoutItemRecord.self,
            configurations: configuration
        )
        let repository = LayoutRepository(container: container)
        let applications = (0..<6).map { index in
            InstalledApplication(
                bundleIdentifier: "com.example.page-boundary.\(index)",
                displayName: "Page Boundary \(index)",
                bundleURL: URL(fileURLWithPath: "/Applications/Page Boundary \(index).app")
            )
        }
        try repository.reconcile(discovered: applications)
        let before = try repository.snapshot(discoveredApplications: applications)
        _ = try repository.createFolder(
            draggedEntryID: before.entries[3].id,
            targetEntryID: before.entries[2].id
        )
        let after = try repository.snapshot(discoveredApplications: applications)

        #expect(after.entries.first(where: {
            $0.application?.displayName == "Page Boundary 4"
        })?.layoutIndex == 4)
        #expect(after.entries.filter { $0.layoutIndex < 4 }.count == 3)
    }

    @MainActor
    @Test func edgePageMovePlacesSourceOnAdjacentPageWithoutCrossPageBackfill() {
        let entries = (0..<8).map { index in
            LauncherEntry(
                id: UUID(),
                kind: .application,
                applicationRecordID: UUID(),
                application: nil,
                folderName: nil,
                childApplicationRecordIDs: [],
                layoutIndex: index
            )
        }

        let moved = LauncherViewModel.movedEntries(
            moving: entries[1].id,
            toPage: 1,
            in: entries,
            capacity: 4
        )
        let firstPageIDs = moved
            .filter { $0.layoutIndex < 4 }
            .sorted { $0.layoutIndex < $1.layoutIndex }
            .map(\.id)
        let secondPageIDs = moved
            .filter { $0.layoutIndex >= 4 && $0.layoutIndex < 8 }
            .sorted { $0.layoutIndex < $1.layoutIndex }
            .map(\.id)

        #expect(firstPageIDs == [entries[0].id, entries[2].id, entries[3].id, entries[7].id])
        #expect(secondPageIDs == [entries[4].id, entries[5].id, entries[6].id, entries[1].id])
    }

    @MainActor
    @Test func dragEdgeClassificationAndPageBoundsAreDeterministic() {
        let frame = CGRect(x: 100, y: 50, width: 1_000, height: 700)

        #expect(LauncherViewModel.dragPageDelta(
            screenX: 180,
            windowFrame: frame,
            threshold: 120
        ) == -1)
        #expect(LauncherViewModel.dragPageDelta(
            screenX: 1_020,
            windowFrame: frame,
            threshold: 120
        ) == 1)
        #expect(LauncherViewModel.dragPageDelta(
            screenX: 600,
            windowFrame: frame,
            threshold: 120
        ) == nil)
        #expect(LauncherViewModel.edgeDestinationPage(
            currentPage: 0,
            pageCount: 3,
            delta: -1
        ) == nil)
        #expect(LauncherViewModel.edgeDestinationPage(
            currentPage: 2,
            pageCount: 3,
            delta: 1
        ) == nil)
        #expect(LauncherViewModel.edgeDestinationPage(
            currentPage: 1,
            pageCount: 3,
            delta: -1
        ) == 0)
        #expect(LauncherViewModel.edgeDestinationPage(
            currentPage: 1,
            pageCount: 3,
            delta: 1
        ) == 2)
    }

    @MainActor
    @Test func importedLaunchOSLayoutPreservesNamesFoldersAndVisibilityAndIsIdempotent() throws {
        let container = try ModelContainer(
            for: ApplicationRecord.self, LayoutItemRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = LayoutRepository(container: container)
        let apps = (0..<3).map { index in
            InstalledApplication(
                bundleIdentifier: "migration.\(index)", displayName: "Imported \(index)",
                bundleURL: URL(fileURLWithPath: "/Applications/Imported \(index).app")
            )
        }
        let imported = [
            ImportedLaunchOSEntry(folderName: nil, applications: [
                ImportedLaunchOSApplication(application: apps[0], alias: "Renamed", isHidden: false)
            ]),
            ImportedLaunchOSEntry(folderName: "Work", applications: [
                ImportedLaunchOSApplication(application: apps[1], alias: nil, isHidden: false),
                ImportedLaunchOSApplication(application: apps[2], alias: nil, isHidden: true)
            ])
        ]

        #expect(try repository.importInitialLayout(imported) == 3)
        #expect(try repository.importInitialLayout(imported) == 0)
        let snapshot = try repository.snapshot(discoveredApplications: apps)
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.entries[0].title == "Renamed")
        #expect(snapshot.entries[1].title == "Work")
        #expect(snapshot.entries[1].childApplicationRecordIDs.count == 1)
        #expect(snapshot.hiddenRecordIDs.count == 1)
    }

    @Test func launchOSFileURLPathsMatchInstalledApplicationPaths() {
        let installed = URL(fileURLWithPath: "/Applications/Design Tool.app")
        #expect(LaunchOSLayoutImporter.normalizedPath(from: "file:///Applications/Design%20Tool.app") == installed.path.lowercased())
        #expect(LaunchOSLayoutImporter.normalizedPath(from: installed.path) == installed.path.lowercased())
    }

    @MainActor
    @Test func multiSelectSelectsVisibleAppsAndHidesSelectedRecords() throws {
        let container = try ModelContainer(
            for: ApplicationRecord.self, LayoutItemRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = LayoutRepository(container: container)
        let apps = (0..<3).map {
            InstalledApplication(bundleIdentifier: "batch.\($0)", displayName: "Batch \($0)",
                                 bundleURL: URL(fileURLWithPath: "/Applications/Batch\($0).app"))
        }
        let model = LauncherViewModel(repository: repository, settings: SettingsStore(),
                                      discovery: ApplicationDiscoveryService(), launcher: ApplicationLauncherService(),
                                      icons: IconProvider(), searchIndex: SearchIndex())
        model.loadForUITesting(apps)
        model.hide(entry: model.snapshot.entries[0])
        model.toggleMultiSelecting()
        model.selectAllApplications()
        #expect(model.selectedApplicationRecordIDs.count == 2)
        model.hideSelectedApplications()
        #expect(model.snapshot.entries.isEmpty)
        #expect(model.snapshot.hiddenRecordIDs.count == 3)
        #expect(!model.isMultiSelecting)
    }

    @MainActor
    @Test func scanRootsPersistAndIncludeUserFolders() {
        let suiteName = "LaunchpadXTests.scanRoots.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = URL(fileURLWithPath: "/tmp/LaunchpadX Extra Apps", isDirectory: true)
        let settings = SettingsStore(defaults: defaults)
        settings.additionalScanRoots = [root]
        let restored = SettingsStore(defaults: defaults)
        #expect(restored.additionalScanRoots.map(\.standardizedFileURL.path) == [root.standardizedFileURL.path])
        #expect(restored.allScanRoots.contains { $0.standardizedFileURL.path == root.standardizedFileURL.path })
    }

    @MainActor
    @Test func customLauncherHotKeyPersists() {
        let suiteName = "LaunchpadXTests.customHotKey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let custom = HotKey(keyCode: 40, carbonModifiers: UInt32(controlKey | optionKey))
        settings.hotKey = custom
        #expect(SettingsStore(defaults: defaults).hotKey == custom)
        #expect(custom.displayString == "⌥⌃K")
    }

    @MainActor
    @Test func menuBarVisibilityDefaultsToShownAndPersists() {
        let suiteName = "LaunchpadXTests.menuBarVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.showMenuBarIcon)
        var visibilityUpdates: [Bool] = []
        settings.onMenuBarVisibilityChanged = { visibilityUpdates.append($0) }
        settings.showMenuBarIcon = false
        #expect(visibilityUpdates == [false])
        #expect(!SettingsStore(defaults: defaults).showMenuBarIcon)
        settings.showMenuBarIcon = true
        #expect(visibilityUpdates == [false, true])
    }

    @MainActor
    @Test func presentationAndGridModesPersist() {
        let suiteName = "LaunchpadXTests.presentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.presentationMode == .fullScreen)
        #expect(settings.gridMode == .pages)
        settings.presentationMode = .window
        settings.gridMode = .verticalScroll
        let restored = SettingsStore(defaults: defaults)
        #expect(restored.presentationMode == .window)
        #expect(restored.gridMode == .verticalScroll)
        #expect(restored.f4ShortcutEnabled == false)
        #expect(restored.trackpadWakeEnabled == false)
        #expect(restored.hotCorner == .off)
    }

    @MainActor
    private func makeRecord(
        name: String,
        bundleID: String,
        launchCount: Int = 0
    ) -> (ApplicationRecord, InstalledApplication) {
        let path = "/Applications/\(name).app"
        let record = ApplicationRecord(
            bundleIdentifier: bundleID,
            lastKnownPath: path,
            displayName: name,
            launchCount: launchCount
        )
        let app = InstalledApplication(bundleIdentifier: bundleID, displayName: name, bundleURL: URL(fileURLWithPath: path))
        return (record, app)
    }
}
