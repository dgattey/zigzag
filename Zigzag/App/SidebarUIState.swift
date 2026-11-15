import Foundation

/// Device-local sidebar fold and tuck state, kept in `SidebarUIState.json` apart from `Library.json` so opening or
/// shutting a folder never dirties synced spaces or undo snapshots. Open folders are absent from `shutFolders`.
nonisolated struct SidebarUIState: Codable, Equatable, Sendable {
    struct ShutFolder: Codable, Equatable, Sendable {
        /// The pages that were open when it was shut: shut on purpose, it hides them too (#154), though pages opened
        /// after still show under it (#94).
        var tucked: [UUID]? = nil
    }

    private(set) var shutFolders: [String: ShutFolder] = [:]

    func isFolderOpen(_ id: UUID) -> Bool {
        shutFolders[id.uuidString] == nil
    }

    func tuckedBookmarks(in id: UUID) -> Set<UUID> {
        Set(shutFolders[id.uuidString]?.tucked ?? [])
    }

    @discardableResult
    mutating func setFolderOpen(_ id: UUID, _ open: Bool, tucking: Set<UUID> = []) -> Bool {
        let key = id.uuidString
        if open {
            return shutFolders.removeValue(forKey: key) != nil
        }
        let sorted = tucking.isEmpty ? nil : tucking.sorted { $0.uuidString < $1.uuidString }
        let next = ShutFolder(tucked: sorted)
        guard shutFolders[key] != next else { return false }
        shutFolders[key] = next
        return true
    }

    @discardableResult
    mutating func untuck(_ bookmarkID: UUID) -> Bool {
        var changed = false
        for key in Array(shutFolders.keys) {
            guard var tucked = shutFolders[key]?.tucked, tucked.contains(bookmarkID) else { continue }
            tucked.removeAll { $0 == bookmarkID }
            shutFolders[key]?.tucked = tucked.isEmpty ? nil : tucked
            changed = true
        }
        return changed
    }

    @discardableResult
    mutating func prune(keepingFolders liveFolders: Set<UUID>, bookmarks liveBookmarks: Set<UUID>) -> Bool {
        var changed = false
        for (key, folder) in shutFolders {
            guard let id = UUID(uuidString: key), liveFolders.contains(id) else {
                shutFolders.removeValue(forKey: key)
                changed = true
                continue
            }
            if let tucked = folder.tucked {
                let kept = tucked.filter { liveBookmarks.contains($0) }
                let normalized = kept.isEmpty ? nil : kept
                if normalized != tucked {
                    shutFolders[key]?.tucked = normalized
                    changed = true
                }
            }
        }
        return changed
    }

    private struct LegacyLibrary: Decodable {
        struct Space: Decodable {
            var folders: [LegacyFolder]?
        }
        var spaces: [Space]
    }

    private struct LegacyFolder: Decodable {
        var id: UUID
        var isOpen: Bool?
        var tucked: [UUID]?
    }

    static func migratedFromLegacyLibraryJSON(_ data: Data) -> (state: SidebarUIState, hadLegacyKeys: Bool) {
        guard let stored = try? JSONDecoder().decode(LegacyLibrary.self, from: data) else {
            return (SidebarUIState(), false)
        }
        return migrated(from: stored.spaces.compactMap(\.folders).flatMap { $0 })
    }

    private static func migrated(from folders: [LegacyFolder]) -> (state: SidebarUIState, hadLegacyKeys: Bool) {
        var state = SidebarUIState()
        var hadLegacyKeys = false
        for folder in folders {
            if folder.isOpen != nil || folder.tucked != nil { hadLegacyKeys = true }
            if folder.isOpen == false {
                state.setFolderOpen(folder.id, false, tucking: Set(folder.tucked ?? []))
            }
        }
        return (state, hadLegacyKeys)
    }
}
