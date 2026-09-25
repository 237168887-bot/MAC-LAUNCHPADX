//
//  LaunchpadXUITests.swift
//  LaunchpadXUITests
//
//  Created by 张航 on 2026/7/29.
//

import AppKit
import XCTest

final class LaunchpadXUITests: XCTestCase {

    private func waitForHittable(_ element: XCUIElement, expected: Bool, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "hittable == %@", NSNumber(value: expected))
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    func testCustomLauncherHotKeyCanBeRecordedAndCancelled() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-isolated-data", "--show-settings-for-ui-testing"]
        app.launch()
        app.activate()

        let settingsWindow = app.windows["LaunchpadX"].firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 8))
        XCTAssertTrue(app.switches["settings.launchAtLogin"].exists)
        XCTAssertTrue(app.switches["settings.showMenuBarIcon"].exists)
        app.staticTexts["快捷键"].firstMatch.click()

        let recorder = app.buttons["settings.hotKeyRecorder"].firstMatch
        XCTAssertTrue(recorder.waitForExistence(timeout: 5))
        let original = recorder.label
        recorder.click()
        XCTAssertTrue(recorder.label.contains("请按下快捷键"), "Actual recorder label: \(recorder.label)")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(recorder.label, original)

        recorder.click()
        app.typeKey("k", modifierFlags: [.control, .shift])
        XCTAssertEqual(recorder.label, "⌃⇧K")

    }

    @MainActor
    func testClickingBlankGridClosesLauncher() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing", "--ui-testing-isolated-data",
            "--ui-testing-fixtures", "--ui-testing-window-mode",
        ]
        app.launch()
        app.activate()
        let root = app.descendants(matching: .any).matching(identifier: "launcher.root").firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).click()
        assertLauncherDismissedWithoutFailedLaunch(app, root: root)
    }

    @MainActor
    func testClickingGapBetweenIconsClosesVerticalGrid() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing", "--ui-testing-isolated-data",
            "--ui-testing-fixtures", "--ui-testing-window-mode", "--ui-testing-scroll-grid",
        ]
        app.launch()
        app.activate()

        let root = app.descendants(matching: .any).matching(identifier: "launcher.root").firstMatch
        let first = app.buttons["Fixture 0"].firstMatch
        let second = app.buttons["Fixture 1"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        clickGap(between: first, and: second, in: app.windows.firstMatch)
        assertLauncherDismissedWithoutFailedLaunch(app, root: root)
    }

    @MainActor
    func testClickingGapBetweenIconAndLabelClosesLauncher() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing", "--ui-testing-isolated-data",
            "--ui-testing-fixtures", "--ui-testing-window-mode", "--ui-testing-scroll-grid",
        ]
        app.launch()
        app.activate()

        let root = app.descendants(matching: .any).matching(identifier: "launcher.root").firstMatch
        let tileElements = app.buttons.matching(identifier: "launcher.tile")
            .matching(NSPredicate(format: "label == %@", "Fixture 0"))
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(tileElements.count, 2, app.debugDescription)
        let iconFrame = tileElements.element(boundBy: 0).frame
        let labelFrame = tileElements.element(boundBy: 1).frame
        XCTAssertGreaterThan(labelFrame.minY, iconFrame.maxY)
        let point = CGPoint(x: iconFrame.midX, y: (iconFrame.maxY + labelFrame.minY) / 2)
        click(point, in: app.windows.firstMatch)
        assertLauncherDismissedWithoutFailedLaunch(app, root: root)
    }

    @MainActor
    func testClickingGapBetweenPagedIconsClosesLauncher() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing", "--ui-testing-isolated-data",
            "--ui-testing-fixtures", "--ui-testing-window-mode",
        ]
        app.launch()
        app.activate()

        let root = app.descendants(matching: .any).matching(identifier: "launcher.root").firstMatch
        let first = app.buttons["Fixture 0"].firstMatch
        let second = app.buttons["Fixture 1"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        clickGap(between: first, and: second, in: app.windows.firstMatch)
        assertLauncherDismissedWithoutFailedLaunch(app, root: root)
    }

    @MainActor
    func testClickingIconRunsItsActionInsteadOfBackgroundDismissal() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing", "--ui-testing-isolated-data",
            "--ui-testing-fixtures", "--ui-testing-window-mode", "--ui-testing-scroll-grid",
        ]
        app.launch()
        app.activate()

        let icon = app.buttons.matching(identifier: "launcher.tile").matching(NSPredicate(format: "label == %@", "Fixture 0")).element(boundBy: 0)
        XCTAssertTrue(icon.waitForExistence(timeout: 8))
        clickCenter(of: icon, in: app.windows.firstMatch)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testClickingIconLabelRunsItsActionInsteadOfBackgroundDismissal() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing", "--ui-testing-isolated-data",
            "--ui-testing-fixtures", "--ui-testing-window-mode", "--ui-testing-scroll-grid",
        ]
        app.launch()
        app.activate()

        let matching = app.buttons.matching(identifier: "launcher.tile")
            .matching(NSPredicate(format: "label == %@", "Fixture 0"))
        XCTAssertGreaterThanOrEqual(matching.count, 2, app.debugDescription)
        let label = matching.element(boundBy: 1)
        XCTAssertTrue(label.waitForExistence(timeout: 8))
        clickCenter(of: label, in: app.windows.firstMatch)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testClickingGapBetweenSearchResultsClosesLauncher() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing", "--ui-testing-isolated-data",
            "--ui-testing-fixtures", "--ui-testing-window-mode",
        ]
        app.launch()
        app.activate()

        let root = app.descendants(matching: .any).matching(identifier: "launcher.root").firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        let search = app.textFields.firstMatch
        search.click()
        search.typeText("Fixture")
        let first = app.buttons["Fixture 0"].firstMatch
        let second = app.buttons["Fixture 1"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        clickGap(between: first, and: second, in: app.windows.firstMatch)
        assertLauncherDismissedWithoutFailedLaunch(app, root: root)
    }

    @MainActor
    func testClickingSearchResultRunsItsActionInsteadOfBackgroundDismissal() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing", "--ui-testing-isolated-data",
            "--ui-testing-fixtures", "--ui-testing-window-mode",
        ]
        app.launch()
        app.activate()

        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.click()
        search.typeText("Fixture")
        let result = app.buttons["Fixture 0"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func clickGap(between first: XCUIElement, and second: XCUIElement, in window: XCUIElement) {
        let firstFrame = first.frame
        let secondFrame = second.frame
        XCTAssertGreaterThan(secondFrame.minX, firstFrame.maxX + 1)
        let verticalOverlap = min(firstFrame.maxY, secondFrame.maxY) - max(firstFrame.minY, secondFrame.minY)
        XCTAssertGreaterThan(verticalOverlap, 0, "Icons should share a row: \(firstFrame), \(secondFrame)")
        let point = CGPoint(x: firstFrame.maxX + 1, y: firstFrame.midY)
        click(point, in: window)
    }

    @MainActor
    private func clickCenter(of element: XCUIElement, in window: XCUIElement) {
        click(CGPoint(x: element.frame.midX, y: element.frame.midY), in: window)
    }

    @MainActor
    private func click(_ point: CGPoint, in window: XCUIElement) {
        let windowFrame = window.frame
        window.coordinate(withNormalizedOffset: CGVector(
            dx: (point.x - windowFrame.minX) / windowFrame.width,
            dy: (point.y - windowFrame.minY) / windowFrame.height
        )).click()
    }

    @MainActor
    private func assertLauncherDismissedWithoutFailedLaunch(_ app: XCUIApplication, root: XCUIElement) {
        XCTAssertTrue(waitForHittable(root, expected: false), app.debugDescription)
        let noFailedLaunch = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.sheets.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [noFailedLaunch], timeout: 1.5), .completed, app.debugDescription)
    }

    @MainActor
    func testFolderRemainsVisibleWhenSwitchingWindowToFullScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing", "--ui-testing-isolated-data",
            "--ui-testing-fixtures", "--ui-testing-existing-folder",
            "--ui-testing-window-mode", "--ui-testing-switch-to-fullscreen",
        ]
        app.launch()
        app.activate()
        let folder = app.buttons["Fixture Folder"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.8)
        let fullScreenHierarchy = app.debugDescription
        XCTAssertTrue(fullScreenHierarchy.contains("Dialog (Main)"))
        XCTAssertTrue(fullScreenHierarchy.contains("Fixture Folder"))
    }

    @MainActor
    private func startEditing(in app: XCUIApplication) {
        app.typeKey("e", modifierFlags: [.command, .shift])
        let root = app.descendants(matching: .any).matching(identifier: "launcher.root").firstMatch
        let enteredEditing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "editing"),
            object: root
        )
        if XCTWaiter.wait(for: [enteredEditing], timeout: 1) == .completed {
            app.activate()
            return
        }

        let appMenu = app.menuBars.menuBarItems["LaunchpadX"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 3), app.debugDescription)
        appMenu.click()
        appMenu.menus.firstMatch.menuItems["编辑布局"].click()
        app.activate()
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testEscapeExitsEditingWithoutTopRightButtons() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing",
            "--ui-testing-isolated-data",
            "--ui-testing-fixtures",
            "--ui-testing-window-mode",
        ]
        app.launch()
        app.activate()

        let root = app.descendants(matching: .any)
            .matching(identifier: "launcher.root")
            .firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        startEditing(in: app)
        XCTAssertFalse(app.buttons["编辑布局"].exists)
        XCTAssertFalse(app.buttons["选择应用"].exists)
        XCTAssertFalse(app.buttons["完成编辑"].exists)
        XCTAssertEqual(root.value as? String, "editing")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertEqual(root.value as? String, "normal")
    }

    @MainActor
    func testFolderRenameAndBackgroundTapExitsEditing() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing",
            "--ui-testing-isolated-data",
            "--ui-testing-fixtures",
            "--ui-testing-existing-folder",
        ]
        app.launch()
        app.activate()

        let root = app.descendants(matching: .any)
            .matching(identifier: "launcher.root")
            .firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        startEditing(in: app)
        let launcherPanel = app.dialogs.firstMatch
        let editSource = app.buttons["Fixture 0"].firstMatch
        let folder = app.buttons["Fixture Folder"].firstMatch
        let rightNeighbor = app.buttons["Fixture 3"].firstMatch
        XCTAssertTrue(editSource.waitForExistence(timeout: 8))
        XCTAssertTrue(folder.exists)
        XCTAssertTrue(rightNeighbor.exists)
        let panelFrame = launcherPanel.frame
        let folderCoordinate = launcherPanel.coordinate(
            withNormalizedOffset: CGVector(
                dx: ((editSource.frame.midX + rightNeighbor.frame.midX) / 2 - panelFrame.minX)
                    / panelFrame.width,
                dy: (editSource.frame.midY - panelFrame.minY) / panelFrame.height
            )
        )

        XCTAssertEqual(root.value as? String, "editing")

        folderCoordinate.click()
        let folderName = app.staticTexts["Fixture Folder"].firstMatch
        XCTAssertTrue(folderName.waitForExistence(timeout: 3))
        folderName.doubleClick()

        let editor = app.textFields
            .matching(NSPredicate(format: "placeholderValue == %@", "Folder name"))
            .firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(editor.exists)
        XCTAssertTrue(app.buttons["Fixture Folder"].firstMatch.exists)

        XCTAssertTrue(launcherPanel.exists)
        launcherPanel.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.50))
            .tap()
        XCTAssertEqual(root.value as? String, "normal")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "folder.tile")
            .firstMatch.exists)
    }

    @MainActor
    func testDraggingToRightEdgeMovesApplicationOnlyToNextPage() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing",
            "--ui-testing-isolated-data",
            "--ui-testing-fixtures",
            "--ui-testing-many-fixtures",
        ]
        app.launch()

        let root = app.descendants(matching: .any)
            .matching(identifier: "launcher.root")
            .firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        startEditing(in: app)
        let launcherFrame = NSScreen.main?.frame ?? app.dialogs.firstMatch.frame
        let source = app.buttons["Fixture 0"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        let coordinateSpace = app.textFields.firstMatch
        XCTAssertTrue(coordinateSpace.exists)
        let coordinateFrame = coordinateSpace.frame
        let sourceCenter = source.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let rightEdge = coordinateSpace.coordinate(
            withNormalizedOffset:
            CGVector(
                dx: (launcherFrame.maxX - 72 - coordinateFrame.minX) / coordinateFrame.width,
                dy: (launcherFrame.midY - coordinateFrame.minY) / coordinateFrame.height
            )
        )

        sourceCenter.press(
                forDuration: 0.35,
                thenDragTo: rightEdge,
                withVelocity: .slow,
                thenHoldForDuration: 1.0
            )

        XCTAssertEqual(root.value as? String, "editing")
        XCTAssertTrue(app.buttons["Fixture 35"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Fixture 0"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["Fixture 1"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Fixture 70"].firstMatch.exists)
    }

    @MainActor
    func testDraggingToLeftEdgeMovesApplicationOnlyToPreviousPage() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing",
            "--ui-testing-isolated-data",
            "--ui-testing-fixtures",
            "--ui-testing-many-fixtures",
        ]
        app.launch()

        let root = app.descendants(matching: .any)
            .matching(identifier: "launcher.root")
            .firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        startEditing(in: app)
        app.typeKey(.rightArrow, modifierFlags: [])
        let launcherFrame = NSScreen.main?.frame ?? app.dialogs.firstMatch.frame
        let source = app.buttons["Fixture 35"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 4))
        let coordinateSpace = app.textFields.firstMatch
        XCTAssertTrue(coordinateSpace.exists)
        let coordinateFrame = coordinateSpace.frame
        let sourceCenter = source.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let leftEdge = coordinateSpace.coordinate(
            withNormalizedOffset:
            CGVector(
                dx: (launcherFrame.minX + 72 - coordinateFrame.minX) / coordinateFrame.width,
                dy: (launcherFrame.midY - coordinateFrame.minY) / coordinateFrame.height
            )
        )

        sourceCenter.press(
                forDuration: 0.35,
                thenDragTo: leftEdge,
                withVelocity: .slow,
                thenHoldForDuration: 1.0
            )

        XCTAssertEqual(root.value as? String, "editing")
        XCTAssertTrue(app.buttons["Fixture 0"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Fixture 35"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["Fixture 34"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Fixture 70"].firstMatch.exists)
    }

    @MainActor
    func testDraggedApplicationStaysAtItsNewPosition() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing",
            "--ui-testing-isolated-data",
            "--ui-testing-fixtures",
            "--ui-testing-many-fixtures",
        ]
        app.launch()

        let root = app.descendants(matching: .any)
            .matching(identifier: "launcher.root")
            .firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        startEditing(in: app)
        let launcherPanel = app.dialogs.firstMatch
        XCTAssertTrue(launcherPanel.exists)

        let source = app.buttons["Fixture 0"].firstMatch
        let target = app.buttons["Fixture 3"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        XCTAssertTrue(target.exists)
        let originalFrame = source.frame
        let targetOriginalFrame = target.frame
        let panelFrame = launcherPanel.frame
        let targetOriginalCoordinate = launcherPanel.coordinate(
            withNormalizedOffset: CGVector(
                dx: (targetOriginalFrame.minX + 5 - panelFrame.minX) / panelFrame.width,
                dy: (targetOriginalFrame.midY - panelFrame.minY) / panelFrame.height
            )
        )

        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.35,
                thenDragTo: targetOriginalCoordinate,
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        XCTAssertEqual(root.value as? String, "editing")

        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                source.exists
                    && source.frame != originalFrame
                    && abs(source.frame.midX - targetOriginalFrame.midX) < 2
                    && abs(source.frame.midY - targetOriginalFrame.midY) < 2
            },
            object: nil
        )
        let result = XCTWaiter.wait(for: [moved], timeout: 3)
        if result != .completed {
            let currentSourceFrame = source.exists ? source.frame : .null
            let currentTargetFrame = target.exists ? target.frame : .null
            XCTFail(
                "source: \(currentSourceFrame), original: \(originalFrame), "
                    + "target slot: \(targetOriginalFrame), target now: \(currentTargetFrame)"
            )
        }
    }

    @MainActor
    func testDraggedApplicationCanBeAddedToExistingFolder() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing",
            "--ui-testing-isolated-data",
            "--ui-testing-fixtures",
            "--ui-testing-existing-folder",
            "--ui-testing-window-mode",
        ]
        app.launch()

        let root = app.descendants(matching: .any)
            .matching(identifier: "launcher.root")
            .firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        startEditing(in: app)
        let launcherPanel = app.windows.firstMatch
        let source = app.buttons.matching(identifier: "launcher.tile")
            .matching(NSPredicate(format: "label == %@", "Fixture 7")).element(boundBy: 0)
        let folder = app.buttons.matching(identifier: "launcher.tile")
            .matching(NSPredicate(format: "label == %@", "Fixture Folder")).element(boundBy: 0)
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        XCTAssertTrue(folder.exists)
        let panelFrame = launcherPanel.frame
        let folderIconCoordinate = launcherPanel.coordinate(
            withNormalizedOffset: CGVector(
                dx: (folder.frame.midX - panelFrame.minX) / panelFrame.width,
                dy: (folder.frame.midY - panelFrame.minY) / panelFrame.height
            )
        )

        XCTAssertEqual(root.value as? String, "editing")
        source.press(
            forDuration: 0.35,
            thenDragTo: folder,
            withVelocity: .slow,
            thenHoldForDuration: 0.7
        )

        let removedFromRoot = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: source
        )
        XCTAssertEqual(XCTWaiter.wait(for: [removedFromRoot], timeout: 3), .completed)

        launcherPanel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        XCTAssertEqual(root.value as? String, "normal")
        folderIconCoordinate.click()
        let applicationInsideFolder = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == %@ AND label == %@",
                    "folder.tile",
                    "Fixture 7"
                )
            )
            .firstMatch
        XCTAssertTrue(applicationInsideFolder.waitForExistence(timeout: 3))
    }

    @MainActor
    func testFolderOpensWhileEditingAndApplicationCanBeDraggedOut() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing",
            "--ui-testing-isolated-data",
            "--ui-testing-fixtures",
            "--ui-testing-existing-folder",
        ]
        app.launch()

        let root = app.descendants(matching: .any)
            .matching(identifier: "launcher.root")
            .firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        startEditing(in: app)
        let launcherPanel = app.dialogs.firstMatch
        let editSource = app.buttons["Fixture 0"].firstMatch
        let leftNeighbor = editSource
        let rightNeighbor = app.buttons["Fixture 3"].firstMatch
        XCTAssertTrue(editSource.waitForExistence(timeout: 8))
        XCTAssertTrue(rightNeighbor.exists)
        let panelFrame = launcherPanel.frame
        let folderCoordinate = launcherPanel.coordinate(
            withNormalizedOffset: CGVector(
                dx: ((leftNeighbor.frame.midX + rightNeighbor.frame.midX) / 2 - panelFrame.minX)
                    / panelFrame.width,
                dy: (leftNeighbor.frame.midY - panelFrame.minY) / panelFrame.height
            )
        )

        XCTAssertEqual(root.value as? String, "editing")
        folderCoordinate.click()

        let folderChild = app.descendants(matching: .any)
            .matching(identifier: "folder.tile")
            .firstMatch
        XCTAssertTrue(folderChild.waitForExistence(timeout: 3))
        let outsideFolder = launcherPanel.coordinate(
            withNormalizedOffset: CGVector(dx: 0.10, dy: 0.52)
        )
        folderChild.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.35,
                thenDragTo: outsideFolder,
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )

        XCTAssertFalse(folderChild.exists)
        XCTAssertEqual(root.value as? String, "editing")
        XCTAssertTrue(app.buttons["Fixture 1"].firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    func testApplicationsInsideFolderCanBeReorderedWhileEditing() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing",
            "--ui-testing-isolated-data",
            "--ui-testing-fixtures",
            "--ui-testing-existing-folder",
        ]
        app.launch()

        let root = app.descendants(matching: .any)
            .matching(identifier: "launcher.root")
            .firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        startEditing(in: app)
        let launcherPanel = app.dialogs.firstMatch
        let editSource = app.buttons["Fixture 0"].firstMatch
        let rightNeighbor = app.buttons["Fixture 3"].firstMatch
        XCTAssertTrue(editSource.waitForExistence(timeout: 8))
        XCTAssertTrue(rightNeighbor.exists)
        let panelFrame = launcherPanel.frame
        let folderCoordinate = launcherPanel.coordinate(
            withNormalizedOffset: CGVector(
                dx: ((editSource.frame.midX + rightNeighbor.frame.midX) / 2 - panelFrame.minX)
                    / panelFrame.width,
                dy: (editSource.frame.midY - panelFrame.minY) / panelFrame.height
            )
        )

        XCTAssertEqual(root.value as? String, "editing")
        folderCoordinate.click()

        let folderTiles = app.images.matching(identifier: "folder.tile")
        XCTAssertEqual(folderTiles.count, 2)
        let first = folderTiles.matching(
            NSPredicate(format: "label == %@", "Fixture 1")
        ).firstMatch
        let second = folderTiles.matching(
            NSPredicate(format: "label == %@", "Fixture 2")
        ).firstMatch
        XCTAssertTrue(first.exists)
        XCTAssertTrue(second.exists)
        let firstOriginalFrame = first.frame
        let secondOriginalFrame = second.frame
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.35,
                thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )

        let reordered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                first.exists
                    && abs(first.frame.midX - secondOriginalFrame.midX) < 3
                    && abs(second.frame.midX - firstOriginalFrame.midX) < 3
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 3), .completed)
    }

    @MainActor
    func testWindowModeShowsLauncherInStandardWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing",
            "--ui-testing-isolated-data",
            "--ui-testing-fixtures",
            "--ui-testing-many-fixtures",
            "--ui-testing-window-mode",
            "--ui-testing-scroll-grid",
        ]
        app.launch()
        app.activate()

        let root = app.descendants(matching: .any)
            .matching(identifier: "launcher.root")
            .firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["编辑布局"].exists)
        XCTAssertFalse(app.buttons["选择应用"].exists)
        XCTAssertTrue(app.buttons["Fixture 0"].exists)
        let search = app.textFields.firstMatch
        let grid = app.scrollViews.firstMatch
        XCTAssertTrue(search.exists)
        XCTAssertTrue(grid.exists)
        XCTAssertGreaterThan(grid.frame.width, 700)
        XCTAssertLessThan(grid.frame.width, 1_200)
        XCTAssertLessThan(search.frame.maxY, grid.frame.minY)
        XCTAssertGreaterThanOrEqual(app.buttons["Fixture 0"].firstMatch.frame.minY, grid.frame.minY)
    }

    @MainActor
    func testFullScreenHasNoTopRightButtons() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher-for-ui-testing", "--ui-testing-isolated-data", "--ui-testing-fixtures"]
        app.launch()
        let root = app.descendants(matching: .any).matching(identifier: "launcher.root").firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["编辑布局"].exists)
        XCTAssertFalse(app.buttons["选择应用"].exists)
        XCTAssertFalse(app.buttons["完成编辑"].exists)
    }

    @MainActor
    func testBatchActionsAppearOnlyWhileSelecting() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing", "--ui-testing-isolated-data",
            "--ui-testing-fixtures", "--ui-testing-selecting-mode", "--ui-testing-window-mode",
        ]
        app.launch()
        let done = app.buttons["完成"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["已选择 0 个应用"].exists)
        XCTAssertTrue(app.buttons["全选"].exists)
        XCTAssertTrue(app.buttons["隐藏"].exists)
        XCTAssertTrue(app.buttons["移到废纸篓"].exists)
        done.tap()
        let controlsGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["全选"].firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [controlsGone], timeout: 3), .completed)
        XCTAssertFalse(app.buttons["编辑布局"].exists)
        XCTAssertFalse(app.buttons["选择应用"].exists)
    }

    @MainActor
    func testOptionHeldShowsUninstallButton() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing",
            "--ui-testing-isolated-data",
            "--ui-testing-fixtures",
            "--ui-testing-window-mode",
            "--ui-testing-option-held",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Fixture 0"].waitForExistence(timeout: 8))

        let uninstallButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "uninstall.")
        ).firstMatch
        XCTAssertTrue(uninstallButton.waitForExistence(timeout: 3))
    }

    @MainActor
    func testOptionUninstallRequiresConfirmationAndCanBeCancelled() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing",
            "--ui-testing-isolated-data",
            "--ui-testing-fixtures",
            "--ui-testing-window-mode",
            "--ui-testing-option-held",
        ]
        app.launch()
        app.activate()

        let uninstallButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "uninstall.")
        ).firstMatch
        XCTAssertTrue(uninstallButton.waitForExistence(timeout: 8))
        uninstallButton.click()
        let cancelButton = app.buttons["trash.cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), app.debugDescription)
        cancelButton.tap()
        XCTAssertTrue(uninstallButton.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Fixture 0"].exists)
    }

    @MainActor
    func testOptionHeldShowsUninstallButtonInsideFolderInWindowMode() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--show-launcher-for-ui-testing",
            "--ui-testing-isolated-data",
            "--ui-testing-fixtures",
            "--ui-testing-existing-folder",
            "--ui-testing-window-mode",
            "--ui-testing-option-held",
        ]
        app.launch()

        let folder = app.buttons["Fixture Folder"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 8))
        folder.tap()
        let uninstallButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "folder.uninstall.")
        ).firstMatch
        XCTAssertTrue(uninstallButton.waitForExistence(timeout: 3))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
