import Foundation
import os

nonisolated enum Paths {
    /// Unit tests run inside the app; they must never touch the person's data folder, windows, session or extensions.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The dev build keeps its data apart from the Zigzag you use.
        let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
        var dir = base.appendingPathComponent(isDev ? "Zigzag Dev" : "Zigzag", isDirectory: true)
        #if DEBUG
        // A second debug copy (for staged screenshots) keeps its own data, apart from the dev build's; unit tests
        // run in a fresh temporary folder so they never create or touch Application Support.
        if let custom = ProcessInfo.processInfo.environment["ZIGZAG_DATA_DIR"], !custom.isEmpty {
            dir = URL(fileURLWithPath: custom, isDirectory: true)
        } else if isHostingTests {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-test-host-\(UUID().uuidString)", isDirectory: true)
        }
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func file(_ name: String) -> URL { support.appendingPathComponent(name) }

    static func directory(_ name: String) -> URL {
        let dir = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func library(in root: URL = support) -> URL { root.appendingPathComponent("Library.json") }
    static func profiles(in root: URL = support) -> URL { root.appendingPathComponent("Profiles.json") }
    static func sidebarUI(in root: URL = support) -> URL { root.appendingPathComponent("SidebarUIState.json") }
    static func history(in root: URL = support) -> URL { root.appendingPathComponent("History.sqlite") }

    static let library = library(in: support)
    static let profiles = profiles(in: support)
    static let sidebarUI = sidebarUI(in: support)
    static let session = file("Session.json")
    static let downloads = file("Downloads.json")
    static let history = history(in: support)
    static let favicons = directory("Favicons")
    /// Icons that clearing history set aside, so ⌘Z can put them back. Emptied when Zigzag starts.
    static let setAsideIcons = support.appendingPathComponent("Cleared Icons", isDirectory: true)
    static let tabState = directory("TabState")
    static let snapshots = directory("Snapshots")
}

nonisolated enum JSONStore {
    private static let log = Logger(subsystem: "wang.zigao.zigzag", category: "storage")
    /// Unreadable files whose rename failed: never overwritten until they can be moved aside or are gone.
    private static let unmovedUnreadable = OSAllocatedUnfairLock(initialState: Set<URL>())

    enum LoadOutcome<T> {
        case loaded(T, rawData: Data)
        case missing
        case unreadable(asideSucceeded: Bool)

        var value: T? {
            if case .loaded(let value, _) = self { return value }
            return nil
        }
    }

    static func loadOutcome<T: Decodable>(_ type: T.Type, from url: URL,
                                          moveItem: (URL, URL) throws -> Void = FileManager.default.moveItem(at:to:)) -> LoadOutcome<T> {
        let key = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            _ = unmovedUnreadable.withLock { $0.remove(key) }
            return .missing
        }
        guard let data = try? Data(contentsOf: url) else {
            // There but can't be read (its permissions, a disk error): set aside too, so a fresh start can't save
            // over it.
            return .unreadable(asideSucceeded: setAside(url, moveItem: moveItem))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let value = try? decoder.decode(type, from: data) {
            _ = unmovedUnreadable.withLock { $0.remove(key) }
            return .loaded(value, rawData: data)
        }
        // There, but unreadable (cut short, or written by a newer Zigzag): kept aside, never written over, so
        // starting fresh can't erase it and it can still be recovered.
        return .unreadable(asideSucceeded: setAside(url, moveItem: moveItem))
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        loadOutcome(type, from: url).value
    }

    @discardableResult
    static func setAside(_ url: URL, moveItem: (URL, URL) throws -> Void = FileManager.default.moveItem(at:to:)) -> Bool {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let stem = url.deletingPathExtension()
        let ext = url.pathExtension
        func candidate(_ attempt: Int) -> URL {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let tag = ext.isEmpty ? "unreadable-\(stamp)\(suffix)" : "unreadable-\(stamp)\(suffix).\(ext)"
            return stem.appendingPathExtension(tag)
        }
        var attempt = 1
        var aside = candidate(attempt)
        while FileManager.default.fileExists(atPath: aside.path) {
            attempt += 1
            aside = candidate(attempt)
        }
        let key = url.standardizedFileURL
        do {
            try moveItem(url, aside)
            _ = unmovedUnreadable.withLock { $0.remove(key) }
            return true
        } catch {
            log.error("Couldn't set aside unreadable file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            tellOnce(error)
            guard FileManager.default.fileExists(atPath: url.path) else {
                _ = unmovedUnreadable.withLock { $0.remove(key) }
                return true
            }
            _ = unmovedUnreadable.withLock { $0.insert(key) }
            return false
        }
    }

    /// Whether it was written: for what must be on disk before something that can't be undone goes ahead.
    @discardableResult
    static func save<T: Encodable>(_ value: T, to url: URL) -> Bool {
        guard let data = encode(value) else { return false }
        return write(data, to: url)
    }

    /// What `save` writes, for comparing with what was written last.
    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        // Keys in a fixed order, so the same value always encodes to the same bytes: the session save skips a write
        // that would change nothing, and that only works if equal sessions compare equal (#89).
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    @discardableResult
    static func write(_ data: Data, to url: URL,
                      moveItem: (URL, URL) throws -> Void = FileManager.default.moveItem(at:to:)) -> Bool {
        let key = url.standardizedFileURL
        if unmovedUnreadable.withLock({ $0.contains(key) }) {
            if FileManager.default.fileExists(atPath: url.path), !setAside(url, moveItem: moveItem) {
                return false
            }
            _ = unmovedUnreadable.withLock { $0.remove(key) }
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            tellOnce(error)
            return false
        }
    }

    /// A save that failed (the disk full, a folder you can't write to) is said once a run, in the front window, so
    /// work doesn't go unsaved without anyone knowing.
    private static let told = OSAllocatedUnfairLock(initialState: false)
    private static func tellOnce(_ error: Error) {
        guard told.withLock({ old in defer { old = true }; return !old }) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
                Toast.show(SaveFailure.message(String(localized: "Zigzag couldn’t save your tabs and spaces", comment: "Toast when Zigzag can't write its library of spaces and tabs; a reason may follow as its own sentence."), error), symbol: "exclamationmark.triangle",
                           duration: 8, in: controller)
            }
        }
    }
}
