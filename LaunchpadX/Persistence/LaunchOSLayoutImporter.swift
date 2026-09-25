import Foundation
import SQLite3

struct ImportedLaunchOSApplication: Hashable, Sendable {
    let application: InstalledApplication
    let alias: String?
    let isHidden: Bool
}

struct ImportedLaunchOSEntry: Sendable {
    let folderName: String?
    let applications: [ImportedLaunchOSApplication]
}

@MainActor
final class LaunchOSLayoutImporter {
    private struct ApplicationRow {
        let id: Int64
        let groupID: Int64?
        let order: Int
        let bundleIdentifier: String?
        let path: String?
        let alias: String?
        let isHidden: Bool
    }

    private struct GroupRow {
        let id: Int64
        let isFolder: Bool
        let order: Int
        let page: Int
        let name: String?
    }

    private let defaults: UserDefaults
    private let marker = "launchpadx.launchos-layout-import.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    @discardableResult
    func importIfAvailable(
        from sourceURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/LaunchOS/LaunchOS.sqlite"),
        discoveredApplications: [InstalledApplication],
        into repository: LayoutRepository
    ) throws -> Int {
        guard !defaults.bool(forKey: marker) else { return 0 }
        if try repository.hasAnySavedData() {
            defaults.set(true, forKey: marker)
            return 0
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return 0 }
        let (groups, rows) = try readDatabase(at: sourceURL)
        let matchedEntries = makeEntries(groups: groups, rows: rows, applications: discoveredApplications)
        guard !matchedEntries.isEmpty else { return 0 }
        let importedCount = try repository.importInitialLayout(matchedEntries)
        if importedCount > 0 { defaults.set(true, forKey: marker) }
        return importedCount
    }

    private func readDatabase(at url: URL) throws -> ([GroupRow], [ApplicationRow]) {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            defer { if let database { sqlite3_close(database) } }
            throw importerError("Could not open the existing LaunchOS layout database.")
        }
        defer { sqlite3_close(database) }
        sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil)

        let groups: [GroupRow] = try query(database,
            "SELECT Z_PK, ZISFOLDER, ZORDER, ZPAGE, ZNAME FROM ZGROUPENTITY",
            map: { statement in
                GroupRow(
                    id: sqlite3_column_int64(statement, 0),
                    isFolder: sqlite3_column_int(statement, 1) != 0,
                    order: Int(sqlite3_column_int(statement, 2)),
                    page: Int(sqlite3_column_int(statement, 3)),
                    name: text(statement, 4)
                )
            })
        let applications: [ApplicationRow] = try query(database,
            "SELECT Z_PK, ZGROUP, ZORDER, ZBUNDLEID, ZURL, ZALIAS, ZHIDDEN FROM ZAPPENTITY",
            map: { statement in
                ApplicationRow(
                    id: sqlite3_column_int64(statement, 0),
                    groupID: sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 1),
                    order: Int(sqlite3_column_int(statement, 2)),
                    bundleIdentifier: text(statement, 3),
                    path: text(statement, 4),
                    alias: text(statement, 5),
                    isHidden: sqlite3_column_int(statement, 6) != 0
                )
            })
        return (groups, applications)
    }

    private func makeEntries(
        groups: [GroupRow],
        rows: [ApplicationRow],
        applications: [InstalledApplication]
    ) -> [ImportedLaunchOSEntry] {
        var byBundleIdentifier: [String: [InstalledApplication]] = [:]
        for application in applications {
            guard let identifier = application.bundleIdentifier else { continue }
            byBundleIdentifier[identifier.lowercased(), default: []].append(application)
        }
        let byPath = Dictionary(grouping: applications, by: \.normalizedPath)
        func match(_ row: ApplicationRow) -> ImportedLaunchOSApplication? {
            let foundByPath = row.path.flatMap { path -> InstalledApplication? in
                return byPath[Self.normalizedPath(from: path)]?.first
            }
            let foundByID = row.bundleIdentifier.flatMap { byBundleIdentifier[$0.lowercased()]?.first }
            guard let application = foundByPath ?? foundByID else { return nil }
            return ImportedLaunchOSApplication(application: application, alias: row.alias, isHidden: row.isHidden)
        }

        var rowsByGroup: [Int64: [ApplicationRow]] = [:]
        for row in rows {
            guard let groupID = row.groupID else { continue }
            rowsByGroup[groupID, default: []].append(row)
        }
        for groupID in rowsByGroup.keys {
            rowsByGroup[groupID]?.sort { $0.order < $1.order }
        }
        var entries: [ImportedLaunchOSEntry] = []
        var representedIDs = Set<Int64>()
        for group in groups.sorted(by: {
            $0.page == $1.page ? $0.order < $1.order : $0.page < $1.page
        }) {
            let members = (rowsByGroup[group.id] ?? []).compactMap { row -> (ApplicationRow, ImportedLaunchOSApplication)? in
                guard let app = match(row) else { return nil }
                representedIDs.insert(row.id)
                return (row, app)
            }
            guard !members.isEmpty else { continue }
            if group.isFolder, members.count > 1 {
                entries.append(ImportedLaunchOSEntry(
                    folderName: group.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Folder",
                    applications: members.map { $0.1 }
                ))
            } else {
                entries.append(contentsOf: members.map {
                    ImportedLaunchOSEntry(folderName: nil, applications: [$0.1])
                })
            }
        }

        let looseRows = rows.filter { !representedIDs.contains($0.id) }.sorted { $0.order < $1.order }
        entries.append(contentsOf: looseRows.compactMap { row in
            match(row).map { ImportedLaunchOSEntry(folderName: nil, applications: [$0]) }
        })
        return entries
    }

    nonisolated static func normalizedPath(from storedPath: String) -> String {
        let url = URL(string: storedPath).flatMap { $0.isFileURL ? $0 : nil }
            ?? URL(fileURLWithPath: storedPath)
        return url.standardizedFileURL.path.lowercased()
    }

    private func query<Row>(
        _ database: OpaquePointer,
        _ sql: String,
        map: (OpaquePointer) -> Row
    ) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw importerError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(map(statement)) }
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            throw importerError(String(cString: sqlite3_errmsg(database)))
        }
        return rows
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func importerError(_ message: String) -> NSError {
        NSError(domain: "LaunchpadX.LaunchOSImport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
