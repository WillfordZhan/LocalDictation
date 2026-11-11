import AppKit

/// Workspace failure tests inject operations; a native metadata test uses one
/// temporary ordinary folder. Neither path touches the installed app, Dock
/// preferences, TCC or global system appearance.
@main
enum AppIconChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "AppIconChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ done: () -> Bool) throws {
        let until = Date().addingTimeInterval(5)
        while !done(), Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        try require(done(), "asynchronous completion timed out")
    }
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0)!)
        return image
    }
    final class Workspace {
        let icons = Dictionary(uniqueKeysWithValues: DictationAppIconStyle.allCases.map { ($0, AppIconChecks.image()) })
        var oldIcon: NSImage?
        var writes: [NSImage?] = [], dock: [NSImage] = []
        var outcomes: [Bool] = [], trust: [Bool] = [true, true]
        var resourceMissing = false, readFails = false
        lazy var controller = DictationAppIconController(applicationURL: URL(fileURLWithPath: "/not-a-real-application.app"), operations: .init(
            loadImage: { self.resourceMissing ? nil : self.icons[$0] },
            customIcon: { _ in
                if self.readFails { throw NSError(domain: "fixture", code: 1) }
                return self.oldIcon
            },
            setFileIcon: { icon, _ in
                self.writes.append(icon)
                return self.outcomes.isEmpty ? true : self.outcomes.removeFirst()
            },
            accessibilityTrusted: { self.trust.isEmpty ? true : self.trust.removeFirst() },
            updateRunningIcon: { self.dock.append($0) }
        ))
        func apply(_ style: DictationAppIconStyle) throws -> Result<Void, Error> {
            var result: Result<Void, Error>?, onMain = false
            controller.apply(style: style) { result = $0; onMain = Thread.isMainThread }
            try AppIconChecks.wait { result != nil }
            try AppIconChecks.require(onMain, "completion escaped main thread")
            return result!
        }
    }
    static func succeeded(_ result: Result<Void, Error>) -> Bool {
        if case .success = result { return true }; return false
    }
    static func controllerChecks() throws {
        let standard = Workspace()
        try require(succeeded(try standard.apply(.softMist)), "default application failed")
        try require(standard.writes.count == 1 && standard.writes[0] == nil && standard.dock.first === standard.icons[.softMist], "C must clear metadata and update running Dock")
        for style in [DictationAppIconStyle.dotFormation, .darkGlow] {
            let custom = Workspace()
            try require(succeeded(try custom.apply(style)), "custom application failed")
            try require(custom.writes.first! === custom.icons[style] && custom.dock.first === custom.icons[style], "Finder and Dock resources differ")
        }
        let denied = Workspace(); denied.outcomes = [false, true]
        try require(!succeeded(try denied.apply(.dotFormation)), "file write failure reported success")
        try require(denied.dock.isEmpty && denied.writes.count == 2 && denied.writes[1] == nil, "file failure updated Dock or failed to compensate")
        let trustLost = Workspace(); trustLost.trust = [true, false]; trustLost.oldIcon = image()
        try require(!succeeded(try trustLost.apply(.darkGlow)), "AX trust loss reported success")
        try require(trustLost.dock.isEmpty && trustLost.writes.last! === trustLost.oldIcon, "AX trust loss failed to restore prior custom icon")
        let untrusted = Workspace(); untrusted.trust = [false]
        try require(succeeded(try untrusted.apply(.dotFormation)), "existing lack of AX permission blocked customization")
        let broken = Workspace(); broken.outcomes = [true, false]; broken.trust = [true, false]
        if case .failure(let error) = try broken.apply(.darkGlow) {
            try require(error.localizedDescription.contains("原图标未能恢复"), "rollback failure hidden")
        } else { try require(false, "failed compensation reported success") }
        for missing in [true, false] {
            let fixture = Workspace(); fixture.resourceMissing = missing; fixture.readFails = !missing
            try require(!succeeded(try fixture.apply(.dotFormation)), "preflight failure reported success")
            try require(fixture.writes.isEmpty && fixture.dock.isEmpty, "preflight failure changed an icon")
        }
        let serial = Workspace(); var completed = 0
        serial.controller.apply(style: .dotFormation) { _ in completed += 1 }
        serial.controller.apply(style: .darkGlow) { _ in completed += 1 }
        try wait { completed == 2 }
        try require(serial.dock.count == 2 && serial.dock[0] === serial.icons[.dotFormation] && serial.dock[1] === serial.icons[.darkGlow], "concurrent API requests reordered")
    }
    final class CoordinatorFixture {
        var preferences = DictationPreferences(), dark = false, saveSucceeds = true, saves = 0
        var calls: [DictationAppIconStyle] = []
        var completions: [(Result<Void, Error>) -> Void] = []
        lazy var coordinator = DictationAppIconCoordinator(readSelection: { .init(self.preferences) }, saveSelection: { choice in
            self.saves += 1
            guard self.saveSucceeds else { return false }
            self.preferences.appIconStyle = choice.manualStyle
            self.preferences.appIconFollowsSystemAppearance = choice.followsSystem
            return true
        }, apply: { style, completion in self.calls.append(style); self.completions.append(completion) }, appearanceIsDark: { self.dark })
        func complete(_ success: Bool = true) {
            let callback = completions.removeFirst()
            callback(success ? .success(()) : .failure(NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "fixture apply failed"])))
        }
    }
    static func coordinatorChecks() throws {
        let startup = CoordinatorFixture(); startup.dark = true; startup.preferences.appIconStyle = .dotFormation
        startup.coordinator.restore()
        try require(startup.calls == [.darkGlow] && startup.coordinator.busy, "restart ignored effective appearance")
        startup.complete()
        try require(startup.saves == 0 && startup.preferences.appIconStyle == .dotFormation, "automatic appearance overwrote manual preference")
        startup.coordinator.setFollowsSystem(false); startup.complete()
        try require(startup.calls == [.darkGlow, .dotFormation] && !startup.preferences.appIconFollowsSystemAppearance, "manual memory lost")
        startup.dark = false; startup.coordinator.systemAppearanceChanged()
        try require(startup.calls.count == 2, "system event changed manual mode")

        let manualDark = CoordinatorFixture()
        manualDark.coordinator.selectManual(.darkGlow); manualDark.complete()
        try require(manualDark.calls == [.darkGlow] && manualDark.preferences.appIconStyle == .darkGlow && !manualDark.preferences.appIconFollowsSystemAppearance,
                    "dark glow cannot be manually selected in light appearance")
        manualDark.dark = true; manualDark.coordinator.systemAppearanceChanged()
        manualDark.dark = false; manualDark.coordinator.systemAppearanceChanged()
        try require(manualDark.calls == [.darkGlow], "appearance changes replaced manual dark glow")

        let themes = CoordinatorFixture(); themes.coordinator.restore()
        themes.dark = true; themes.coordinator.systemAppearanceChanged()
        themes.dark = false; themes.coordinator.systemAppearanceChanged(); themes.complete()
        try require(themes.calls == [.softMist] && themes.coordinator.appliedStyle == .softMist && !themes.coordinator.busy, "latest light appearance not coalesced")
        themes.dark = true; themes.coordinator.systemAppearanceChanged()
        themes.dark = false; themes.coordinator.systemAppearanceChanged(); themes.complete()
        try require(themes.calls == [.softMist, .darkGlow, .softMist] && themes.coordinator.busy, "queued light appearance dropped")
        themes.complete()
        try require(themes.coordinator.appliedStyle == .softMist && !themes.coordinator.busy, "theme changes did not converge")

        let failedSave = CoordinatorFixture(); failedSave.coordinator.restore(); failedSave.complete()
        failedSave.saveSucceeds = false; failedSave.coordinator.selectManual(.dotFormation); failedSave.complete()
        try require(failedSave.calls == [.softMist, .dotFormation, .softMist] && failedSave.coordinator.busy, "save failure did not compensate")
        failedSave.complete()
        try require(failedSave.preferences.appIconFollowsSystemAppearance && failedSave.preferences.appIconStyle == .softMist && failedSave.coordinator.appliedStyle == .softMist && failedSave.coordinator.error != nil, "save failure changed preferences or hid error")
        failedSave.coordinator.selectManual(.dotFormation); failedSave.complete(); failedSave.complete(false)
        try require(!failedSave.coordinator.busy && failedSave.coordinator.error?.contains("fixture apply failed") == true && failedSave.coordinator.appliedStyle == nil, "failed rollback retained an unverified cached style or blocked retry")
        failedSave.saveSucceeds = true; failedSave.coordinator.selectManual(.softMist); failedSave.complete()
        try require(failedSave.coordinator.error == nil && !failedSave.preferences.appIconFollowsSystemAppearance, "retry failed")

        let pending = CoordinatorFixture(); pending.coordinator.restore(); pending.complete()
        pending.dark = true; pending.coordinator.systemAppearanceChanged()
        pending.coordinator.setFollowsSystem(false); pending.coordinator.selectManual(.dotFormation)
        pending.dark = false; pending.coordinator.systemAppearanceChanged(); pending.complete(); pending.complete()
        try require(pending.calls == [.softMist, .darkGlow, .dotFormation] && !pending.preferences.appIconFollowsSystemAppearance && pending.preferences.appIconStyle == .dotFormation, "stale theme event overrode newest manual request")
        let failedApply = CoordinatorFixture(); failedApply.coordinator.selectManual(.dotFormation); failedApply.complete(false)
        try require(failedApply.saves == 0 && failedApply.preferences.appIconFollowsSystemAppearance && !failedApply.coordinator.busy, "OS failure persisted a choice")

        let automatic = CoordinatorFixture(); automatic.coordinator.restore(); automatic.complete(false)
        try require(automatic.coordinator.error != nil, "automatic failure was hidden")
        automatic.dark = true; automatic.coordinator.systemAppearanceChanged(); automatic.complete()
        try require(automatic.coordinator.appliedStyle == .darkGlow && automatic.coordinator.error == nil,
                    "successful automatic update retained a stale automatic failure")

        for storageFailure in [true, false] {
            let race = CoordinatorFixture(); race.coordinator.restore(); race.complete()
            race.saveSucceeds = !storageFailure
            race.coordinator.selectManual(.dotFormation)
            race.dark = true; race.coordinator.systemAppearanceChanged()
            race.complete(storageFailure)
            if storageFailure { race.complete() } // compensate to prior C
            try require(race.calls.last == .darkGlow && race.coordinator.busy,
                        "failed manual choice dropped a theme event required by the durable follow policy")
            race.complete()
            try require(race.coordinator.appliedStyle == .darkGlow && race.preferences.appIconFollowsSystemAppearance && race.coordinator.error != nil,
                        "appearance reconciliation lost either the current theme or the failed-choice message")
        }
    }
    static func pixels(_ image: NSImage) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
    static func nativeMetadataChecks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalDictationIconMetadataCheck-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            _ = DictationAppIconController.setFileIcon(nil, at: directory)
            try? FileManager.default.removeItem(at: directory)
        }
        func colored(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> NSImage {
            let icon = image(), bitmap = imageRep(icon)
            let bytes = bitmap.bitmapData!
            for y in 0..<32 { for x in 0..<32 {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = red; bytes[offset + 1] = green; bytes[offset + 2] = blue; bytes[offset + 3] = 255
            } }
            return icon
        }
        let dark = colored(120, 40, 190), dots = colored(230, 140, 40)
        try require(try DictationAppIconController.customIconSnapshot(at: directory) == nil, "default folder unexpectedly has a custom icon")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: directory.path)
        let beforeUpdate = Date()
        try require(DictationAppIconController.setFileIcon(dark, at: directory), "native custom icon setup failed")
        let modified = try FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate] as! Date
        try require(modified >= beforeUpdate, "successful icon update did not refresh directory mtime")
        let original = try DictationAppIconController.customIconSnapshot(at: directory)
        try require(original != nil, "native snapshot lost custom metadata (URL customIcon may return nil)")
        let darkPixels = pixels(original!)
        try require(DictationAppIconController.setFileIcon(dots, at: directory), "second native icon setup failed")
        let changed = try DictationAppIconController.customIconSnapshot(at: directory)
        try require(changed != nil && pixels(changed!) != darkPixels, "native snapshot returned a stale cached icon")
        try require(pixels(original!) == darkPixels, "snapshot changed lazily after the file changed")
        try require(DictationAppIconController.setFileIcon(dark, at: directory), "native icon reset failed")
        for hasCustom in [true, false] {
            if !hasCustom { _ = DictationAppIconController.setFileIcon(nil, at: directory) }
            var trustChecks = 0, dockUpdates = 0
            let controller = DictationAppIconController(applicationURL: directory, operations: .init(
                loadImage: { _ in dots }, customIcon: DictationAppIconController.customIconSnapshot,
                setFileIcon: { DictationAppIconController.setFileIcon($0, at: $1) },
                accessibilityTrusted: { trustChecks += 1; return trustChecks == 1 },
                updateRunningIcon: { _ in dockUpdates += 1 }
            ))
            var result: Result<Void, Error>?
            controller.apply(style: .dotFormation) { result = $0 }
            try wait { result != nil }
            try require(!succeeded(result!) && dockUpdates == 0, "native compensation reported success or changed Dock")
            let restored = try DictationAppIconController.customIconSnapshot(at: directory)
            if hasCustom { try require(restored != nil && pixels(restored!) == darkPixels, "D-to-B failure did not restore original D pixels") }
            else { try require(restored == nil, "default-C failure installed a custom icon instead of restoring nil") }
        }

        try require(DictationAppIconController.setFileIcon(dark, at: directory), "mtime failure fixture setup failed")
        var touches = 0, dockUpdates = 0
        let controller = DictationAppIconController(applicationURL: directory, operations: .init(
            loadImage: { _ in dots }, customIcon: DictationAppIconController.customIconSnapshot,
            setFileIcon: { image, url in
                DictationAppIconController.setFileIcon(image, at: url, updateModificationDate: { target in
                    touches += 1
                    if touches == 1 { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
                    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
                })
            }, accessibilityTrusted: { true }, updateRunningIcon: { _ in dockUpdates += 1 }
        ))
        let beforeRollback = Date()
        var result: Result<Void, Error>?
        controller.apply(style: .dotFormation) { result = $0 }
        try wait { result != nil }
        let restored = try DictationAppIconController.customIconSnapshot(at: directory)
        let rollbackDate = try FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate] as! Date
        try require(!succeeded(result!) && touches == 2 && dockUpdates == 0 && restored != nil && pixels(restored!) == darkPixels,
                    "mtime failure reported success or failed to restore the original icon")
        try require(rollbackDate >= beforeRollback, "compensation did not refresh directory mtime")
    }
    static func imageRep(_ image: NSImage) -> NSBitmapImageRep { image.representations[0] as! NSBitmapImageRep }
    static func applicationAppearanceChecks() throws {
        // This overrides only this invisible test process, not macOS appearance.
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        NSApp.appearance = NSAppearance(named: .aqua)
        let fixture = Workspace(), store = DictationStore(memoryOnly: true)
        let coordinator = DictationAppIconCoordinator(store: store, controller: fixture.controller)
        coordinator.restore()
        try wait { !coordinator.busy }
        try require(coordinator.appliedStyle == .softMist, "application light override did not resolve C")
        let observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            DispatchQueue.main.async { coordinator.systemAppearanceChanged() }
        }
        defer { observation.invalidate() }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try wait { coordinator.appliedStyle == .darkGlow && !coordinator.busy }
        NSApp.appearance = NSAppearance(named: .aqua)
        try wait { coordinator.appliedStyle == .softMist && !coordinator.busy }
        try require(fixture.dock.count == 3 && store.preferences.appIconStyle == .softMist,
                    "effective appearance observer missed a change or overwrote manual memory")
    }
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try controllerChecks(); try coordinatorChecks(); try applicationAppearanceChecks(); try nativeMetadataChecks()
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1)
        }
        print("PASS: resource/write failures, metadata rollback, AX guard, main-thread completion, serial writes; effective appearance coalescing, manual memory, startup restore, preference compensation and retry.")
        print("PASS: native temporary-folder snapshots, D-to-B/default-to-nil rollback, directory mtime updates and compensation on mtime failure.")
        print("LIMIT: installed application, Dock and AX remain unmodified; native icon operations only use a temporary ordinary folder.")
    }
}
