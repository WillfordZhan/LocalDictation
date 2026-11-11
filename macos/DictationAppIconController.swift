import AppKit
import ApplicationServices
import Darwin

/// Finder custom icons are user metadata; the sealed executable, resources and
/// designated requirement are not rewritten. Ordinary signature validation
/// remains valid in the isolated signed-bundle probe. `codesign --strict` can
/// reject FinderInfo/resource-fork metadata, so release archives must be built
/// clean, before any user customization. See docs/app-icons.md for the limits.
final class DictationAppIconController {
    struct Operations {
        var loadImage: (DictationAppIconStyle) -> NSImage?
        var customIcon: (URL) throws -> NSImage?
        var setFileIcon: (NSImage?, URL) -> Bool
        var accessibilityTrusted: () -> Bool
        var updateRunningIcon: (NSImage) -> Void
    }

    private struct Request {
        let style: DictationAppIconStyle
        let completion: (Result<Void, Error>) -> Void
    }
    private struct IconError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private let applicationURL: URL
    private let operations: Operations
    // NSWorkspace permits setIcon off-main, but not simultaneous calls. Keep
    // file operations off the microphone/UI thread and complete on main.
    private let fileQueue = DispatchQueue(label: "local-dictation.app-icon", qos: .userInitiated)
    private var requests: [Request] = []
    private var applying = false

    convenience init(bundle: Bundle = .main) {
        self.init(applicationURL: bundle.bundleURL, operations: Operations(
            loadImage: { style in
                bundle.url(forResource: style.resourceName, withExtension: "icns")
                    .flatMap { NSImage(contentsOf: $0) }
            },
            customIcon: Self.customIconSnapshot,
            setFileIcon: { image, url in NSWorkspace.shared.setIcon(image, forFile: url.path, options: []) },
            accessibilityTrusted: { AXIsProcessTrusted() },
            updateRunningIcon: { image in
                NSApp.applicationIconImage = image
                NSApp.dockTile.display()
            }
        ))
    }

    init(applicationURL: URL, operations: Operations) {
        self.applicationURL = applicationURL; self.operations = operations
    }

    static func customIconSnapshot(at url: URL) throws -> NSImage? {
        // URLResourceValues.customIcon can return nil after setIcon succeeds.
        // FinderInfo stores big-endian finderFlags at bytes 8–9; the documented
        // kHasCustomIcon flag is 0x0400. Only read it; all icon writes remain
        // NSWorkspace operations rather than direct metadata manipulation.
        var info = [UInt8](repeating: 0, count: 32)
        let count = getxattr(url.path, "com.apple.FinderInfo", &info, info.count, 0, 0)
        if count < 0 {
            let code = errno
            if code == ENOATTR { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        guard count >= 10 else { throw IconError(message: "无法读取原图标信息，未进行切换。") }
        let finderFlags = UInt16(info[8]) << 8 | UInt16(info[9])
        guard finderFlags & 0x0400 != 0 else { return nil }
        // Materialize Icon Services' lazy image before replacing the file icon;
        // rollback must not retain an image that later resolves the new icon.
        let image = NSWorkspace.shared.icon(forFile: url.path)
        guard let data = image.tiffRepresentation, let snapshot = NSImage(data: data), snapshot.isValid else {
            throw IconError(message: "无法读取原图标，未进行切换。")
        }
        return snapshot
    }

    func apply(style: DictationAppIconStyle, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async {
            self.requests.append(Request(style: style, completion: completion))
            self.startNext()
        }
    }

    private func startNext() {
        guard !applying, !requests.isEmpty else { return }
        applying = true
        let request = requests.removeFirst()
        guard let image = operations.loadImage(request.style), image.isValid else {
            finish(request, .failure(IconError(message: "图标资源不完整，请重新安装应用后重试。")))
            return
        }
        fileQueue.async {
            let result: Result<Void, Error>
            do {
                // Retain nil as nil: rolling back the default must remove a
                // custom icon, not install a bitmap of the default as metadata.
                let previous = try self.operations.customIcon(self.applicationURL)
                let trustedBefore = self.operations.accessibilityTrusted()
                let replacement: NSImage? = request.style == .softMist ? nil : image
                if !self.operations.setFileIcon(replacement, self.applicationURL) {
                    let restored = self.operations.setFileIcon(previous, self.applicationURL)
                    let reason = "无法更新应用图标，请确认应用位于可写入的文件夹，而不是安装镜像中。"
                    throw IconError(message: reason + (restored ? "" : " 原图标也未能恢复，请重新打开应用后重试。"))
                }
                if trustedBefore && !self.operations.accessibilityTrusted() {
                    let restored = self.operations.setFileIcon(previous, self.applicationURL)
                    throw IconError(message: "自动填入权限状态发生变化，图标切换已取消。" + (restored ? "" : " 原图标未能恢复，请重新打开应用后重试。"))
                }
                result = .success(())
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                // A failed Finder write or trust check must never advertise a
                // successful Dock-only change. No TCC prompt or reset is used.
                if case .success = result { self.operations.updateRunningIcon(image) }
                self.finish(request, result)
            }
        }
    }

    private func finish(_ request: Request, _ result: Result<Void, Error>) {
        applying = false
        request.completion(result)
        startNext()
    }
}

/// Serializes OS updates with durable preferences. Theme notifications can
/// arrive during a file write; only the latest appearance is resolved once the
/// current transaction (including compensation on save failure) has finished.
final class DictationAppIconCoordinator {
    struct Selection: Equatable {
        var manualStyle: DictationAppIconStyle
        var followsSystem: Bool
        init(_ preferences: DictationPreferences) {
            manualStyle = preferences.appIconStyle
            followsSystem = preferences.appIconFollowsSystemAppearance
        }
    }
    typealias Apply = (DictationAppIconStyle, @escaping (Result<Void, Error>) -> Void) -> Void
    private let readSelection: () -> Selection
    private let saveSelection: (Selection) -> Bool
    private let applyIcon: Apply
    private let appearanceIsDark: () -> Bool
    private var pendingSelection: Selection?
    private var activeSelection: Selection?
    private var appearancePending = false
    private var selectionError: String?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var appliedStyle: DictationAppIconStyle?
    var onChange: (() -> Void)?

    convenience init(store: DictationStore, controller: DictationAppIconController,
                     appearanceIsDark: @escaping () -> Bool = {
                         // NSApp combines system appearance with the user's
                         // in-app override; no individual window decides it.
                         NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                     }) {
        self.init(readSelection: { Selection(store.preferences) }, saveSelection: {
            store.setAppIconStyle($0.manualStyle, followsSystemAppearance: $0.followsSystem)
        }, apply: controller.apply, appearanceIsDark: appearanceIsDark)
    }

    init(readSelection: @escaping () -> Selection, saveSelection: @escaping (Selection) -> Bool,
         apply: @escaping Apply, appearanceIsDark: @escaping () -> Bool) {
        self.readSelection = readSelection; self.saveSelection = saveSelection
        self.applyIcon = apply; self.appearanceIsDark = appearanceIsDark
    }

    func restore() { appearancePending = true; startNext() }
    func systemAppearanceChanged() {
        // A manual choice in flight may fail. Remember theme events while the
        // durable policy still follows appearance, so rollback can catch up.
        guard (pendingSelection ?? activeSelection ?? readSelection()).followsSystem || readSelection().followsSystem else { return }
        appearancePending = true; startNext()
    }
    func selectManual(_ style: DictationAppIconStyle) {
        guard DictationAppIconStyle.manualChoices.contains(style) else { return }
        var selection = pendingSelection ?? activeSelection ?? readSelection()
        selection.manualStyle = style; selection.followsSystem = false
        pendingSelection = selection; startNext()
    }
    func setFollowsSystem(_ follows: Bool) {
        var selection = pendingSelection ?? activeSelection ?? readSelection(); selection.followsSystem = follows
        pendingSelection = selection; startNext()
    }
    private func resolve(_ selection: Selection) -> DictationAppIconStyle {
        .resolved(manual: selection.manualStyle, followsSystem: selection.followsSystem, dark: appearanceIsDark())
    }
    private func startNext() {
        precondition(Thread.isMainThread)
        guard !busy, pendingSelection != nil || appearancePending else { return }
        let stored = readSelection(), selection = pendingSelection ?? stored
        let persist = pendingSelection != nil
        // Preserve a rejected explicit choice across automatic reconciliation;
        // a purely automatic failure clears after a later automatic success.
        if persist { selectionError = nil }
        let retainedError = selectionError
        let target = resolve(selection), previous = appliedStyle ?? resolve(stored)
        pendingSelection = nil; appearancePending = false
        activeSelection = selection
        busy = true; error = retainedError; onChange?()
        let completed: (Result<Void, Error>) -> Void = { result in
            switch result {
            case .failure(let failure):
                // A failed write can also fail its compensation. Invalidate
                // the cache so retrying the selected style really writes it.
                self.appliedStyle = nil
                if persist { self.selectionError = failure.localizedDescription }
                self.finish(error: failure.localizedDescription)
            case .success:
                self.appliedStyle = target
                guard persist, !self.saveSelection(selection) else { self.finish(error: retainedError); return }
                // Restore the actual last applied style, not a newly resolved
                // theme. A newer theme notification is handled after rollback.
                self.applyIcon(previous) { rollback in
                    var message = "图标选择未能保存，请检查数据文件夹后重试。"
                    if case .failure(let failure) = rollback {
                        self.appliedStyle = nil; message += " " + failure.localizedDescription
                    }
                    else { self.appliedStyle = previous }
                    self.selectionError = message
                    self.finish(error: message)
                }
            }
        }
        if appliedStyle == target { completed(.success(())) }
        else { applyIcon(target, completed) }
    }
    private func finish(error: String?) {
        busy = false; activeSelection = nil; self.error = error; onChange?()
        startNext()
    }
}
