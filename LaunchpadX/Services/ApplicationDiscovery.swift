import AppKit
import CoreServices
import Foundation
import Observation

protocol ApplicationDiscovering: Sendable {
    func scan(roots: [URL]) async -> [InstalledApplication]
}

struct ApplicationDiscoveryService: ApplicationDiscovering {
    static var defaultRoots: [URL] {
        let manager = FileManager.default
        let paths = [
            "/Applications",
            "/System/Applications",
            "/System/Cryptexes/App/System/Applications",
            NSHomeDirectory() + "/Applications"
        ]
        return paths.map(URL.init(fileURLWithPath:)).filter { manager.fileExists(atPath: $0.path) }
    }

    nonisolated func scan(roots: [URL]) async -> [InstalledApplication] {
        await Task.detached(priority: .background) {
            Self.scanSynchronously(roots: roots)
        }.value
    }

    nonisolated private static func scanSynchronously(roots: [URL]) -> [InstalledApplication] {
        let manager = FileManager.default
        var result: [InstalledApplication] = []
        for root in roots {
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isExecutableKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
                guard let app = parseApplication(at: canonicalURL) else { continue }
                result.append(app)
            }
        }
        return deduplicated(result, currentApplicationURL: Bundle.main.bundleURL)
    }

    nonisolated static func deduplicated(
        _ applications: [InstalledApplication],
        currentApplicationURL: URL
    ) -> [InstalledApplication] {
        let currentPath = currentApplicationURL.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let homeApplications = (NSHomeDirectory() + "/Applications/").lowercased()
        func priority(_ app: InstalledApplication) -> (Int, Int, String) {
            let path = app.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
            let location: Int
            if path == currentPath { location = 0 }
            else if URL(fileURLWithPath: path).deletingLastPathComponent().path == "/applications" { location = 1 }
            else if path.hasPrefix(homeApplications) { location = 2 }
            else if path.hasPrefix("/system/") { location = 3 }
            else { location = 4 }
            return (location, path.count, path)
        }
        let ordered = applications.sorted {
            let lhs = priority($0)
            let rhs = priority($1)
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.2 < rhs.2
        }
        var seenPaths = Set<String>()
        var seenBundleIDs = Set<String>()
        var seenSystemNames = Set<String>()
        let unique = ordered.filter { app in
            let physicalPath = app.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
            guard seenPaths.insert(physicalPath).inserted else { return false }
            if physicalPath.hasPrefix("/system/applications/"),
               !seenSystemNames.insert(app.displayName.lowercased()).inserted { return false }
            guard let bundleID = app.bundleIdentifier?.lowercased(), !bundleID.isEmpty else { return true }
            return seenBundleIDs.insert(bundleID).inserted
        }
        return unique.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.normalizedPath < $1.normalizedPath : order == .orderedAscending
        }
    }

    nonisolated private static func parseApplication(at url: URL) -> InstalledApplication? {
        guard let bundle = Bundle(url: url),
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let localizedInfo = bundle.localizedInfoDictionary ?? [:]
        // Menu bar apps and macOS launcher agents are visible in Finder's
        // Applications view and are user-launchable, so include them here.
        guard info["LSBackgroundOnly"] as? Bool != true else { return nil }
        let name = localizedMetadataName(for: url)
            ?? (localizedInfo["CFBundleDisplayName"] as? String)
            ?? (localizedInfo["CFBundleName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApplication(
            bundleIdentifier: bundle.bundleIdentifier,
            displayName: name,
            bundleURL: url,
            version: info["CFBundleShortVersionString"] as? String,
            isSystemApplication: url.path.hasPrefix("/System/")
        )
    }

    nonisolated private static func localizedMetadataName(for url: URL) -> String? {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString),
              let name = MDItemCopyAttribute(item, kMDItemDisplayName) as? String else { return nil }
        let displayName = (name as NSString).deletingPathExtension
        return displayName.isEmpty ? nil : displayName
    }
}

protocol ApplicationLaunching: Sendable {
    func launch(_ application: InstalledApplication) async throws
}

struct ApplicationLauncherService: ApplicationLaunching {
    func launch(_ application: InstalledApplication) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: application.bundleURL, configuration: configuration)
    }
}

protocol IconProviding: Sendable {
    func icon(for application: InstalledApplication) -> NSImage
    func prewarm(_ applications: [InstalledApplication]) async
    func clearCache()
}

final class IconProvider: IconProviding, @unchecked Sendable {
    @Observable
    fileprivate final class Slot {
        var image: NSImage
        var task: Task<Void, Never>?
        let application: InstalledApplication
        init(image: NSImage, application: InstalledApplication) {
            self.image = image
            self.application = application
        }
    }

    private var slots: [String: Slot] = [:]
    private let placeholder = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    // Serial IO keeps Launch Services from competing with itself during a cold scan.
    private let loader = DispatchQueue(label: "LaunchpadX.icon-loader", qos: .utility)

    private func slot(for application: InstalledApplication) -> Slot {
        let key = application.normalizedPath
        if let slot = slots[key] { return slot }
        let slot = Slot(image: placeholder, application: application)
        slots[key] = slot
        load(application, into: slot)
        return slot
    }

    private func load(_ application: InstalledApplication, into slot: Slot) {
        slot.task = Task { [loader] in
            let image: NSImage = await withCheckedContinuation { continuation in
                loader.async {
                    dispatchPrecondition(condition: .notOnQueue(.main))
                    let image = autoreleasepool {
                        let source = NSWorkspace.shared.icon(forFile: application.bundleURL.path)
                        var rect = CGRect(x: 0, y: 0, width: 256, height: 256)
                        guard let bitmap = source.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                            return source
                        }
                        return NSImage(cgImage: bitmap, size: rect.size)
                    }
                    continuation.resume(returning: image)
                }
            }
            guard !Task.isCancelled else { return }
            // Publish the loaded image, never perform filesystem IO from a view body.
            slot.image = image
            slot.task = nil
        }
    }

    func icon(for application: InstalledApplication) -> NSImage {
        slot(for: application).image
    }

    func prewarm(_ applications: [InstalledApplication]) async {
        for application in applications {
            guard !Task.isCancelled else { return }
            await slot(for: application).task?.value
        }
    }

    func clearCache() {
        for slot in slots.values {
            slot.task?.cancel()
            load(slot.application, into: slot)
        }
    }
}
