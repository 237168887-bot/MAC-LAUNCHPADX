import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var viewModel: LauncherViewModel
    @Bindable var settings: SettingsStore
    let pointerRouter: LauncherPointerRouter
    @State private var glassGlowPulse = false
    @FocusState private var searchFocused: Bool
    @State private var renameRecordID: UUID?
    @State private var renameDraft = ""
    @State private var pendingTrashRecordIDs: [UUID] = []
    @State private var pendingUninstallRecordID: UUID?
    @State private var verticalGridTileFrames: [UUID: [CGRect]] = [:]
    @State private var searchGridTileFrames: [UUID: [CGRect]] = [:]

    init(viewModel: LauncherViewModel, settings: SettingsStore, pointerRouter: LauncherPointerRouter) {
        self.viewModel = viewModel
        self.settings = settings
        self.pointerRouter = pointerRouter
    }

    var body: some View {
        GeometryReader { viewport in
            ZStack {
                LauncherBackgroundView(
                    colorScheme: colorScheme,
                    isFullScreen: settings.presentationMode == .fullScreen,
                    glowPulse: glassGlowPulse
                )
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { handleBackgroundTap() }
                launcherCanvas
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .overlay {
                if settings.presentationMode == .window {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(glassGlowPulse ? 0.19 : 0.07), lineWidth: 1)
                        .blur(radius: glassGlowPulse ? 5 : 2)
                        .padding(1)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlayPreferenceValue(FolderSourceAnchorKey.self) { anchors in
            GeometryReader { proxy in
                folderPresentation(anchors: anchors, proxy: proxy)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .background(
            TrackpadGestureMonitor(
                gridMode: settings.gridMode,
                reversesPageDirection: settings.reversePageDirection,
                handleGesture: viewModel.handleTrackpadGesture,
                onOptionStateChanged: viewModel.setOptionUninstallMode,
                handleKeyDown: viewModel.handleKeyDown
            )
            .frame(width: 0, height: 0)
        )
        .onChange(of: viewModel.shouldFocusSearch) { _, shouldFocus in
            if shouldFocus {
                searchFocused = true
                viewModel.shouldFocusSearch = false
            }
        }
        .onChange(of: viewModel.searchQuery) { _, _ in
            pointerRouter.gridFrame = .zero
            pointerRouter.tileFrames = []
        }
        .onChange(of: settings.gridMode) { _, _ in
            pointerRouter.gridFrame = .zero
            pointerRouter.tileFrames = []
        }
        .onKeyPress(.escape) {
            viewModel.handleEscapeKey()
            return .handled
        }
        .task {
            guard !reduceMotion else { return }
            glassGlowPulse = true
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 5).repeatForever(autoreverses: true),
            value: glassGlowPulse
        )
        .alert(String(localized: "LaunchpadX Error"), isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) { viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? "") }
        .alert(String(localized: "Rename Application"), isPresented: Binding(
            get: { renameRecordID != nil },
            set: { if !$0 { renameRecordID = nil } }
        )) {
            TextField(String(localized: "Application name"), text: $renameDraft)
            Button(String(localized: "Cancel"), role: .cancel) { renameRecordID = nil }
            Button(String(localized: "Save")) {
                if let renameRecordID { viewModel.renameApplication(recordID: renameRecordID, to: renameDraft) }
                self.renameRecordID = nil
            }
        }
        .confirmationDialog(
            activeConfirmationTitle,
            isPresented: Binding(
                get: { pendingUninstallRecordID != nil || !pendingTrashRecordIDs.isEmpty },
                set: { if !$0 { pendingUninstallRecordID = nil; pendingTrashRecordIDs = [] } }
            ),
            titleVisibility: .visible
        ) {
            if pendingUninstallRecordID != nil {
                Button(String(localized: "Permanently Delete App"), role: .destructive) {
                    performPermanentUninstall(includingData: false)
                }
                if !pendingUninstallDataURLs.isEmpty {
                    Button(String(localized: "Permanently Delete App and Matching Data"), role: .destructive) {
                        performPermanentUninstall(includingData: true)
                    }
                }
            } else {
                Button(String(localized: "Move to Trash"), role: .destructive) {
                    let recordIDs = pendingTrashRecordIDs
                    pendingTrashRecordIDs = []
                    moveToTrash(recordIDs)
                }
                .accessibilityIdentifier("trash.confirm")
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingUninstallRecordID = nil
                pendingTrashRecordIDs = []
            }
            .accessibilityIdentifier(pendingUninstallRecordID != nil ? "uninstall.cancel" : "trash.cancel")
        } message: {
            Text(pendingUninstallRecordID != nil
                ? pendingUninstallMessage
                : String(localized: "These applications will be moved to the macOS Trash and can be restored from there. Application support data is left in place."))
        }
        .accessibilityIdentifier("launcher.root")
        .accessibilityValue(viewModel.isEditing ? "editing" : "normal")
        .accessibilityHint("\(settings.presentationMode == .window ? "window" : "full-screen"), \(settings.gridMode == .verticalScroll ? "vertical-scroll" : "pages")")
    }

    // Scope the presentation transaction to the overlay, not the application grid.
    private func folderPresentation(anchors: [UUID: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
        ZStack {
            if let folder = viewModel.openedFolder {
                let source = anchors[folder.id].map { proxy[$0] }
                let origin = source.map { CGPoint(x: $0.midX, y: $0.minY + settings.iconSize / 2) }
                    ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { handleBackgroundTap() })
                    .onDrop(of: [UTType.plainText], delegate: FolderOutsideDropDelegate(viewModel: viewModel))
                    .transition(.opacity)
                    .zIndex(0)
                FolderOverlayView(viewModel: viewModel, folder: folder, availableSize: proxy.size) { recordID in
                    requestPermanentUninstall(recordID)
                }
                    .onAppear { pointerRouter.folderFrame = folderPanelFrame(in: proxy.size) }
                    .onChange(of: viewModel.openedFolderApplications.count) { _, _ in
                        pointerRouter.folderFrame = folderPanelFrame(in: proxy.size)
                    }
                    .onChange(of: proxy.size) { _, newSize in
                        pointerRouter.folderFrame = folderPanelFrame(in: newSize)
                    }
                    .onDisappear { pointerRouter.folderFrame = nil }
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.16)
                        .combined(with: .offset(x: origin.x - proxy.size.width / 2,
                                                y: origin.y - proxy.size.height / 2))
                        .combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .contentShape(Rectangle())
        .animation(
            reduceMotion ? .linear(duration: 0.12) : .smooth(duration: 0.34, extraBounce: 0),
            value: viewModel.openedFolderID
        )
        .allowsHitTesting(viewModel.openedFolderID != nil)
    }

    private func folderPanelFrame(in availableSize: CGSize) -> CGRect {
        let width = min(800, max(280, availableSize.width - 32))
        let columns = max(2, min(5, Int((width - 48 + 18) / (112 + 18))))
        let rows = (viewModel.openedFolderApplications.count + columns - 1) / columns
        let height = min(650, availableSize.height - 32, max(240, CGFloat(rows) * 132 + 108))
        return CGRect(x: (availableSize.width - width) / 2,
                      y: (availableSize.height - height) / 2,
                      width: width, height: height)
    }

    private var launcherCanvas: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.top, settings.presentationMode == .window ? 4 : 52)
                .accessibilityIdentifier("launcher.search")
            if viewModel.isMultiSelecting {
                selectionControls
            }
            if !viewModel.searchQuery.isEmpty {
                searchGrid
                    .frame(maxHeight: .infinity)
            } else if settings.gridMode == .verticalScroll {
                verticalScrollGrid
                    .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 24)
                PagedLauncherGrid(
                    viewModel: viewModel,
                    settings: settings,
                    pointerRouter: pointerRouter,
                    onBackgroundTap: handleBackgroundTap,
                    entryView: entryView
                )
                Spacer(minLength: 20)
            }
            if viewModel.searchQuery.isEmpty, settings.gridMode == .pages, viewModel.pageCount > 1 {
                pageControl.padding(.bottom, 36)
            } else {
                Color.clear.frame(height: 44)
            }
        }
        .padding(.horizontal, 42)
        .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
    }

    @ViewBuilder
    private var selectionControls: some View {
        HStack(spacing: 12) {
            if viewModel.isMultiSelecting {
                Spacer()
                Text("已选择 \(viewModel.selectedApplicationRecordIDs.count) 个应用")
                    .foregroundStyle(.white.opacity(0.8))
                Button("全选") { viewModel.selectAllApplications() }
                Button("隐藏") { viewModel.hideSelectedApplications() }
                    .disabled(viewModel.selectedApplicationRecordIDs.isEmpty)
                Button("Move to Trash") { requestTrash(viewModel.selectedApplicationRecordIDs) }
                    .disabled(viewModel.selectedApplicationRecordIDs.isEmpty)
                Button("完成") { viewModel.toggleMultiSelecting() }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(.bordered)
        .padding(.top, 8)
        .accessibilityIdentifier("launcher.selectionControls")
    }

    private var verticalScrollGrid: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 24
            let columns = Self.responsiveColumnCount(
                availableWidth: min(geometry.size.width, 1_280),
                iconSize: settings.iconSize,
                requested: settings.columns,
                spacing: spacing
            )
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(minimum: settings.iconSize + 40, maximum: 156), spacing: spacing), count: columns),
                    spacing: spacing
                ) {
                    ForEach(viewModel.allRootEntries) { entry in
                        entryView(entry, isActivePage: true)
                    }
                }
                .frame(maxWidth: 1_280)
                .padding(.top, 28)
                .padding(.bottom, 32)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("launcher.verticalGrid.content")
            }
            .scrollIndicators(.hidden)
            .onPreferenceChange(LauncherTileFramePreferenceKey.self) { frames in
                verticalGridTileFrames = frames
                if viewModel.searchQuery.isEmpty, settings.gridMode == .verticalScroll {
                    pointerRouter.tileFrames = frames.values.flatMap { $0 }
                }
            }
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
                    guard !viewModel.isDraggingSession,
                          !verticalGridTileFrames.values.joined().contains(where: { $0.contains(tap.location) }) else { return }
                    handleBackgroundTap()
                }
            )
            .frame(width: min(geometry.size.width, 1_360), height: geometry.size.height)
            .frame(maxWidth: .infinity, alignment: .center)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                if viewModel.searchQuery.isEmpty, settings.gridMode == .verticalScroll {
                    pointerRouter.gridFrame = frame
                }
            }
        }
        .frame(maxWidth: 1_360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launcher.verticalGrid")
    }

    private var searchField: some View {
        GeometryReader { geometry in
        let isFullScreen = settings.presentationMode == .fullScreen
        let fieldHeight: CGFloat = isFullScreen ? 50 : 44
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: isFullScreen ? 17 : 15, weight: .medium))
                .foregroundStyle(colorScheme == .dark ? .white.opacity(0.72) : .primary.opacity(0.68))
            TextField(String(localized: "Search applications"), text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: isFullScreen ? 18 : 16))
                .focused($searchFocused)
                .onSubmit { viewModel.launchSelectedSearchResult() }
                .onKeyPress(.downArrow) { viewModel.moveSearchSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { viewModel.moveSearchSelection(by: -1); return .handled }
            if !viewModel.searchQuery.isEmpty {
                Button { viewModel.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(colorScheme == .dark ? .white.opacity(0.58) : .primary.opacity(0.48))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, isFullScreen ? 17 : 14)
        .frame(width: min(isFullScreen ? 620 : 540, geometry.size.width), height: fieldHeight)
        .background(colorScheme == .dark ? .black.opacity(0.24) : .white.opacity(0.46), in: Capsule())
        .overlay(Capsule().stroke(colorScheme == .dark ? .white.opacity(0.24) : .black.opacity(0.14), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: settings.presentationMode == .fullScreen ? 50 : 44)
    }

    private var searchGrid: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 24
            let columns = Self.responsiveColumnCount(
                availableWidth: min(geometry.size.width, 1_280),
                iconSize: settings.iconSize,
                requested: settings.columns,
                spacing: spacing
            )
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(minimum: settings.iconSize + 40, maximum: 156), spacing: spacing), count: columns),
                    spacing: spacing
                ) {
                    ForEach(Array(viewModel.searchResults.prefix(9).enumerated()), id: \.element.id) { index, result in
                        SearchResultTile(
                            result: result,
                            title: viewModel.snapshot.applicationAliases[result.recordID] ?? result.application.displayName,
                            image: viewModel.icon(for: result.application),
                            iconSize: settings.iconSize,
                            selected: index == viewModel.selectedSearchIndex
                        ) {
                            viewModel.launch(result: result)
                        }
                    }
                }
                .frame(maxWidth: 1_280)
                .padding(.vertical, 24)
            }
            .onPreferenceChange(LauncherTileFramePreferenceKey.self) { frames in
                searchGridTileFrames = frames
                if !viewModel.searchQuery.isEmpty {
                    pointerRouter.tileFrames = frames.values.flatMap { $0 }
                }
            }
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
                    guard !viewModel.isDraggingSession,
                          !searchGridTileFrames.values.joined().contains(where: { $0.contains(tap.location) }) else { return }
                    handleBackgroundTap()
                }
            )
            .frame(width: min(geometry.size.width, 1_360), height: geometry.size.height)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                if !viewModel.searchQuery.isEmpty { pointerRouter.gridFrame = frame }
            }
        }
        .transition(.opacity)
    }

    nonisolated static func responsiveColumnCount(
        availableWidth: CGFloat,
        iconSize: Double,
        requested: Int,
        spacing: CGFloat = 24
    ) -> Int {
        let tileWidth = CGFloat(iconSize + 40)
        let fitting = Int(max(0, availableWidth + spacing) / (tileWidth + spacing))
        return max(1, min(requested, fitting))
    }

    @ViewBuilder
    private func entryView(_ entry: LauncherEntry, isActivePage: Bool) -> some View {
        let isDraggedEntry = viewModel.isDragging(entry)
        let tile = AppTile(
            entry: entry,
            image: entry.application.map(viewModel.icon(for:)),
            folderImages: entry.childApplicationRecordIDs.prefix(9).compactMap { viewModel.snapshot.applications[$0].map(viewModel.icon(for:)) },
            groupingImages: viewModel.groupingPreviewImages(for: entry),
            showsGroupingPreview: viewModel.groupingTargetID == entry.id,
            dragProvider: { viewModel.applicationDragProvider(recordID: entry.applicationRecordID, entryID: entry.id) },
            iconSize: settings.iconSize,
            selected: entry.applicationRecordID.map(viewModel.selectedApplicationRecordIDs.contains) ?? false,
            editing: viewModel.isEditing && isActivePage,
            showsUninstallControl: viewModel.isOptionUninstallMode
                && entry.application?.canMoveToTrash == true
                && entry.applicationRecordID != nil,
            onUninstall: {
                if let recordID = entry.applicationRecordID { requestPermanentUninstall(recordID) }
            },
            onDragBegan: {
                if !viewModel.isEditing { viewModel.beginEditing() }
                viewModel.beginDraggingFromPress(entry)
            },
        ) {
            if entry.kind == .folder { viewModel.open(entry) }
            else if viewModel.isMultiSelecting { viewModel.toggleSelection(for: entry) }
            else { viewModel.open(entry) }
        } onLongPress: {
            viewModel.beginEditing()
        }
        .opacity(isDraggedEntry ? 0.28 : 1)
        .contextMenu { contextMenu(for: entry) }
        tile
            .anchorPreference(key: FolderSourceAnchorKey.self, value: .bounds) { anchor in
                entry.kind == .folder && isActivePage ? [entry.id: anchor] : [:]
            }
            .onDrop(
                of: [UTType.plainText],
                delegate: LauncherEntryDropDelegate(
                    entry: entry,
                    iconSize: settings.iconSize,
                    viewModel: viewModel
                )
            )
    }

    @ViewBuilder private func contextMenu(for entry: LauncherEntry) -> some View {
        if entry.kind == .application {
            Button(String(localized: "Rename Application")) { beginRename(entry) }
            Button(String(localized: "Hide Application")) { viewModel.hide(entry: entry) }
            Button(String(localized: "Show in Finder")) { viewModel.reveal(entry: entry) }
            Divider()
            Button(String(localized: "Move to Trash"), role: .destructive) {
                if let recordID = entry.applicationRecordID { requestTrash([recordID]) }
            }
        } else if viewModel.isEditing {
            Button(String(localized: "Rename Folder")) {
                viewModel.beginRenamingFolder(entry)
            }
        }
    }

    private func beginRename(_ entry: LauncherEntry) {
        guard let recordID = entry.applicationRecordID else { return }
        renameDraft = entry.customName ?? entry.application?.displayName ?? ""
        renameRecordID = recordID
    }

    private func requestTrash<S: Sequence>(_ recordIDs: S) where S.Element == UUID {
        let requestedIDs = Array(Set(recordIDs))
        let validIDs = requestedIDs.filter {
            viewModel.application(for: $0)?.canMoveToTrash == true
        }
        guard !validIDs.isEmpty else {
            if !requestedIDs.isEmpty {
                viewModel.presentError(NSError(
                    domain: "LaunchpadX.Trash",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "System applications cannot be moved to Trash.")]
                ))
            }
            return
        }
        pendingTrashRecordIDs = validIDs
    }

    private var pendingUninstallApplication: InstalledApplication? {
        pendingUninstallRecordID.flatMap(viewModel.application(for:))
    }

    private var pendingUninstallTitle: String {
        guard let app = pendingUninstallApplication else { return String(localized: "Permanently Uninstall Application?") }
        return String(localized: "Permanently Uninstall \(app.displayName)?")
    }

    private var activeConfirmationTitle: String {
        pendingUninstallRecordID != nil
            ? pendingUninstallTitle
            : String(localized: "Move selected applications to Trash?")
    }

    private var pendingUninstallDataURLs: [URL] {
        guard let bundleID = pendingUninstallApplication?.bundleIdentifier else { return [] }
        return PermanentUninstaller.matchingDataURLs(bundleIdentifier: bundleID)
    }

    private var pendingUninstallMessage: String {
        let paths = pendingUninstallDataURLs.map(\.path)
        guard !paths.isEmpty else {
            return String(localized: "The selected action permanently deletes the application. No matching data was found in your Library.")
        }
        return String(localized: "Choose whether to permanently delete only the app or also these exact matching data items:\n\n\(paths.joined(separator: "\n"))")
    }

    private func requestPermanentUninstall(_ recordID: UUID) {
        guard let application = viewModel.application(for: recordID), application.canMoveToTrash else { return }
        pendingUninstallRecordID = recordID
    }

    private func performPermanentUninstall(includingData: Bool) {
        guard let recordID = pendingUninstallRecordID,
              let application = viewModel.application(for: recordID) else {
            pendingUninstallRecordID = nil
            return
        }
        pendingUninstallRecordID = nil
        do {
            try PermanentUninstaller.uninstall(application, includingMatchingData: includingData)
            viewModel.removeApplication(recordID: recordID)
        } catch {
            viewModel.presentError(error)
        }
    }

    private func moveToTrash(_ recordIDs: [UUID]) {
        let applications = recordIDs.compactMap { recordID in
            viewModel.application(for: recordID).map { (recordID, $0) }
        }
        guard !applications.isEmpty else { return }
        NSWorkspace.shared.recycle(applications.map { $0.1.bundleURL }) { movedURLs, error in
            DispatchQueue.main.async {
                let movedPaths = Set(movedURLs.keys.map { $0.standardizedFileURL.path })
                let movedIDs = applications.compactMap { recordID, app in
                    movedPaths.contains(app.bundleURL.standardizedFileURL.path) ? recordID : nil
                }
                movedIDs.forEach(viewModel.removeApplication(recordID:))
                if let error { viewModel.presentError(error) }
                else if movedIDs.count < applications.count {
                    viewModel.presentError(NSError(
                        domain: "LaunchpadX.Trash",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: String(localized: "Some applications could not be moved to Trash.")]
                    ))
                }
            }
        }
    }

    private func handleBackgroundTap() {
        if viewModel.openedFolderID != nil {
            if viewModel.isEditing { viewModel.endEditing() }
            viewModel.closeFolder()
            return
        }
        guard !viewModel.isDraggingSession else { return }
        if viewModel.isEditing {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                viewModel.endEditing()
            }
        }
        viewModel.onDismiss?()
    }

    private var pageControl: some View {
        HStack(spacing: 8) {
            ForEach(0..<viewModel.pageCount, id: \.self) { page in
                Circle()
                    .fill(page == viewModel.selectedPage ? .white.opacity(0.95) : .white.opacity(0.42))
                    .frame(width: page == viewModel.selectedPage ? 7 : 6, height: page == viewModel.selectedPage ? 7 : 6)
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.selectedPage = page }
            }
        }
        .shadow(color: .black.opacity(0.38), radius: 3, y: 1)
    }
}

private struct FolderSourceAnchorKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PagedLauncherGrid<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var viewModel: LauncherViewModel
    @Bindable var settings: SettingsStore
    let pointerRouter: LauncherPointerRouter
    let onBackgroundTap: () -> Void
    let entryView: (LauncherEntry, Bool) -> Content
    @State private var stableEntryFrames: [UUID: CGRect] = [:]
    @State private var stableTileFrames: [UUID: [CGRect]] = [:]
    @State private var retainedPage: Int?
    @State private var pageReleaseTask: Task<Void, Never>?
    @State private var isPageTransitioning = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                HStack(spacing: 0) {
                    ForEach(0..<viewModel.pageCount, id: \.self) { page in
                        Group {
                            if shouldRender(page: page) {
                                pageGrid(
                                    entries: viewModel.entries(forPage: page),
                                    isActivePage: page == viewModel.selectedPage
                                )
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .allowsHitTesting(page == viewModel.selectedPage)
                        .accessibilityHidden(page != viewModel.selectedPage)
                    }
                }
                .offset(x: -CGFloat(viewModel.selectedPage) * proxy.size.width)
                .animation(reduceMotion ? nil : .smooth(duration: 0.28, extraBounce: 0), value: viewModel.selectedPage)
            }
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
                    guard !isPageTransitioning else { return }
                    guard !stableTileFrames.values.joined().contains(where: {
                        $0.contains(tap.location)
                    }) else { return }
                    onBackgroundTap()
                }
            )
        }
        .clipped()
        .coordinateSpace(name: LauncherGridCoordinateSpace.name)
        .onPreferenceChange(LauncherEntryFramePreferenceKey.self) { frames in
            guard !isPageTransitioning, !viewModel.isDraggingSession, !frames.isEmpty, frames != stableEntryFrames else { return }
            stableEntryFrames = frames
            viewModel.rootEntryFrames = frames
        }
        .onPreferenceChange(LauncherTileFramePreferenceKey.self) { frames in
            stableTileFrames = frames
            if viewModel.searchQuery.isEmpty, settings.gridMode == .pages {
                pointerRouter.tileFrames = frames.values.flatMap { $0 }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            viewModel.rootGridFrame = frame
            if viewModel.searchQuery.isEmpty, settings.gridMode == .pages {
                pointerRouter.gridFrame = frame
            }
        }
        .onAppear {
            retainedPage = viewModel.selectedPage
        }
        .onChange(of: viewModel.selectedPage) { oldPage, newPage in
            isPageTransitioning = true
            retainedPage = oldPage
            pageReleaseTask?.cancel()
            pageReleaseTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, viewModel.selectedPage == newPage else { return }
                retainedPage = newPage
                isPageTransitioning = false
            }
        }
        .onDisappear {
            pageReleaseTask?.cancel()
            isPageTransitioning = false
        }
        .onDrop(
            of: [UTType.plainText],
            delegate: LauncherGridBackgroundDropDelegate(
                viewModel: viewModel,
                stableEntryFrames: stableEntryFrames
            )
        )
    }

    private func shouldRender(page: Int) -> Bool {
        page == viewModel.selectedPage
            || abs(page - (retainedPage ?? viewModel.selectedPage)) <= 1
            || page == retainedPage
            || (viewModel.isDraggingSession && abs(page - viewModel.selectedPage) <= 1)
    }

    private func pageGrid(entries: [LauncherEntry], isActivePage: Bool) -> some View {
        VStack {
            Spacer(minLength: 0)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 102, maximum: 156), spacing: 30), count: settings.columns),
                spacing: 30
            ) {
                ForEach(entries) { entry in
                    entryView(entry, isActivePage)
                        .background {
                            if isActivePage, !isPageTransitioning, !viewModel.isDraggingSession {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: LauncherEntryFramePreferenceKey.self,
                                        value: [
                                            entry.id: proxy.frame(
                                                in: .named(LauncherGridCoordinateSpace.name)
                                            )
                                        ]
                                    )
                                }
                            }
                        }
                }
            }
            .animation(
                viewModel.isEditing && isActivePage && !isPageTransitioning
                    ? LaunchpadTheme.gridSpring
                    : nil,
                value: entries.map(\.id)
            )
            .frame(maxWidth: 1_280)
            .padding(.horizontal, 28)
            Spacer(minLength: 0)
        }
    }
}

private enum LauncherGridCoordinateSpace {
    static let name = "launcher.grid"
}

private struct LauncherEntryFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct LauncherTileFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: [CGRect]] = [:]

    static func reduce(value: inout [UUID: [CGRect]], nextValue: () -> [UUID: [CGRect]]) {
        for (id, rects) in nextValue() {
            value[id, default: []].append(contentsOf: rects)
        }
    }
}

private struct AppTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: LauncherEntry
    let image: NSImage?
    let folderImages: [NSImage]
    let groupingImages: [NSImage]
    let showsGroupingPreview: Bool
    let dragProvider: () -> NSItemProvider
    let iconSize: Double
    let selected: Bool
    let editing: Bool
    let showsUninstallControl: Bool
    let onUninstall: () -> Void
    let onDragBegan: () -> Void
    let action: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        tileContent
        .accessibilityElement(children: .contain)
        .fixedSize()
        .rotationEffect(.degrees(editing ? wiggleAngle : 0))
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: showsGroupingPreview)
        .accessibilityLabel(entry.title)
        .accessibilityIdentifier("launcher.tile")
        .accessibilityValue(selected ? "selected" : (editing ? "editing" : "normal"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) {
            action()
        }
    }

    private var tileContent: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topLeading) {
                interactive(ZStack {
                    if entry.kind == .folder {
                        FolderPreview(images: folderImages, size: iconSize)
                    } else {
                        Image(nsImage: image ?? NSImage())
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    }

                    if showsGroupingPreview {
                        FolderPreview(images: groupingImages, size: iconSize)
                            .transition(.scale(scale: 0.82).combined(with: .opacity))
                    }
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(3)
                    }
                }
                .frame(width: iconSize, height: iconSize))
                .accessibilityIdentifier("launcher.icon.\(entry.id.uuidString)")
                .compositingGroup()
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: LauncherTileFramePreferenceKey.self,
                            value: [entry.id: [proxy.frame(in: .global)]]
                        )
                    }
                }
                if showsUninstallControl, let recordID = entry.applicationRecordID {
                    Button(action: onUninstall) {
                        Image(systemName: "minus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(colorScheme == .dark ? .white : .black.opacity(0.78))
                            .frame(width: 28, height: 28)
                            .glassEffect(
                                .regular.tint(colorScheme == .dark ? .white.opacity(0.28) : .white.opacity(0.66)),
                                in: Circle()
                            )
                            .overlay(Circle().stroke(.white.opacity(colorScheme == .dark ? 0.48 : 0.82), lineWidth: 0.8))
                            .shadow(color: .black.opacity(0.22), radius: 4, y: 1)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: -10, y: -10)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: LauncherTileFramePreferenceKey.self,
                                value: [recordID: [proxy.frame(in: .global)]]
                            )
                        }
                    }
                    .accessibilityLabel(String(localized: "Permanently Uninstall"))
                    .accessibilityValue(entry.title)
                    .accessibilityIdentifier("uninstall.\(entry.id.uuidString)")
                    .zIndex(10)
                }
            }
            .frame(width: iconSize, height: iconSize)
            interactive(Text(entry.title)
                .font(.system(size: 12, weight: .regular))
                .lineLimit(1)
                .shadow(color: colorScheme == .dark ? .black.opacity(0.85) : .clear, radius: 2, y: 1)
                .frame(width: visibleTitleWidth)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: LauncherTileFramePreferenceKey.self,
                            value: [entry.id: [proxy.frame(in: .global)]]
                        )
                    }
                })
        }
        .scaleEffect(showsGroupingPreview ? 1.10 : 1)
    }

    private var visibleTitleWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        let measuredWidth = (entry.title as NSString).size(withAttributes: [.font: font]).width
        return min(CGFloat(iconSize + 40), max(1, ceil(measuredWidth)))
    }

    @ViewBuilder
    private func interactive<Content: View>(_ content: Content) -> some View {
        let dragSource = Button(action: action) {
            content.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag {
                onDragBegan()
                return dragProvider()
            } preview: {
                Image(nsImage: image ?? folderImages.first ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
            }
        if editing {
            dragSource
        } else {
            dragSource.onLongPressGesture(minimumDuration: LaunchpadTheme.editingLongPressDuration) {
                onLongPress()
            }
        }
    }

    private var wiggleSeed: Int {
        entry.id.uuidString.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fff }
    }

    private var wiggleAngle: Double {
        0.72 + Double(wiggleSeed % 7) * 0.075
    }

}

private struct SearchResultTile: View {
    let result: SearchResult
    let title: String
    let image: NSImage
    let iconSize: Double
    let selected: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Image(nsImage: image)
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: LauncherTileFramePreferenceKey.self,
                            value: [result.recordID: [proxy.frame(in: .global)]]
                        )
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: action)

            Text(title)
                .font(.system(size: 12, weight: .regular))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                .frame(width: visibleTitleWidth)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: LauncherTileFramePreferenceKey.self,
                            value: [result.recordID: [proxy.frame(in: .global)]]
                        )
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
        }
        .background(selected ? .white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier("launcher.searchResult")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    }

    private var visibleTitleWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        let measuredWidth = (title as NSString).size(withAttributes: [.font: font]).width
        return min(CGFloat(iconSize + 40), max(1, ceil(measuredWidth)))
    }
}

private struct FolderPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let images: [NSImage]
    let size: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.20, style: .continuous)
                .fill(colorScheme == .dark ? .white.opacity(0.11) : .white.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.20, style: .continuous)
                        .stroke(colorScheme == .dark ? .white.opacity(0.24) : .black.opacity(0.12), lineWidth: 0.7)
                }
                .shadow(color: colorScheme == .dark ? .black.opacity(0.18) : .black.opacity(0.10), radius: 2, y: 1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(Array(images.prefix(9).enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image).resizable().scaledToFit()
                }
            }
            .padding(size * 0.12)
        }
        .frame(width: size, height: size)
    }
}

struct LauncherEntryDropDelegate: DropDelegate {
    let entry: LauncherEntry
    let iconSize: Double
    let viewModel: LauncherViewModel

    func dropEntered(info: DropInfo) {
        updateGroupingState(for: info)
    }

    func dropExited(info: DropInfo) {
        viewModel.dragExited(target: entry)
    }

    func performDrop(info: DropInfo) -> Bool {
        return viewModel.performDrop(
            on: entry,
            grouping: Self.isGroupingLocation(info.location, iconSize: iconSize, tileWidth: tileWidth)
        )
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateGroupingState(for: info)
        return DropProposal(operation: .move)
    }

    nonisolated static func isGroupingLocation(
        _ location: CGPoint, iconSize: Double, tileWidth: CGFloat
    ) -> Bool {
        let iconCenter = CGPoint(x: tileWidth / 2, y: iconSize / 2)
        let radius = iconSize * 0.38
        return hypot(location.x - iconCenter.x, location.y - iconCenter.y) <= radius
    }

    private var tileWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        let labelWidth = ceil((entry.title as NSString).size(withAttributes: [.font: font]).width)
        return max(CGFloat(iconSize), min(CGFloat(iconSize + 40), labelWidth))
    }

    private func updateGroupingState(for info: DropInfo) {
        viewModel.dragMoved(
            over: entry,
            grouping: Self.isGroupingLocation(info.location, iconSize: iconSize, tileWidth: tileWidth)
        )
    }
}

private struct LauncherGridBackgroundDropDelegate: DropDelegate {
    let viewModel: LauncherViewModel
    let stableEntryFrames: [UUID: CGRect]

    func performDrop(info: DropInfo) -> Bool {
        if let targetID = nearestEntryID(to: info.location),
           let target = viewModel.snapshot.entries.first(where: { $0.id == targetID }) {
            viewModel.moveDraggedEntry(toOriginalSlotOf: target.id)
            return viewModel.performDrop(on: target)
        }
        return viewModel.performBackgroundDrop()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    private func nearestEntryID(to location: CGPoint) -> UUID? {
        stableEntryFrames.min { lhs, rhs in
            Self.distanceSquared(from: location, to: lhs.value)
                < Self.distanceSquared(from: location, to: rhs.value)
        }?.key
    }

    private static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        return dx * dx + dy * dy
    }
}

private struct LauncherBackgroundView: View {
    let colorScheme: ColorScheme
    let isFullScreen: Bool
    let glowPulse: Bool

    var body: some View {
        Rectangle()
            .fill(.clear)
            .glassEffect(.regular.tint(colorScheme == .dark ? .white.opacity(0.12) : .white.opacity(0.19)), in: Rectangle())
            .overlay {
                Rectangle().fill(
                    LinearGradient(
                        colors: [.white.opacity(colorScheme == .dark ? 0.08 : 0.12), .clear, .white.opacity(0.025)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                if isFullScreen {
                    Rectangle().fill(
                        RadialGradient(
                            colors: [
                                .white.opacity(glowPulse ? 0.075 : 0.025),
                                Color.cyan.opacity(glowPulse ? 0.025 : 0.008),
                                .clear
                            ],
                            center: .topLeading,
                            startRadius: 8,
                            endRadius: 720
                        )
                    )
                }
            }
            .ignoresSafeArea()
    }
}
