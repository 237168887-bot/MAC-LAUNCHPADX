import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class LauncherViewModel {
    private let repository: LayoutRepository
    private let settings: SettingsStore
    private let discovery: ApplicationDiscoveryService
    private let launcher: ApplicationLauncherService
    private let icons: IconProvider
    private let searchIndex: SearchIndex

    private(set) var discoveredApplications: [InstalledApplication] = []
    private(set) var snapshot = LauncherSnapshot(entries: [], applications: [:], hiddenRecordIDs: [])
    private(set) var searchResults: [SearchResult] = []
    var searchQuery = "" { didSet { refreshSearch() } }
    var selectedSearchIndex = 0
    var selectedPage = 0
    var isEditing = false
    var isMultiSelecting = false
    private(set) var isOptionUninstallMode = false
    var selectedApplicationRecordIDs: Set<UUID> = []
    var openedFolderID: UUID?
    var renamingFolderID: UUID?
    var errorMessage: String?
    var shouldFocusSearch = false
    var onDismiss: (() -> Void)?
    private var draggedEntryID: UUID?
    private var nativeDraggedEntryID: UUID?
    @ObservationIgnored var rootGridFrame: CGRect = .zero
    @ObservationIgnored var rootEntryFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var originalDragFrame: CGRect?
    @ObservationIgnored private var returningToOrigin = false
    private(set) var groupingTargetID: UUID?
    private var dragPreviewEntries: [LauncherEntry]?
    private var draggedFolderApplicationRecordID: UUID?
    private var folderDragPreviewRecordIDs: [UUID]?
    @ObservationIgnored private var groupingCandidateID: UUID?
    @ObservationIgnored private var groupingHoverTask: Task<Void, Never>?
    @ObservationIgnored private var lastReorderTargetID: UUID?
    @ObservationIgnored private var reorderPreviews: [UUID: [LauncherEntry]] = [:]
    @ObservationIgnored private var reorderPreviewCapacity = 0
    @ObservationIgnored private var dragEdgeTurnedPage = false
    @ObservationIgnored private var scanInProgress = false
    @ObservationIgnored private var scanRequestedWhileRunning = false
    @ObservationIgnored private var iconPrewarmTask: Task<Void, Never>?

    private enum DragEdge: Equatable {
        case previous
        case next
    }

    init(
        repository: LayoutRepository,
        settings: SettingsStore,
        discovery: ApplicationDiscoveryService,
        launcher: ApplicationLauncherService,
        icons: IconProvider,
        searchIndex: SearchIndex
    ) {
        self.repository = repository
        self.settings = settings
        self.discovery = discovery
        self.launcher = launcher
        self.icons = icons
        self.searchIndex = searchIndex
    }

    private var displayedEntries: [LauncherEntry] { dragPreviewEntries ?? snapshot.entries }
    var pageCount: Int {
        let entries = draggedEntryID == nil
            ? displayedEntries
            : displayedEntries + snapshot.entries
        let lastPage = entries.map { max(0, $0.layoutIndex) / settings.gridCapacity }.max() ?? 0
        return lastPage + 1
    }
    var currentPageEntries: [LauncherEntry] {
        entries(forPage: selectedPage)
    }
    var allRootEntries: [LauncherEntry] { displayedEntries.sorted { $0.layoutIndex < $1.layoutIndex } }

    func entries(forPage page: Int) -> [LauncherEntry] {
        let range = (page * settings.gridCapacity)..<((page + 1) * settings.gridCapacity)
        return displayedEntries
            .filter { range.contains($0.layoutIndex) }
            .sorted { $0.layoutIndex < $1.layoutIndex }
    }
    var openedFolder: LauncherEntry? { snapshot.entries.first { $0.id == openedFolderID } }
    var openedFolderApplications: [(UUID, InstalledApplication)] {
        guard let folder = openedFolder else { return [] }
        let recordIDs = folderDragPreviewRecordIDs ?? folder.childApplicationRecordIDs
        return recordIDs.compactMap { id in snapshot.applications[id].map { (id, $0) } }
    }

    func prepareForPresentation() {
        selectedPage = min(selectedPage, pageCount - 1)
        shouldFocusSearch = settings.focusSearchOnShow
    }

    func restoreCachedApplications() {
        do {
            discoveredApplications = try repository.cachedApplications()
            try reloadSnapshot()
            scheduleIconPrewarming()
        } catch {
            presentError(error)
        }
    }

    func rescan() async {
        guard !scanInProgress else {
            scanRequestedWhileRunning = true
            return
        }

        scanInProgress = true
        defer { scanInProgress = false }

        repeat {
            scanRequestedWhileRunning = false
            let roots = settings.allScanRoots
            let apps = await discovery.scan(roots: roots)
            guard !Task.isCancelled else { return }
            applyScanResults(apps)
        } while scanRequestedWhileRunning && !Task.isCancelled
    }

    func applyScanResults(_ applications: [InstalledApplication]) {
        guard !Self.hasSameDiscoveredApplications(applications, discoveredApplications) else { return }
        do {
            try repository.reconcile(discovered: applications)
            let nextSnapshot = try repository.snapshot(discoveredApplications: applications)
            discoveredApplications = applications
            applySnapshot(nextSnapshot)
            scheduleIconPrewarming()
        } catch { presentError(error) }
    }

#if DEBUG
    func loadForUITesting(_ applications: [InstalledApplication]) {
        do {
            try repository.reconcile(discovered: applications)
            discoveredApplications = applications
            try reloadSnapshot()
            scheduleIconPrewarming()
        } catch {
            presentError(error)
        }
    }
#endif

    func reloadSnapshot(refreshesSearch: Bool = true) throws {
        applySnapshot(
            try repository.snapshot(discoveredApplications: discoveredApplications),
            refreshesSearch: refreshesSearch
        )
    }

    private func applySnapshot(_ nextSnapshot: LauncherSnapshot, refreshesSearch: Bool = true) {
        reorderPreviews.removeAll(keepingCapacity: true)
        snapshot = nextSnapshot
        selectedPage = min(selectedPage, pageCount - 1)
        if refreshesSearch {
            refreshSearch()
        }
    }

    func launch(entry: LauncherEntry) {
        guard let application = entry.application, let recordID = entry.applicationRecordID else { return }
        Task {
            do {
                try await launcher.launch(application)
                try repository.recordLaunched(recordID: recordID)
                try reloadSnapshot()
                onDismiss?()
            } catch {
                presentError(error)
            }
        }
    }

    func launch(result: SearchResult) {
        Task {
            do {
                try await launcher.launch(result.application)
                try repository.recordLaunched(recordID: result.recordID)
                try reloadSnapshot()
                onDismiss?()
            } catch {
                presentError(error)
            }
        }
    }

    func launch(application: InstalledApplication, recordID: UUID) {
        Task {
            do {
                try await launcher.launch(application)
                try repository.recordLaunched(recordID: recordID)
                try reloadSnapshot()
                onDismiss?()
            } catch {
                presentError(error)
            }
        }
    }

    func launchSelectedSearchResult() {
        guard searchResults.indices.contains(selectedSearchIndex) else { return }
        launch(result: searchResults[selectedSearchIndex])
    }

    func moveSearchSelection(by delta: Int) {
        guard !searchResults.isEmpty else { return }
        selectedSearchIndex = min(max(selectedSearchIndex + delta, 0), searchResults.count - 1)
    }

    func changePage(by delta: Int) {
        selectedPage = min(max(selectedPage + delta, 0), pageCount - 1)
    }

    func handleTrackpadGesture(_ gesture: TrackpadGesture) -> Bool {
        guard renamingFolderID == nil else { return false }
        guard settings.gridMode == .pages else { return false }
        switch gesture {
        case .previousPage:
            guard searchQuery.isEmpty, openedFolderID == nil, !isEditing, selectedPage > 0 else { return false }
            changePage(by: -1)
        case .nextPage:
            guard searchQuery.isEmpty, openedFolderID == nil, !isEditing, selectedPage < pageCount - 1 else { return false }
            changePage(by: 1)
        case .dismiss:
            if openedFolderID != nil { closeFolder() }
            else if !searchQuery.isEmpty { searchQuery = "" }
            else { onDismiss?() }
        }
        return true
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            handleEscapeKey()
            return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shortcutModifiers = modifiers.intersection([.command, .shift, .option, .control])
        if shortcutModifiers == [.command, .shift] {
            switch event.keyCode {
            case 14: // E
                toggleEditing()
                return true
            case 0: // A
                if isEditing { endEditing() }
                if !isMultiSelecting { toggleMultiSelecting() }
                return true
            default:
                break
            }
        }
        guard searchQuery.isEmpty, openedFolderID == nil, !isEditing else { return false }
        if settings.previousPageHotKey.matches(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            return handleTrackpadGesture(.previousPage)
        }
        if settings.nextPageHotKey.matches(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            return handleTrackpadGesture(.nextPage)
        }
        return false
    }

    func handleEscapeKey() {
        if renamingFolderID != nil { renamingFolderID = nil }
        else if openedFolderID != nil { closeFolder() }
        else if !searchQuery.isEmpty { searchQuery = "" }
        else if isMultiSelecting { toggleMultiSelecting() }
        else if isEditing { endEditing() }
        else { onDismiss?() }
    }

    func open(_ entry: LauncherEntry) {
        if entry.kind == .folder {
            openedFolderID = entry.id
        } else if !isEditing, !isOptionUninstallMode {
            launch(entry: entry)
        }
    }

    func setOptionUninstallMode(_ isPressed: Bool) {
        isOptionUninstallMode = isPressed
    }

    func beginRenamingFolder(_ entry: LauncherEntry) {
        guard isEditing, entry.kind == .folder else { return }
        openedFolderID = entry.id
        renamingFolderID = entry.id
    }

    func closeFolder() {
        finishFolderDragging()
        renamingFolderID = nil
        openedFolderID = nil
    }

    func toggleEditing() {
        if isEditing { endEditing() }
        else { beginEditing() }
    }

    func beginEditing() {
        guard searchQuery.isEmpty, openedFolderID == nil else { return }
        isEditing = true
    }

    func endEditing() {
        finishDragging()
        finishFolderDragging()
        renamingFolderID = nil
        isEditing = false
    }

    func cancelTransientEditing() {
        endEditing()
        isOptionUninstallMode = false
        openedFolderID = nil
        searchQuery = ""
    }

    func hide(entry: LauncherEntry) {
        guard let recordID = entry.applicationRecordID else { return }
        do { try repository.setHidden(true, recordID: recordID); try reloadSnapshot() }
        catch { presentError(error) }
    }

    func toggleMultiSelecting() {
        isMultiSelecting.toggle()
        selectedApplicationRecordIDs.removeAll()
    }

    func toggleSelection(for entry: LauncherEntry) {
        guard let recordID = entry.applicationRecordID else { return }
        toggleSelection(for: recordID)
    }

    func toggleSelection(for recordID: UUID) {
        guard snapshot.applications[recordID] != nil,
              !snapshot.hiddenRecordIDs.contains(recordID) else { return }
        if selectedApplicationRecordIDs.contains(recordID) { selectedApplicationRecordIDs.remove(recordID) }
        else { selectedApplicationRecordIDs.insert(recordID) }
    }

    func selectAllApplications() {
        selectedApplicationRecordIDs = Set(snapshot.applications.keys).subtracting(snapshot.hiddenRecordIDs)
    }

    func clearSelection() { selectedApplicationRecordIDs.removeAll() }

    func renameApplication(recordID: UUID, to name: String) {
        do { try repository.setAlias(name, recordID: recordID); try reloadSnapshot() }
        catch { presentError(error) }
    }

    func reveal(recordID: UUID) {
        guard let app = snapshot.applications[recordID] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
    }

    func unhide(recordID: UUID) {
        do { try repository.setHidden(false, recordID: recordID); try reloadSnapshot() }
        catch { presentError(error) }
    }

    func application(for recordID: UUID) -> InstalledApplication? { snapshot.applications[recordID] }

    func removeApplication(recordID: UUID) {
        do {
            try repository.deleteApplication(recordID: recordID)
            selectedApplicationRecordIDs.remove(recordID)
            try reloadSnapshot()
        } catch { presentError(error) }
    }

    func hideSelectedApplications() {
        do {
            for recordID in selectedApplicationRecordIDs { try repository.setHidden(true, recordID: recordID) }
            selectedApplicationRecordIDs.removeAll()
            isMultiSelecting = false
            try reloadSnapshot()
        } catch { presentError(error) }
    }

    func reveal(entry: LauncherEntry) {
        guard let app = entry.application else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
    }

    func beginDraggingFromPress(_ entry: LauncherEntry) {
        beginDragging(entry)
        if draggedEntryID != nil { nativeDraggedEntryID = entry.id }
    }

    func completeDraggingFromSourceIfNeeded() {
        defer { nativeDraggedEntryID = nil }
        guard draggedEntryID != nil else { return }
        if dragEdgeTurnedPage {
            _ = performBackgroundDrop()
        } else {
            finishDragging()
        }
    }

    private func beginDragging(_ entry: LauncherEntry) {
        guard isEditing,
              snapshot.entries.contains(where: { $0.id == entry.id }) else { return }
        cancelGroupingHover()
        reorderPreviews.removeAll(keepingCapacity: true)
        draggedEntryID = entry.id
        originalDragFrame = rootEntryFrames[entry.id].map {
            $0.offsetBy(dx: rootGridFrame.minX, dy: rootGridFrame.minY)
        }
        returningToOrigin = false
        groupingTargetID = nil
        lastReorderTargetID = nil
        // Keep the source view alive for the whole native dragging session.
        // Removing it from ForEach here cancels AppKit's source before drop.
        dragPreviewEntries = snapshot.entries
    }

    func isDragging(_ entry: LauncherEntry) -> Bool {
        draggedEntryID == entry.id || nativeDraggedEntryID == entry.id
    }

    var isDraggingSession: Bool {
        draggedEntryID != nil || draggedFolderApplicationRecordID != nil
    }

    func moveDraggedEntry(toOriginalSlotOf targetID: UUID) {
        guard let sourceID = draggedEntryID else { return }
        if reorderPreviewCapacity != settings.gridCapacity {
            reorderPreviews.removeAll(keepingCapacity: true)
            reorderPreviewCapacity = settings.gridCapacity
        }
        lastReorderTargetID = targetID
        if let cached = reorderPreviews[targetID] {
            updateDragPreview(cached)
            return
        }
        if sourceID == targetID {
            updateDragPreview(snapshot.entries)
        } else {
            updateDragPreview(
                Self.reorderedEntries(
                    moving: sourceID,
                    toOriginalSlotOf: targetID,
                    in: snapshot.entries,
                    capacity: settings.gridCapacity
                )
            )
        }
        reorderPreviews[targetID] = dragPreviewEntries
    }

    private func moveDraggedEntry(toPage page: Int) {
        guard let sourceID = draggedEntryID else { return }
        updateDragPreview(
            Self.movedEntries(
                moving: sourceID,
                toPage: page,
                in: snapshot.entries,
                capacity: settings.gridCapacity
            )
        )
    }

    func updateRootDragLocation(_ screenPoint: NSPoint, windowFrame: CGRect) {
        guard draggedEntryID != nil,
              !windowFrame.isEmpty else { return }
        let point = CGPoint(x: screenPoint.x - windowFrame.minX,
                            y: windowFrame.maxY - screenPoint.y)
        let isOriginalPage = snapshot.entries.first(where: { $0.id == draggedEntryID })
            .map { $0.layoutIndex / settings.gridCapacity == selectedPage } ?? false
        returningToOrigin = isOriginalPage && originalDragFrame?.contains(point) == true
        if returningToOrigin {
            cancelGroupingHover()
            groupingTargetID = nil
            dragEdgeTurnedPage = false
            if let draggedEntryID { moveDraggedEntry(toOriginalSlotOf: draggedEntryID) }
            return
        }
        let threshold = min(140, windowFrame.width * 0.10)
        let edge = Self.dragPageDelta(
            screenX: screenPoint.x,
            windowFrame: windowFrame,
            threshold: threshold
        ).map { $0 < 0 ? DragEdge.previous : DragEdge.next }

        guard let edge else {
            dragEdgeTurnedPage = false
            return
        }
        let delta = edge == .previous ? -1 : 1
        guard !dragEdgeTurnedPage,
              let destinationPage = Self.edgeDestinationPage(
                  currentPage: selectedPage,
                  pageCount: pageCount,
                  delta: delta
              ) else { return }
        selectedPage = destinationPage
        moveDraggedEntry(toPage: destinationPage)
        dragEdgeTurnedPage = true
    }

    nonisolated static func dragPageDelta(
        screenX: CGFloat,
        windowFrame: CGRect,
        threshold: CGFloat
    ) -> Int? {
        if screenX <= windowFrame.minX + threshold { return -1 }
        if screenX >= windowFrame.maxX - threshold { return 1 }
        return nil
    }

    nonisolated static func edgeDestinationPage(
        currentPage: Int,
        pageCount: Int,
        delta: Int
    ) -> Int? {
        let destination = currentPage + delta
        return (0..<pageCount).contains(destination) ? destination : nil
    }

    func dragMoved(over target: LauncherEntry, grouping: Bool) {
        guard !returningToOrigin else { return }
        guard isEditing,
              let sourceID = draggedEntryID,
              sourceID != target.id,
              let source = snapshot.entries.first(where: { $0.id == sourceID }) else { return }

        let canGroupWithTarget = target.kind == .folder
            || (grouping && target.kind == .application)
        if source.kind == .application, canGroupWithTarget {
            guard groupingCandidateID != target.id, groupingTargetID != target.id else { return }
            cancelGroupingHover()
            groupingTargetID = nil
            groupingCandidateID = target.id
            groupingHoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled,
                      self?.draggedEntryID == sourceID,
                      self?.groupingCandidateID == target.id else { return }
                self?.groupingTargetID = target.id
            }
            return
        }

        if lastReorderTargetID != target.id {
            moveDraggedEntry(toOriginalSlotOf: target.id)
        }

        if groupingCandidateID != nil || groupingTargetID != nil {
            cancelGroupingHover()
            groupingTargetID = nil
        }
    }

    func dragExited(target: LauncherEntry) {
        if groupingCandidateID == target.id { cancelGroupingHover() }
        if groupingTargetID == target.id { groupingTargetID = nil }
    }

    func performDrop(on target: LauncherEntry, grouping: Bool = false) -> Bool {
        defer { finishDragging() }
        guard isEditing,
              let sourceID = draggedEntryID else { return false }
        do {
            if returningToOrigin {
                moveDraggedEntry(toOriginalSlotOf: sourceID)
                try commitPreviewMove(sourceID: sourceID, fallbackDestinationID: nil)
                return true
            }
            if dragEdgeTurnedPage {
                moveDraggedEntry(toPage: selectedPage)
                try commitPreviewMove(sourceID: sourceID, fallbackDestinationID: nil)
                return true
            }
            if let folderID = existingFolderDropTargetID(explicitTarget: target) {
                try repository.addRootApplication(sourceID, toFolder: folderID)
                try reloadSnapshot(refreshesSearch: false)
                return true
            }
            if sourceID == target.id {
                try commitPreviewMove(sourceID: sourceID, fallbackDestinationID: nil)
                return true
            }
            guard let source = snapshot.entries.first(where: { $0.id == sourceID }) else { return false }
            let createdFolderID: UUID?
            if (grouping || groupingTargetID == target.id),
               source.kind == .application,
               target.kind == .application {
                createdFolderID = try repository.createFolder(draggedEntryID: sourceID, targetEntryID: target.id)
            } else {
                moveDraggedEntry(toOriginalSlotOf: target.id)
                try commitPreviewMove(sourceID: sourceID, fallbackDestinationID: target.id)
                return true
            }
            try reloadSnapshot(refreshesSearch: false)
            if let createdFolderID {
                openedFolderID = createdFolderID
                renamingFolderID = createdFolderID
                isEditing = false
                selectedApplicationRecordIDs.removeAll()
            }
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func performBackgroundDrop() -> Bool {
        defer { finishDragging() }
        guard let sourceID = draggedEntryID else { return false }
        do {
            if returningToOrigin {
                moveDraggedEntry(toOriginalSlotOf: sourceID)
                try commitPreviewMove(sourceID: sourceID, fallbackDestinationID: nil)
                return true
            }
            if let folderID = activeExistingFolderTargetID {
                try repository.addRootApplication(sourceID, toFolder: folderID)
            } else {
                moveDraggedEntry(toPage: selectedPage)
                try commitPreviewMove(sourceID: sourceID, fallbackDestinationID: nil)
                return true
            }
            try reloadSnapshot(refreshesSearch: false)
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    nonisolated static func compactedEntries(
        afterLifting sourceID: UUID,
        from entries: [LauncherEntry]
    ) -> [LauncherEntry] {
        entries.filter { $0.id != sourceID }
    }

    nonisolated static func compactedEntries(
        afterLifting sourceID: UUID,
        from entries: [LauncherEntry],
        capacity: Int
    ) -> [LauncherEntry] {
        guard let source = entries.first(where: { $0.id == sourceID }) else { return entries }
        let sourcePage = page(of: source, capacity: capacity)
        return assigningPage(
            sourcePage,
            orderedIDs: entries
                .filter { $0.id != sourceID && page(of: $0, capacity: capacity) == sourcePage }
                .sorted { $0.layoutIndex < $1.layoutIndex }
                .map(\.id),
            in: entries.filter { $0.id != sourceID },
            capacity: capacity
        )
    }

    nonisolated static func reorderedEntries(
        moving sourceID: UUID,
        relativeTo targetID: UUID,
        insertAfter: Bool,
        in entries: [LauncherEntry]
    ) -> [LauncherEntry] {
        guard let source = entries.first(where: { $0.id == sourceID }) else { return entries }
        var result = entries.filter { $0.id != sourceID }
        guard let targetIndex = result.firstIndex(where: { $0.id == targetID }) else { return result }
        result.insert(source, at: targetIndex + (insertAfter ? 1 : 0))
        return result
    }

    nonisolated static func reorderedEntries(
        moving sourceID: UUID,
        toOriginalSlotOf targetID: UUID,
        in entries: [LauncherEntry]
    ) -> [LauncherEntry] {
        guard let sourceIndex = entries.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = entries.firstIndex(where: { $0.id == targetID }) else {
            return entries
        }
        return reorderedEntries(
            moving: sourceID,
            relativeTo: targetID,
            insertAfter: sourceIndex < targetIndex,
            in: entries
        )
    }

    nonisolated static func reorderedEntries(
        moving sourceID: UUID,
        toOriginalSlotOf targetID: UUID,
        in entries: [LauncherEntry],
        capacity: Int
    ) -> [LauncherEntry] {
        guard capacity > 0,
              let source = entries.first(where: { $0.id == sourceID }),
              let target = entries.first(where: { $0.id == targetID }) else { return entries }
        let sourcePage = page(of: source, capacity: capacity)
        let targetPage = page(of: target, capacity: capacity)
        var result = compactedEntries(
            afterLifting: sourceID,
            from: entries,
            capacity: capacity
        )
        var destinationIDs = result
            .filter { page(of: $0, capacity: capacity) == targetPage }
            .sorted { $0.layoutIndex < $1.layoutIndex }
            .map(\.id)
        guard let targetIndex = destinationIDs.firstIndex(of: targetID) else { return result }
        let insertAfter = sourcePage == targetPage && source.layoutIndex < target.layoutIndex
        destinationIDs.insert(sourceID, at: targetIndex + (insertAfter ? 1 : 0))
        result.append(source)

        if destinationIDs.count > capacity,
           let displacedID = destinationIDs.last(where: { $0 != sourceID }) {
            destinationIDs.removeAll { $0 == displacedID }
            var sourcePageIDs = result
                .filter {
                    $0.id != sourceID
                        && $0.id != displacedID
                        && page(of: $0, capacity: capacity) == sourcePage
                }
                .sorted { $0.layoutIndex < $1.layoutIndex }
                .map(\.id)
            sourcePageIDs.append(displacedID)
            result = assigningPage(
                sourcePage,
                orderedIDs: sourcePageIDs,
                in: result,
                capacity: capacity
            )
        }
        return assigningPage(
            targetPage,
            orderedIDs: destinationIDs,
            in: result,
            capacity: capacity
        )
    }

    nonisolated static func movedEntries(
        moving sourceID: UUID,
        toPage destinationPage: Int,
        in entries: [LauncherEntry],
        capacity: Int
    ) -> [LauncherEntry] {
        guard capacity > 0,
              destinationPage >= 0,
              let source = entries.first(where: { $0.id == sourceID }) else { return entries }
        let sourcePage = page(of: source, capacity: capacity)
        var result = compactedEntries(
            afterLifting: sourceID,
            from: entries,
            capacity: capacity
        )
        var destinationIDs = result
            .filter { page(of: $0, capacity: capacity) == destinationPage }
            .sorted { $0.layoutIndex < $1.layoutIndex }
            .map(\.id)
        result.append(source)

        if destinationPage != sourcePage, destinationIDs.count >= capacity,
           let displacedID = destinationIDs.last {
            destinationIDs.removeLast()
            var sourcePageIDs = result
                .filter {
                    $0.id != sourceID
                        && $0.id != displacedID
                        && page(of: $0, capacity: capacity) == sourcePage
                }
                .sorted { $0.layoutIndex < $1.layoutIndex }
                .map(\.id)
            sourcePageIDs.append(displacedID)
            result = assigningPage(
                sourcePage,
                orderedIDs: sourcePageIDs,
                in: result,
                capacity: capacity
            )
        }
        destinationIDs.append(sourceID)
        return assigningPage(
            destinationPage,
            orderedIDs: destinationIDs,
            in: result,
            capacity: capacity
        )
    }

    nonisolated private static func page(
        of entry: LauncherEntry,
        capacity: Int
    ) -> Int {
        max(0, entry.layoutIndex) / max(1, capacity)
    }

    nonisolated private static func assigningPage(
        _ page: Int,
        orderedIDs: [UUID],
        in entries: [LauncherEntry],
        capacity: Int
    ) -> [LauncherEntry] {
        let slots = Dictionary(
            uniqueKeysWithValues: orderedIDs.enumerated().map {
                ($0.element, page * capacity + $0.offset)
            }
        )
        return entries
            .map { entry in
                guard let slot = slots[entry.id] else { return entry }
                var updated = entry
                updated.layoutIndex = slot
                return updated
            }
            .sorted {
                if $0.layoutIndex == $1.layoutIndex {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.layoutIndex < $1.layoutIndex
            }
    }

    func folderDragProvider(recordID: UUID) -> NSItemProvider {
        guard isEditing else { return NSItemProvider() }
        let provider = NSItemProvider(object: recordID.uuidString as NSString)
        DispatchQueue.main.async { [weak self] in
            self?.beginFolderDragging(recordID: recordID)
        }
        return provider
    }

    private func beginFolderDragging(recordID: UUID) {
        guard isEditing,
              let folder = openedFolder,
              folder.childApplicationRecordIDs.contains(recordID) else { return }
        draggedFolderApplicationRecordID = recordID
        // SwiftUI's drag source must remain in the folder hierarchy until drop.
        folderDragPreviewRecordIDs = folder.childApplicationRecordIDs
    }

    func isDraggingFolderApplication(recordID: UUID) -> Bool {
        draggedFolderApplicationRecordID == recordID
    }

    func folderDragMoved(over targetRecordID: UUID) {
        guard let sourceID = draggedFolderApplicationRecordID,
              let folder = openedFolder,
              sourceID != targetRecordID else { return }
        let reordered = Self.reorderedRecordIDs(
            moving: sourceID,
            toOriginalSlotOf: targetRecordID,
            in: folder.childApplicationRecordIDs
        )
        guard folderDragPreviewRecordIDs != reordered else { return }
        folderDragPreviewRecordIDs = reordered
    }

    func performFolderDrop(on targetRecordID: UUID) -> Bool {
        guard let sourceID = draggedFolderApplicationRecordID,
              let folderID = openedFolderID else { return false }
        folderDragMoved(over: targetRecordID)
        return commitFolderOrder(folderID: folderID, sourceID: sourceID)
    }

    func performFolderBackgroundDrop() -> Bool {
        guard let sourceID = draggedFolderApplicationRecordID,
              let folderID = openedFolderID else { return false }
        return commitFolderOrder(folderID: folderID, sourceID: sourceID)
    }

    func performFolderDropOutside() -> Bool {
        guard let recordID = draggedFolderApplicationRecordID else { return false }
        do {
            try repository.removeFromFolder(recordID: recordID)
            finishFolderDragging()
            try reloadSnapshot(refreshesSearch: false)
            renamingFolderID = nil
            openedFolderID = nil
            return true
        } catch {
            finishFolderDragging()
            presentError(error)
            return false
        }
    }

    nonisolated static func reorderedRecordIDs(
        moving sourceID: UUID,
        toOriginalSlotOf targetID: UUID,
        in recordIDs: [UUID]
    ) -> [UUID] {
        guard let sourceIndex = recordIDs.firstIndex(of: sourceID),
              let targetIndex = recordIDs.firstIndex(of: targetID) else {
            return recordIDs
        }
        var reordered = recordIDs.filter { $0 != sourceID }
        guard let compactedTargetIndex = reordered.firstIndex(of: targetID) else {
            return recordIDs
        }
        reordered.insert(sourceID, at: compactedTargetIndex + (sourceIndex < targetIndex ? 1 : 0))
        return reordered
    }

    func saveFolderName(_ name: String) {
        guard let id = renamingFolderID else { return }
        do { try repository.renameFolder(id: id, name: name); renamingFolderID = nil; try reloadSnapshot() }
        catch { presentError(error) }
    }

    func removeFromFolder(recordID: UUID) {
        do {
            try repository.removeFromFolder(recordID: recordID)
            try reloadSnapshot()
            if openedFolder == nil {
                openedFolderID = nil
                renamingFolderID = nil
            }
        }
        catch { presentError(error) }
    }

    func resetLayout() {
        do { try repository.resetLayout(); try reloadSnapshot() }
        catch { presentError(error) }
    }

    func purgeExpiredMissingRecords() {
        do {
            try repository.purgeMissing(olderThan: Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast)
            try reloadSnapshot()
        } catch {
            presentError(error)
        }
    }

    func clearIconCache() {
        icons.clearCache()
        scheduleIconPrewarming()
    }
    func icon(for application: InstalledApplication) -> NSImage { icons.icon(for: application) }
    func groupingPreviewImages(for entry: LauncherEntry) -> [NSImage] {
        guard groupingTargetID == entry.id else { return [] }
        let draggedImage = draggedEntryID
            .flatMap { id in snapshot.entries.first(where: { $0.id == id })?.application }
            .map(icon(for:))
        if entry.kind == .folder {
            let existingImages = entry.childApplicationRecordIDs.compactMap {
                snapshot.applications[$0].map(icon(for:))
            }
            return Array((existingImages + [draggedImage].compactMap { $0 }).prefix(9))
        }
        return [entry.application.map(icon(for:)), draggedImage].compactMap { $0 }
    }
    func presentError(_ error: Error) { errorMessage = error.localizedDescription }

    nonisolated static func hasSameDiscoveredApplications(
        _ lhs: [InstalledApplication],
        _ rhs: [InstalledApplication]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let rhsByPath = Dictionary(grouping: rhs, by: \.normalizedPath)
        guard rhsByPath.values.allSatisfy({ $0.count == 1 }) else { return false }
        return lhs.allSatisfy { application in
            guard let existing = rhsByPath[application.normalizedPath]?.first else { return false }
            return application.bundleIdentifier == existing.bundleIdentifier
                && application.displayName == existing.displayName
                && application.version == existing.version
                && application.isSystemApplication == existing.isSystemApplication
        }
    }

    private func scheduleIconPrewarming() {
        iconPrewarmTask?.cancel()
        let applications = prioritizedApplicationsForIconPrewarming(
            snapshot: snapshot,
            discoveredApplications: discoveredApplications
        )
        iconPrewarmTask = Task(priority: .background) { [icons] in
            await icons.prewarm(applications)
        }
    }

    private func prioritizedApplicationsForIconPrewarming(
        snapshot: LauncherSnapshot,
        discoveredApplications: [InstalledApplication]
    ) -> [InstalledApplication] {
        let currentRange = (selectedPage * settings.gridCapacity)..<((selectedPage + 1) * settings.gridCapacity)
        let currentEntries = snapshot.entries
            .filter { currentRange.contains($0.layoutIndex) }
            .sorted { $0.layoutIndex < $1.layoutIndex }
        let currentEntryIDs = Set(currentEntries.map(\.id))
        let orderedEntries = currentEntries + snapshot.entries.filter { !currentEntryIDs.contains($0.id) }
        var seenPaths = Set<String>()
        var applications: [InstalledApplication] = []

        func append(_ application: InstalledApplication?) {
            guard let application,
                  seenPaths.insert(application.normalizedPath).inserted else { return }
            applications.append(application)
        }

        for entry in orderedEntries {
            append(entry.application)
            for recordID in entry.childApplicationRecordIDs {
                append(snapshot.applications[recordID])
            }
        }
        for application in discoveredApplications {
            append(application)
        }
        return applications
    }

    private func refreshSearch() {
        do {
            let records = try repository.visibleRecords(discoveredApplications: discoveredApplications)
            searchResults = searchIndex.search(query: searchQuery, records: records, sort: settings.searchSort)
            selectedSearchIndex = min(selectedSearchIndex, max(searchResults.count - 1, 0))
        } catch {
            presentError(error)
        }
    }

    private func commitPreviewMove(sourceID: UUID, fallbackDestinationID _: UUID?) throws {
        if dragPreviewEntries?.contains(where: { $0.id == sourceID }) != true {
            moveDraggedEntry(toPage: selectedPage)
        }
        guard let dragPreviewEntries else { return }
        try repository.applyRootLayout(dragPreviewEntries)
        // The preview is already the committed layout. Keep its identities and geometry
        // instead of fetching and reconstructing every application on mouse-up.
        snapshot.entries = dragPreviewEntries
    }

    private func existingFolderDropTargetID(explicitTarget: LauncherEntry) -> UUID? {
        if explicitTarget.kind == .folder {
            return explicitTarget.id
        }
        return activeExistingFolderTargetID
    }

    private var activeExistingFolderTargetID: UUID? {
        groupingTargetID.flatMap { targetID in
            snapshot.entries.first {
                $0.id == targetID && $0.kind == .folder
            }?.id
        }
    }

    nonisolated static func dropDestinationID(
        sourceID: UUID,
        previewEntries: [LauncherEntry]?,
        fallbackDestinationID: UUID?
    ) -> UUID? {
        guard let previewEntries,
              let sourceIndex = previewEntries.firstIndex(where: { $0.id == sourceID }) else {
            return fallbackDestinationID
        }
        let nextIndex = previewEntries.index(after: sourceIndex)
        return previewEntries.indices.contains(nextIndex) ? previewEntries[nextIndex].id : nil
    }

    private func cancelGroupingHover() {
        groupingHoverTask?.cancel()
        groupingHoverTask = nil
        groupingCandidateID = nil
    }

    private func updateDragPreview(_ entries: [LauncherEntry]) {
        guard !Self.hasSameOrder(dragPreviewEntries, entries) else { return }
        dragPreviewEntries = entries
    }

    nonisolated private static func hasSameOrder(
        _ lhs: [LauncherEntry]?,
        _ rhs: [LauncherEntry]
    ) -> Bool {
        guard let lhs, lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0.id == $1.id && $0.layoutIndex == $1.layoutIndex }
    }

    private func finishDragging() {
        returningToOrigin = false
        originalDragFrame = nil
        reorderPreviews.removeAll(keepingCapacity: true)
        cancelGroupingHover()
        dragEdgeTurnedPage = false
        lastReorderTargetID = nil
        draggedEntryID = nil
        groupingTargetID = nil
        dragPreviewEntries = nil
    }

    private func commitFolderOrder(folderID: UUID, sourceID: UUID) -> Bool {
        var orderedRecordIDs = folderDragPreviewRecordIDs ?? openedFolder?.childApplicationRecordIDs ?? []
        if !orderedRecordIDs.contains(sourceID) {
            orderedRecordIDs.append(sourceID)
        }
        do {
            try repository.reorderFolderApplications(
                folderID: folderID,
                orderedRecordIDs: orderedRecordIDs
            )
            finishFolderDragging()
            try reloadSnapshot(refreshesSearch: false)
            return true
        } catch {
            finishFolderDragging()
            presentError(error)
            return false
        }
    }

    private func finishFolderDragging() {
        draggedFolderApplicationRecordID = nil
        folderDragPreviewRecordIDs = nil
    }
}
