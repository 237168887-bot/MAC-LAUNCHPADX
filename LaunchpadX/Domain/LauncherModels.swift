import AppKit
import Carbon
import Foundation

struct InstalledApplication: Identifiable, Sendable, Hashable {
    let id: UUID
    let bundleIdentifier: String?
    let displayName: String
    let bundleURL: URL
    let version: String?
    let isSystemApplication: Bool

    nonisolated init(
        id: UUID = UUID(),
        bundleIdentifier: String?,
        displayName: String,
        bundleURL: URL,
        version: String? = nil,
        isSystemApplication: Bool = false
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundleURL = bundleURL
        self.version = version
        self.isSystemApplication = isSystemApplication
    }

    nonisolated var normalizedPath: String {
        bundleURL.standardizedFileURL.path.lowercased()
    }

    nonisolated var canMoveToTrash: Bool {
        !isSystemApplication && !(bundleIdentifier?.lowercased().hasPrefix("com.apple.") ?? false)
    }
}

enum LauncherEntryKind: String, Codable, Sendable {
    case application
    case folder
}

struct LauncherEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: LauncherEntryKind
    var applicationRecordID: UUID?
    var application: InstalledApplication?
    var folderName: String?
    var childApplicationRecordIDs: [UUID]
    var layoutIndex: Int = 0
    var customName: String? = nil

    var title: String {
        switch kind {
        case .application:
            customName?.nilIfEmpty ?? application?.displayName ?? "Missing Application"
        case .folder:
            folderName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Folder"
        }
    }
}

struct LauncherSnapshot: Sendable {
    var entries: [LauncherEntry]
    var applications: [UUID: InstalledApplication]
    var hiddenRecordIDs: Set<UUID>
    var applicationAliases: [UUID: String] = [:]
}

enum SearchSortOrder: String, CaseIterable, Codable, Identifiable {
    case relevance
    case recent
    case name

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .relevance: "相关度"
        case .recent: "最近使用"
        case .name: "名称"
        }
    }
}

enum DisplayStrategy: String, CaseIterable, Codable, Identifiable {
    case cursor
    case primary
    case lastUsed
    case fixed

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .cursor: "鼠标所在显示器"
        case .primary: "主显示器"
        case .lastUsed: "上次使用的显示器"
        case .fixed: "指定显示器"
        }
    }
}

enum LauncherPresentationMode: String, CaseIterable, Codable, Identifiable {
    case fullScreen
    case window

    var id: String { rawValue }
    var localizedTitle: String {
        switch self {
        case .fullScreen: "全屏"
        case .window: "窗口"
        }
    }
}

enum LauncherGridMode: String, CaseIterable, Codable, Identifiable {
    case pages
    case verticalScroll

    var id: String { rawValue }
    var localizedTitle: String {
        switch self {
        case .pages: "分页"
        case .verticalScroll: "纵向滚动"
        }
    }
}

enum HotCornerLocation: String, CaseIterable, Codable, Identifiable {
    case off
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }
    var localizedTitle: String {
        switch self {
        case .off: "关闭"
        case .topLeft: "左上角"
        case .topRight: "右上角"
        case .bottomLeft: "左下角"
        case .bottomRight: "右下角"
        }
    }
}

struct HotKey: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultLauncher = HotKey(keyCode: 49, carbonModifiers: UInt32(optionKey))
    static let defaultPreviousPage = HotKey(keyCode: 123, carbonModifiers: 0)
    static let defaultNextPage = HotKey(keyCode: 124, carbonModifiers: 0)

    var displayString: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        return parts.joined() + keyName
    }

    private var keyName: String {
        switch keyCode {
        case 49: "空格"
        case 36: "回车"
        case 53: "Esc"
        case 123: "←"
        case 124: "→"
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 25: "9"
        case 26: "7"
        case 28: "8"
        case 29: "0"
        case 31: "O"
        case 32: "U"
        case 34: "I"
        case 35: "P"
        case 37: "L"
        case 38: "J"
        case 40: "K"
        case 45: "N"
        case 46: "M"
        default: "按键 \(keyCode)"
        }
    }

    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        self.keyCode == UInt32(keyCode) && carbonModifiers == Self.carbonModifiers(from: modifiers)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
