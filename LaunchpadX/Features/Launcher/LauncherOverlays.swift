import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SearchResultsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var viewModel: LauncherViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Search Results").font(.headline)
                Spacer()
                Text("\(viewModel.searchResults.count) / 9")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(22)

            Divider().overlay(.white.opacity(0.15))
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(viewModel.searchResults.enumerated()), id: \.element.id) { index, result in
                        Button { viewModel.launch(result: result) } label: {
                            HStack(spacing: 14) {
                                Image(nsImage: viewModel.icon(for: result.application))
                                    .resizable().scaledToFit().frame(width: 42, height: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.application.displayName).fontWeight(.medium)
                                    Text(result.application.bundleIdentifier ?? result.application.bundleURL.path)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("⌘\(index + 1)").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(index == viewModel.selectedSearchIndex ? LaunchpadTheme.accent.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 410)
            HStack {
                Text("↑↓ Select")
                Text("↩ Open")
                Text("Esc Close")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 22).padding(.vertical, 15)
        }
        .frame(width: 780, height: 570)
        .background((colorScheme == .dark ? Color.black.opacity(0.32) : Color.white.opacity(0.56)), in: RoundedRectangle(cornerRadius: 28))
        .glassEffect(.regular.tint(colorScheme == .dark ? .white.opacity(0.12) : .white.opacity(0.38)), in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.45), radius: 40, y: 16)
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard press.modifiers.contains(.command), let index = Int(press.characters), index > 0,
                  viewModel.searchResults.indices.contains(index - 1) else { return .ignored }
            viewModel.launch(result: viewModel.searchResults[index - 1])
            return .handled
        }
    }
}

struct FolderOverlayView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Bindable var viewModel: LauncherViewModel
    let folder: LauncherEntry
    let requestTrash: (UUID) -> Void
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
                if viewModel.renamingFolderID == folder.id {
                    TextField(String(localized: "Folder name"), text: $draftName)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background((colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08)), in: Capsule())
                        .frame(width: 260)
                        .focused($nameFocused)
                        .onSubmit { viewModel.saveFolderName(draftName) }
                        .onKeyPress(.escape) { viewModel.renamingFolderID = nil; return .handled }
                        .accessibilityIdentifier("folder.name.editor")
                } else {
                    Text(folder.title)
                        .font(.system(size: 20, weight: .regular))
                        .shadow(color: colorScheme == .dark ? .black.opacity(0.7) : .clear, radius: 2, y: 1)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            viewModel.beginRenamingFolder(folder)
                        }
                        .accessibilityIdentifier("folder.name.label")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(112), spacing: 30), count: 5), spacing: 30) {
                    ForEach(viewModel.openedFolderApplications, id: \.0) { recordID, app in
                        folderApplication(recordID: recordID, application: app)
                    }
                }
                .animation(LaunchpadTheme.gridSpring, value: viewModel.openedFolderApplications.map(\.0))
                .padding(.bottom, 6)
        }
        .padding(.horizontal, 54).padding(.vertical, 40)
        .frame(minWidth: 660, maxWidth: 800, minHeight: 360)
        .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(colorScheme == .dark
                    ? Color(white: 0.10).opacity(reduceTransparency ? 0.98 : 0.34)
                    : Color(white: 0.98).opacity(reduceTransparency ? 1 : 0.38))
                .glassEffect(.regular.tint(colorScheme == .dark ? .white.opacity(0.06) : .white.opacity(0.14)), in: RoundedRectangle(cornerRadius: 26))
                .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? .white.opacity(contrast == .increased ? 0.65 : 0.24)
                        : .black.opacity(contrast == .increased ? 0.42 : 0.14),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .onDrop(
            of: [UTType.plainText],
            delegate: FolderGridBackgroundDropDelegate(viewModel: viewModel)
        )
        .onAppear {
            draftName = folder.title
            focusNameIfNeeded()
        }
        .onChange(of: viewModel.renamingFolderID) { _, _ in
            focusNameIfNeeded()
        }
    }

    private func focusNameIfNeeded() {
        guard viewModel.renamingFolderID == folder.id else { return }
        draftName = folder.title
        DispatchQueue.main.async { nameFocused = true }
    }

    @ViewBuilder
    private func folderApplication(
        recordID: UUID,
        application: InstalledApplication
    ) -> some View {
        let tile = FolderApplicationTile(
            title: viewModel.snapshot.applicationAliases[recordID] ?? application.displayName,
            image: viewModel.icon(for: application),
            editing: viewModel.isEditing,
            selected: viewModel.selectedApplicationRecordIDs.contains(recordID)
        )
        .opacity(viewModel.isDraggingFolderApplication(recordID: recordID) ? 0.28 : 1)
        .contextMenu {
            if viewModel.isEditing {
                Button(String(localized: "Remove from Folder")) {
                    viewModel.removeFromFolder(recordID: recordID)
                }
            }
            Button(String(localized: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([application.bundleURL])
            }
        }

        Group {
            if viewModel.isEditing {
                tile
                    .onDrag {
                        viewModel.folderDragProvider(recordID: recordID)
                    } preview: {
                        Image(nsImage: viewModel.icon(for: application))
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 82, height: 82)
                            .scaleEffect(1.06)
                            .shadow(color: .black.opacity(0.32), radius: 12, y: 7)
                    }
                    .onDrop(
                        of: [UTType.plainText],
                        delegate: FolderApplicationDropDelegate(
                            recordID: recordID,
                            viewModel: viewModel
                        )
                    )
            } else if viewModel.isOptionUninstallMode {
                tile
            } else if viewModel.isMultiSelecting {
                Button {
                    viewModel.toggleSelection(for: recordID)
                } label: {
                    tile
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.snapshot.applicationAliases[recordID] ?? application.displayName)
                .accessibilityIdentifier("folder.tile")
            } else {
                Button {
                    if !viewModel.isOptionUninstallMode {
                        viewModel.launch(application: application, recordID: recordID)
                    }
                } label: {
                    tile
                }
                .disabled(viewModel.isOptionUninstallMode)
                .buttonStyle(.plain)
                .accessibilityLabel(application.displayName)
                .accessibilityIdentifier("folder.tile")
            }
        }
        .overlay(alignment: .topLeading) {
            if viewModel.isOptionUninstallMode && application.canMoveToTrash {
                Button { requestTrash(recordID) } label: {
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
                .offset(x: 5, y: -10)
                .accessibilityLabel(String(localized: "Permanently Uninstall"))
                .accessibilityValue(application.displayName)
                .accessibilityIdentifier("folder.uninstall.\(recordID.uuidString)")
            }
        }
    }
}

private struct FolderApplicationTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let image: NSImage
    let editing: Bool
    let selected: Bool

    var body: some View {
        tileContent
            .rotationEffect(.degrees(editing ? 0.6 : 0))
        .contentShape(Rectangle())
        .accessibilityLabel(title)
        .accessibilityIdentifier("folder.tile")
    }

    private var tileContent: some View {
        VStack(spacing: 8) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 82, height: 82)
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    }
                }
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(width: 112)
                .shadow(color: colorScheme == .dark ? .black.opacity(0.75) : .clear, radius: 2, y: 1)
        }
    }
}

private struct FolderApplicationDropDelegate: DropDelegate {
    let recordID: UUID
    let viewModel: LauncherViewModel

    func dropEntered(info: DropInfo) {
        viewModel.folderDragMoved(over: recordID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        viewModel.folderDragMoved(over: recordID)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        viewModel.performFolderDrop(on: recordID)
    }
}

private struct FolderGridBackgroundDropDelegate: DropDelegate {
    let viewModel: LauncherViewModel

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        viewModel.performFolderBackgroundDrop()
    }
}

struct FolderOutsideDropDelegate: DropDelegate {
    let viewModel: LauncherViewModel

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        viewModel.performFolderDropOutside()
    }
}
