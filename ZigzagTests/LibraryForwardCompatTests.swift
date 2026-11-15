import AppKit
import Foundation
import Testing
@testable import Zigzag

@MainActor
struct LibraryForwardCompatTests {
    private func withTempRoot(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-forward-compat-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func strictRawValueRejectsUnknownStringsWhileDecodedKeepsThem() {
        #expect(SpaceColor(rawValue: "sky") == .sky)
        #expect(SpaceColor(rawValue: "ultraviolet") == nil)
        #expect(SpaceColor(rawValue: "") == nil)
        #expect(SpaceColor.decoded("ultraviolet").rawValue == "ultraviolet")
        #expect(!SpaceColor.decoded("ultraviolet").isKnown)
        #expect(SpaceColor.decoded("") == .graphite)
        #expect(SpaceColor.decoded("").isKnown)

        #expect(SearchEngine(rawValue: "kagi") == .kagi)
        #expect(SearchEngine(rawValue: "quantumSearch") == nil)
        #expect(SearchEngine(rawValue: "") == nil)
        #expect(SearchEngine.decoded("quantumSearch").rawValue == "quantumSearch")
        #expect(!SearchEngine.decoded("quantumSearch").isKnown)
        #expect(SearchEngine.decoded("") == .google)
        #expect(SearchEngine.decoded("").isKnown)
    }

    @Test func unknownSpaceColorsSurviveLibraryAndProfileSavesWithoutStampingTint() throws {
        try withTempRoot { root in
            let spaceID = UUID()
            let profileID = UUID()
            let libraryJSON = """
            {"searchEngine":"google","spaces":[{"bookmarks":[],"color":"ultraviolet","defaultColor":"solarFlare","id":"\(spaceID.uuidString)","name":"Future"}]}
            """
            let profilesJSON = """
            {"first":{"color":"aurora","id":"\(Profile.defaultID.uuidString)","name":"Main"},"others":[{"color":"nebula","id":"\(profileID.uuidString)","name":"Work"}]}
            """
            try Data(libraryJSON.utf8).write(to: Paths.library(in: root), options: .atomic)
            try Data(profilesJSON.utf8).write(to: Paths.profiles(in: root), options: .atomic)

            let library = Library(root: root)
            let space = try #require(library.space(spaceID))
            #expect(!space.color.isKnown && space.color.rawValue == "ultraviolet")
            #expect(space.defaultColor?.isKnown == false && space.defaultColor?.rawValue == "solarFlare")
            #expect(space.tint == nil)
            #expect(space.background == SpaceColor.graphite.background)
            #expect(space.swatch == SpaceColor.graphite.swatch)
            #expect(library.profiles.first?.color?.rawValue == "aurora")
            #expect(library.profiles.last?.color?.rawValue == "nebula")

            library.renameSpace(spaceID, to: "Future Renamed")
            library.updateProfile(profileID, name: "Work Renamed", color: library.profiles.last?.color)
            library.saveNow()

            let rawLibrary = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: Paths.library(in: root))) as? [String: Any])
            let savedSpace = try #require((rawLibrary["spaces"] as? [[String: Any]])?.first)
            #expect(savedSpace["color"] as? String == "ultraviolet")
            #expect(savedSpace["defaultColor"] as? String == "solarFlare")
            #expect(savedSpace["tint"] == nil)

            let reloaded = Library(root: root)
            #expect(reloaded.space(spaceID)?.color.rawValue == "ultraviolet")
            #expect(reloaded.space(spaceID)?.defaultColor?.rawValue == "solarFlare")
            #expect(reloaded.space(spaceID)?.tint == nil)
            #expect(reloaded.profiles.first?.color?.rawValue == "aurora")
            #expect(reloaded.profiles.last?.color?.rawValue == "nebula")
        }
    }

    @Test func unknownSearchEngineSurvivesLibraryAndExtensionFallback() throws {
        try withTempRoot { root in
            let spaceID = UUID()
            let libraryJSON = """
            {"searchEngine":"quantumSearch","spaces":[{"bookmarks":[],"color":"sky","id":"\(spaceID.uuidString)","name":"Home"}]}
            """
            try Data(libraryJSON.utf8).write(to: Paths.library(in: root), options: .atomic)

            let library = Library(root: root)
            #expect(!library.searchEngine.isKnown)
            #expect(library.searchEngine.rawValue == "quantumSearch")
            #expect(library.searchEngine.name == SearchEngine.google.name)
            #expect(library.searchEngine.searchURL("swift") == SearchEngine.google.searchURL("swift"))
            #expect(library.searchEngine.homeURL == SearchEngine.google.homeURL)
            #expect(library.searchEngine.suggestionsURL("swift") == SearchEngine.google.suggestionsURL("swift"))

            library.addSpace(name: "Second")
            library.saveNow()

            let reloaded = Library(root: root)
            #expect(!reloaded.searchEngine.isKnown && reloaded.searchEngine.rawValue == "quantumSearch")

            let key = "SearchEngineBeforeExtension"
            let prior = UserDefaults.standard.object(forKey: key)
            defer {
                if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            ExtensionSearchProvider.previousEngine = SearchEngine.decoded("quantumSearch")
            #expect(!ExtensionSearchProvider.previousEngine.isKnown)
            #expect(ExtensionSearchProvider.previousEngine.rawValue == "quantumSearch")
        }
    }

    @Test func setAsideDisambiguatesCollisionsAndProtectsUnmovedUnreadableFiles() throws {
        try withTempRoot { root in
            try Data("corrupt-library".utf8).write(to: Paths.library(in: root), options: .atomic)
            try Data("corrupt-profiles".utf8).write(to: Paths.profiles(in: root), options: .atomic)

            let recovered = Library(root: root)
            #expect(recovered.profilesWereSetAside)
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(files.contains { $0.hasPrefix("Library.unreadable-") && $0.hasSuffix(".json") })
            #expect(files.contains { $0.hasPrefix("Profiles.unreadable-") && $0.hasSuffix(".json") })

            let collisionFile = root.appendingPathComponent("Sample.json")
            try Data("bad-one".utf8).write(to: collisionFile, options: .atomic)
            #expect(JSONStore.setAside(collisionFile))
            try Data("bad-two".utf8).write(to: collisionFile, options: .atomic)
            #expect(JSONStore.setAside(collisionFile))
            let asideSamples = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("Sample.unreadable-") }
            #expect(asideSamples.count == 2)
            #expect(Set(asideSamples.compactMap { try? String(contentsOf: $0, encoding: .utf8) }) == ["bad-one", "bad-two"])

            let lockedFile = root.appendingPathComponent("Locked.json")
            try Data("precious-unreadable".utf8).write(to: lockedFile, options: .atomic)
            let denyMove: (URL, URL) throws -> Void = { _, _ in throw CocoaError(.fileWriteNoPermission) }
            let outcome = JSONStore.loadOutcome([String: String].self, from: lockedFile, moveItem: denyMove)
            if case .unreadable(let asideSucceeded) = outcome {
                #expect(!asideSucceeded)
            } else {
                Issue.record("Expected unreadable outcome")
            }
            #expect(!JSONStore.write(Data(#"{"ok":"1"}"#.utf8), to: lockedFile, moveItem: denyMove))
            #expect(try String(contentsOf: lockedFile, encoding: .utf8) == "precious-unreadable")

            if geteuid() != 0 {
                let lockedRoot = root.appendingPathComponent("ReadOnly", isDirectory: true)
                try FileManager.default.createDirectory(at: lockedRoot, withIntermediateDirectories: true)
                try Data("precious-library-bytes".utf8).write(to: Paths.library(in: lockedRoot), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedRoot.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedRoot.path) }

                let fallback = Library(root: lockedRoot)
                #expect(fallback.spaces.count == 1)
                #expect(try String(contentsOf: Paths.library(in: lockedRoot), encoding: .utf8) == "precious-library-bytes")
            }
        }
    }

    @Test func setPinnedSplitLayoutEmitsChangesSkipsNoOpsAndPreservesUndo() {
        withTempRoot { root in
            let library = Library(root: root)
            defer { library.saveNow() }
            let spaceID = library.spaces[0].id

            let m0 = Bookmark(url: URL(string: "https://example.com/0")!, title: "0")
            let m1 = Bookmark(url: URL(string: "https://example.com/1")!, title: "1")
            let m2 = Bookmark(url: URL(string: "https://example.com/2")!, title: "2")
            var group = PinnedSplit(left: m0.id, right: m1.id)
            group.more = [m2.id]
            group.regions = [.left, .topRight, .bottomRight]
            group.ratio = 0.5
            group.otherRatio = 0.5
            library.addPinnedSplit([m0, m1, m2], as: group, to: spaceID)

            let f0 = Bookmark(url: URL(string: "https://example.com/f0")!, title: "F0")
            let f1 = Bookmark(url: URL(string: "https://example.com/f1")!, title: "F1")
            let favSplit = PinnedSplit(left: f0.id, right: f1.id)
            library.addFavoriteSplit([f0, f1], as: favSplit, in: Profile.defaultID)

            let snapshotBeforeResize = library.snapshot
            var libraryChangedCount = 0
            var layoutChanges: [Library.SplitLayoutChange] = []
            let changedToken = library.changed.observe { libraryChangedCount += 1 }
            let splitToken = library.splitLayoutChanged.observe { layoutChanges.append($0) }
            _ = (changedToken, splitToken)

            library.setPinnedSplitLayout(group)
            library.setPinnedSplitLayout(favSplit)
            #expect(layoutChanges.isEmpty && libraryChangedCount == 0)

            var resizedGroup = group
            resizedGroup.ratio = 0.35
            resizedGroup.otherRatio = 0.65
            resizedGroup.regions = [.topLeft, .bottomLeft, .right]
            library.setPinnedSplitLayout(resizedGroup)
            #expect(layoutChanges == [Library.SplitLayoutChange(location: .space(spaceID), split: resizedGroup)])
            #expect(libraryChangedCount == 0)
            #expect(library.snapshot == snapshotBeforeResize)

            var resizedFav = favSplit
            resizedFav.ratio = 0.7
            resizedFav.vertical = true
            library.setPinnedSplitLayout(resizedFav)
            #expect(layoutChanges.last == Library.SplitLayoutChange(location: .favorites, split: resizedFav))
            #expect(libraryChangedCount == 0)
            #expect(library.snapshot == snapshotBeforeResize)

            let swappedFav = PinnedSplit(left: f1.id, right: f0.id)
            library.setPinnedSplitLayout(swappedFav)
            #expect(layoutChanges.last == Library.SplitLayoutChange(location: .favorites, split: swappedFav))
            #expect(libraryChangedCount == 1)
            #expect(library.snapshot != snapshotBeforeResize)
        }
    }
}
