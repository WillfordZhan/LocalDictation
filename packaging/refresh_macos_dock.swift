import Foundation
import CoreFoundation

// Refresh only this product's existing Dock tile. Do not create a new tile,
// reorder entries, restart Dock, or change unrelated preference keys.
let domain = "com.apple.dock" as CFString
let persistentAppsKey = "persistent-apps" as CFString
let bundleIdentifier = "local.willford.dictation"
let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LocalDictation/UpgradeBackups/Dock")

struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message: message) }
}
func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
func exportDock() throws -> (Data, [String: Any]) {
    let process = Process()
    let output = Pipe(), errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = ["export", "com.apple.dock", "-"]
    process.standardOutput = output; process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let error = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try require(process.terminationStatus == 0,
                "Could not export Dock preferences: \(String(decoding: error, as: UTF8.self))")
    guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw Failure(message: "Dock preferences were not a property-list dictionary")
    }
    return (data, plist)
}
func same(_ lhs: Any, _ rhs: Any) -> Bool {
    guard let object = lhs as? NSObject else { return false }
    return object.isEqual(rhs)
}
func normalizedPath(_ value: String?) -> String? {
    guard let value, let url = URL(string: value), url.isFileURL else { return nil }
    return url.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}
func bookmarkReport(_ data: Data?) -> [String: Any] {
    guard let data else { return ["present": false] }
    var stale = false
    do {
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return ["present": true, "resolvedPath": url.path, "stale": stale]
    } catch {
        return ["present": true, "resolutionError": error.localizedDescription]
    }
}

do {
    let rawArguments = Array(CommandLine.arguments.dropFirst())
    let dryRun = rawArguments.contains("--dry-run")
    let arguments = rawArguments.filter { $0 != "--dry-run" }
    try require(arguments.count == 1 && arguments[0].hasPrefix("/"),
                "Usage: swift refresh-dock.swift [--dry-run] /absolute/LocalDictation.app")
    let app = URL(fileURLWithPath: arguments[0], isDirectory: true).standardizedFileURL
    let appInfo = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    let info = try PropertyListSerialization.propertyList(from: appInfo, format: nil) as? [String: Any]
    try require(info?["CFBundleIdentifier"] as? String == bundleIdentifier,
                "Destination is not the LocalDictation application")

    let (beforeData, beforePlist) = try exportDock()
    guard let before = beforePlist["persistent-apps"] as? [[String: Any]] else {
        throw Failure(message: "Dock persistent-apps is missing or malformed")
    }
    let matches = before.indices.filter { index in
        guard let tile = before[index]["tile-data"] as? [String: Any] else { return false }
        let fileData = tile["file-data"] as? [String: Any]
        return tile["bundle-identifier"] as? String == bundleIdentifier ||
            normalizedPath(fileData?["_CFURLString"] as? String) == normalizedPath(app.absoluteString)
    }
    // Duplicates need a separate explicit decision: this helper never silently
    // removes or moves Dock entries while trying to refresh a stale bookmark.
    try require(matches.count == 1, "Expected exactly one existing LocalDictation Dock tile, found \(matches.count)")
    let index = matches[0]
    var tile = before[index]["tile-data"] as! [String: Any]
    let oldBookmark = bookmarkReport(tile["book"] as? Data)
    let freshBookmark = try app.bookmarkData(options: [.suitableForBookmarkFile],
                                           includingResourceValuesForKeys: nil, relativeTo: nil)
    let newBookmark = bookmarkReport(freshBookmark)
    try require(newBookmark["resolvedPath"] as? String == app.path && newBookmark["stale"] as? Bool == false,
                "A fresh bookmark did not resolve to the destination application")
    var fileData = tile["file-data"] as? [String: Any] ?? [:]
    fileData["_CFURLString"] = app.absoluteString
    fileData["_CFURLStringType"] = 15
    tile["file-data"] = fileData
    tile["book"] = freshBookmark
    // Dock can retain a rendered icon by tile identity even after the app,
    // bookmark and Finder icon are fresh. Rebuild only this tile's identity
    // and filesystem dates; its slot and all other applications stay intact.
    tile.removeValue(forKey: "file-mod-date")
    tile.removeValue(forKey: "parent-mod-date")
    let usedGUIDs = Set(before.compactMap { ($0["GUID"] as? NSNumber)?.uint32Value })
    var refreshedGUID = UInt32.random(in: 1...UInt32.max)
    while usedGUIDs.contains(refreshedGUID) { refreshedGUID = UInt32.random(in: 1...UInt32.max) }
    var after = before
    after[index]["GUID"] = NSNumber(value: refreshedGUID)
    after[index]["tile-data"] = tile
    let report: [String: Any] = [
        "dryRun": dryRun, "slot": index, "previousGUID": before[index]["GUID"] ?? NSNull(), "GUID": refreshedGUID,
        "target": app.path, "url": app.absoluteString, "beforeBookmark": oldBookmark,
        "freshBookmark": newBookmark, "entryCount": before.count,
        "otherEntriesUnchangedByConstruction": before.indices.filter { $0 != index }.allSatisfy { same(before[$0], after[$0]) },
        "changes": ["matched bookmark", "matched file URL", "matched tile identity and cached filesystem dates"],
        "dockRestarted": false
    ]
    if dryRun {
        try emit(report)
    } else {
        // Export the complete domain before the narrow preference-key write.
        // The unique backup is never overwritten and can restore this exact state.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = outputDirectory.appendingPathComponent("dock-before-\(stamp)-\(UUID().uuidString).plist")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try beforeData.write(to: backup, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)

        guard let live = CFPreferencesCopyValue(persistentAppsKey, domain,
                                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [[String: Any]] else {
            throw Failure(message: "Could not read the live Dock preference array")
        }
        try require(same(live, before), "Dock entries changed during preparation; no preferences were written")
        CFPreferencesSetValue(persistentAppsKey, after as CFArray, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try require(CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
                    "Dock preference synchronization failed; backup: \(backup.path)")
        let (_, verifiedPlist) = try exportDock()
        guard let verified = verifiedPlist["persistent-apps"] as? [[String: Any]] else {
            throw Failure(message: "Cannot verify Dock preferences after update; backup: \(backup.path)")
        }
        try require(same(verified, after), "Dock preference verification failed; backup: \(backup.path)")
        var otherKeysBefore = beforePlist, otherKeysAfter = verifiedPlist
        otherKeysBefore.removeValue(forKey: "persistent-apps")
        otherKeysAfter.removeValue(forKey: "persistent-apps")
        try require(same(otherKeysBefore, otherKeysAfter),
                    "Another Dock preference key changed concurrently; inspect backup: \(backup.path)")
        var complete = report
        complete["backup"] = backup.path
        complete["otherEntriesUnchanged"] = before.indices.filter { $0 != index }.allSatisfy { same(before[$0], verified[$0]) }
        complete["allOtherPreferenceKeysUnchanged"] = true
        complete["writtenAndVerified"] = true
        try emit(complete)
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
