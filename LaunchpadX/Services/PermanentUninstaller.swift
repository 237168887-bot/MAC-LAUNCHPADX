import AppKit
import Foundation

enum PermanentUninstaller {
    enum Failure: LocalizedError {
        case invalidApplication
        case protectedApplication
        case cannotUninstallSelf
        case applicationIsRunning(String)
        case authorizationFailed(String)
        case authorizationCancelled

        var errorDescription: String? {
            switch self {
            case .invalidApplication:
                String(localized: "The application bundle is missing or is not a valid app path.")
            case .protectedApplication:
                String(localized: "System applications cannot be uninstalled.")
            case .cannotUninstallSelf:
                String(localized: "LaunchpadX cannot uninstall itself while it is running.")
            case .applicationIsRunning(let name):
                String(localized: "Quit \(name) before uninstalling it.")
            case .authorizationFailed(let reason):
                String(localized: "Administrator authorization failed: \(reason)")
            case .authorizationCancelled:
                String(localized: "Uninstall was cancelled because administrator authorization was not granted.")
            }
        }
    }

    static func matchingDataURLs(
        bundleIdentifier: String,
        libraryURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
    ) -> [URL] {
        guard !bundleIdentifier.isEmpty,
              !bundleIdentifier.contains("/"),
              !bundleIdentifier.contains("..") else { return [] }

        let candidates = [
            libraryURL.appending(path: "Application Support").appending(path: bundleIdentifier),
            libraryURL.appending(path: "Caches").appending(path: bundleIdentifier),
            libraryURL.appending(path: "Preferences").appending(path: "\(bundleIdentifier).plist"),
            libraryURL.appending(path: "Saved Application State").appending(path: "\(bundleIdentifier).savedState"),
            libraryURL.appending(path: "Containers").appending(path: bundleIdentifier),
            libraryURL.appending(path: "HTTPStorages").appending(path: bundleIdentifier),
            libraryURL.appending(path: "Logs").appending(path: bundleIdentifier)
        ].map(\.standardizedFileURL)

        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func uninstall(
        _ application: InstalledApplication,
        includingMatchingData: Bool,
        libraryURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library"),
        fileManager: FileManager = .default
    ) throws {
        guard application.canMoveToTrash else { throw Failure.protectedApplication }
        let appURL = application.bundleURL.standardizedFileURL
        guard appURL.pathExtension.lowercased() == "app",
              fileManager.fileExists(atPath: appURL.path) else {
            throw Failure.invalidApplication
        }
        if (try? appURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw Failure.invalidApplication
        }
        if let ownBundleID = Bundle.main.bundleIdentifier,
           application.bundleIdentifier == ownBundleID {
            throw Failure.cannotUninstallSelf
        }
        if let bundleID = application.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            throw Failure.applicationIsRunning(running.localizedName ?? application.displayName)
        }

        let dataURLs: [URL]
        if includingMatchingData, let bundleID = application.bundleIdentifier {
            dataURLs = matchingDataURLs(bundleIdentifier: bundleID, libraryURL: libraryURL)
        } else {
            dataURLs = []
        }

        let removalURLs = dataURLs + [appURL]
        for url in removalURLs {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                guard isPermissionError(error) else { throw error }
                try removeWithAdministratorAuthorization(removalURLs, fileManager: fileManager)
                return
            }
        }
    }

    static func administratorRemovalScript(for urls: [URL]) -> String {
        let shellArguments = urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let shellCommand = "/bin/rm -rf -- " + shellArguments.joined(separator: " ")
        let appleScriptString = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(appleScriptString)\" with administrator privileges"
    }

    private static func removeWithAdministratorAuthorization(_ urls: [URL], fileManager: FileManager) throws {
        let existingURLs = urls.filter { fileManager.fileExists(atPath: $0.path) }
        guard !existingURLs.isEmpty else { return }
        var scriptError: NSDictionary?
        let script = NSAppleScript(source: administratorRemovalScript(for: existingURLs))
        guard script?.executeAndReturnError(&scriptError) != nil else {
            let number = scriptError?[NSAppleScript.errorNumber] as? Int
            if number == -128 { throw Failure.authorizationCancelled }
            let reason = scriptError?[NSAppleScript.errorMessage] as? String ?? String(localized: "Unknown error")
            throw Failure.authorizationFailed(reason)
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 1 || nsError.code == 13 { return true }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileWriteNoPermission.rawValue { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionError(underlying)
        }
        return false
    }
}
