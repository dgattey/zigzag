import Foundation
import Testing
@testable import Zigzag

@MainActor
struct SidebarUIStateMigrationTests {
    private func withTempRoot(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-sidebar-ui-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func folderFoldAndTuckPersistInSidebarUIStateWithoutTouchingLibraryOrUndo() throws {
        try withTempRoot { root in
            let library = Library(root: root)
            let spaceID = library.spaces[0].id
            let first = try #require(library.addBookmark(url: URL(string: "https://example.com/a")!, title: "A", to: spaceID))
            let second = try #require(library.addBookmark(url: URL(string: "https://example.com/b")!, title: "B", to: spaceID))
            let folder = try #require(library.addFolder(named: "Docs", with: [first.id, second.id], in: spaceID))
            library.saveNow()

            let snapshotBefore = library.snapshot
            var libraryChanges = 0
            var uiChanges = 0
            let changedToken = library.changed.observe { libraryChanges += 1 }
            let uiToken = library.sidebarUIChanged.observe { uiChanges += 1 }
            _ = (changedToken, uiToken)

            library.setFolderOpen(folder.id, false, tucking: [second.id, first.id])
            #expect(!library.isFolderOpen(folder.id))
            #expect(library.tuckedBookmarks(inFolder: folder.id) == [first.id, second.id].sorted { $0.uuidString < $1.uuidString })
            #expect(uiChanges == 1 && libraryChanges == 0)
            #expect(library.snapshot == snapshotBefore)

            library.untuck(first.id)
            #expect(library.tuckedBookmarks(inFolder: folder.id) == [second.id])
            #expect(uiChanges == 2 && libraryChanges == 0)
            #expect(library.snapshot == snapshotBefore)

            library.saveNow()
            let rawLibrary = try String(contentsOf: Paths.library(in: root), encoding: .utf8)
            #expect(!rawLibrary.contains("isOpen"))
            #expect(!rawLibrary.contains("tucked"))

            let savedUI = try #require(JSONStore.load(SidebarUIState.self, from: Paths.sidebarUI(in: root)))
            #expect(!savedUI.isFolderOpen(folder.id))
            #expect(savedUI.tuckedBookmarks(in: folder.id) == [second.id])

            library.setFolderOpen(folder.id, true)
            library.saveSidebarUINow()
            let reloaded = Library(root: root)
            #expect(reloaded.isFolderOpen(folder.id))
            #expect(reloaded.tuckedBookmarks(inFolder: folder.id) == nil)
        }
    }

    @Test func legacyLibraryMigratesOnceAndNeverReMigratesAfterReopen() throws {
        try withTempRoot { root in
            let spaceID = UUID()
            let shutFolder = UUID()
            let openFolder = UUID()
            let pinnedA = UUID()
            let pinnedB = UUID()
            let legacyJSON = """
            {
              "searchEngine": "google",
              "spaces": [{
                "id": "\(spaceID.uuidString)",
                "name": "Personal",
                "color": "sky",
                "bookmarks": [
                  {"id": "\(pinnedA.uuidString)", "title": "A", "url": "https://example.com/a"},
                  {"id": "\(pinnedB.uuidString)", "title": "B", "url": "https://example.com/b"}
                ],
                "folders": [
                  {"id": "\(shutFolder.uuidString)", "name": "Shut", "bookmarkIDs": ["\(pinnedA.uuidString)"], "isOpen": false, "tucked": ["\(pinnedA.uuidString)"]},
                  {"id": "\(openFolder.uuidString)", "name": "Open", "bookmarkIDs": ["\(pinnedB.uuidString)"], "isOpen": true}
                ]
              }]
            }
            """
            try Data(legacyJSON.utf8).write(to: Paths.library(in: root), options: .atomic)
            #expect(!FileManager.default.fileExists(atPath: Paths.sidebarUI(in: root).path))

            let library = Library(root: root)
            #expect(!library.isFolderOpen(shutFolder))
            #expect(library.tuckedBookmarks(inFolder: shutFolder) == [pinnedA])
            #expect(library.isFolderOpen(openFolder))
            #expect(FileManager.default.fileExists(atPath: Paths.sidebarUI(in: root).path))

            library.setFolderOpen(shutFolder, true)
            library.saveSidebarUINow()
            let stillLegacyOnDisk = try String(contentsOf: Paths.library(in: root), encoding: .utf8)
            #expect(stillLegacyOnDisk.contains("\"isOpen\": false"))

            let reloadedBeforeLibraryFlush = Library(root: root)
            #expect(reloadedBeforeLibraryFlush.isFolderOpen(shutFolder))
            #expect(reloadedBeforeLibraryFlush.tuckedBookmarks(inFolder: shutFolder) == nil)

            library.saveNow()
            let strippedLibrary = try String(contentsOf: Paths.library(in: root), encoding: .utf8)
            #expect(!strippedLibrary.contains("isOpen"))
            #expect(!strippedLibrary.contains("tucked"))
        }
    }

    @Test func isolatedRootPrunesDeletedEntriesAndUntucksOnBookmarkOpen() throws {
        try withTempRoot { root in
            let library = Library(root: root)
            let profiles = Profiles(library: library)
            let spaceID = library.spaces[0].id
            let bookmark = try #require(library.addBookmark(url: URL(string: "https://example.com/doc")!, title: "Doc", to: spaceID))
            let keptFolder = try #require(library.addFolder(named: "Kept", with: [bookmark.id], in: spaceID))
            let goneFolder = try #require(library.addFolder(named: "Gone", with: [], in: spaceID))
            library.setFolderOpen(keptFolder.id, false, tucking: [bookmark.id])
            library.setFolderOpen(goneFolder.id, false)

            let manager = TabManager(spaceID: spaceID, library: library, profiles: profiles)
            defer { manager.invalidate() }
            _ = manager.pageTab(for: bookmark)
            #expect(library.tuckedBookmarks(inFolder: keptFolder.id) == nil)
            #expect(!library.isFolderOpen(keptFolder.id))

            library.removeFolder(goneFolder.id)
            library.saveNow()

            let reloaded = Library(root: root)
            reloaded.pruneProfileAssignments()
            reloaded.saveNow()
            #expect(reloaded.sidebarUI.shutFolders.keys.sorted() == [keptFolder.id.uuidString])
        }
    }
}
