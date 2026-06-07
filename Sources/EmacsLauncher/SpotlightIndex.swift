//
// SpotlightIndex — publish the user's recent Emacs files into macOS Spotlight via Core
// Spotlight, so they're findable from Spotlight search and open straight into Emacs.
//
// Items are grouped under one domain identifier so a refresh can replace the whole set
// (files that dropped off the recent list are removed). Selecting a result hands the app
// a `CSSearchableItemActionType` NSUserActivity carrying the file path; the app delegate
// opens it through the usual `runEmacsGui` path — see `selectedPath(from:)`.
//
// The list comes from `RecentFiles.localPaths()` (absolute, existing, local). Indexing
// is best-effort and asynchronous; failures are surfaced only to the optional completion
// handler (used by the --reindex-spotlight developer flag).
//
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum SpotlightIndex {
    /// Groups all of our recent-file items, so we can replace or clear them as a set.
    static let domain = "io.alberti42.EmacsLauncher.recentf"
    /// UserDefaults key: whether to index recent files in Spotlight. Absent ⇒ enabled.
    static let enabledKey = "SpotlightIndexingEnabled"

    /// Whether indexing is on. Defaults to true when the user hasn't chosen.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil
            || UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Persist the on/off choice and act on it immediately: reindex when enabled, clear
    /// our domain when disabled.
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on { reindex() } else { clear() }
    }

    /// Rebuild our Spotlight items from the current recent-files list, replacing the whole
    /// domain (so files no longer recent are dropped). No-op when disabled. The recent-list
    /// lookup hits the daemon socket, so the work runs off the main thread.
    static func reindex(completion: ((Error?) -> Void)? = nil) {
        guard isEnabled else { completion?(nil); return }
        DispatchQueue.global(qos: .utility).async {
            let items = RecentFiles.localPaths().enumerated().map { item(for: $0.element, rank: $0.offset) }
            let index = CSSearchableIndex.default()
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
                guard !items.isEmpty else { completion?(nil); return }
                index.indexSearchableItems(items, completionHandler: completion)
            }
        }
    }

    /// Remove all of our items from the Spotlight index.
    static func clear(completion: ((Error?) -> Void)? = nil) {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain],
                                                          completionHandler: completion)
    }

    /// The file path encoded in a Spotlight-result-selection user activity, or nil if the
    /// activity isn't one of ours.
    static func selectedPath(from activity: NSUserActivity) -> String? {
        guard activity.activityType == CSSearchableItemActionType,
              let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              !id.isEmpty else { return nil }
        return id
    }

    // MARK: Item building

    /// Build one searchable item for `path`. `rank` is the position in the recent list (0 =
    /// most recent); we map it to a descending `rankingHint` so recent files rank higher.
    private static func item(for path: String, rank: Int) -> CSSearchableItem {
        let url = URL(fileURLWithPath: path)
        let type = UTType(filenameExtension: url.pathExtension) ?? .item
        let attrs = CSSearchableItemAttributeSet(contentType: type)
        attrs.title = url.lastPathComponent
        attrs.displayName = url.lastPathComponent
        attrs.path = path
        attrs.contentURL = url
        attrs.keywords = ["Emacs", "recent"]
        attrs.rankingHint = NSNumber(value: max(1, 100_000 - rank))
        // The unique identifier IS the path, so selection can open it directly.
        return CSSearchableItem(uniqueIdentifier: path, domainIdentifier: domain, attributeSet: attrs)
    }
}
