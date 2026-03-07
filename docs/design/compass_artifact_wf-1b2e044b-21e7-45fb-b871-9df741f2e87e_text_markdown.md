# iOS File Provider for git-backed Logseq sync

**Use Apple's replicated File Provider model (`NSFileProviderReplicatedExtension`, iOS 16+) to bridge your local git working tree to Logseq through the Files app.** The replicated model treats your on-disk git repo as the "remote" source of truth while the system manages its own local replica — an unintuitive fit for already-local files, but the only actively maintained path forward. The non-replicated `NSFileProviderExtension` API is effectively dead: Apple's Xcode templates, sample code, and engineer guidance all point exclusively to the replicated model, and macOS never supported the old API at all. The critical architectural constraint is the **20 MB memory limit** on iOS File Provider extensions, which means git operations (SwiftGit2/libgit2) must run exclusively in the main app — the extension stays lightweight, handling only file enumeration and individual file reads/writes.

---

## Recommended architecture and component design

The system maintains its own managed replica of your files — you cannot point it at your existing git directory. Your extension acts as a bidirectional bridge: reading from the git working tree for `fetchContents`/enumeration, and writing changes back from `createItem`/`modifyItem`/`deleteItem`. On APFS, the system's copy uses clones (near-zero additional storage).

```
┌──────────────────────┐           ┌───────────────────────────┐
│     Main App         │           │   File Provider Extension  │
│                      │  Shared   │                            │
│  • SwiftGit2 ops     │  App      │  • Enumerates working tree │
│    (pull/push/commit)│  Group    │  • fetchContents → return  │
│  • App Intents for   │  Container│    file URL from git tree  │
│    Shortcuts         │ ────────► │  • createItem/modifyItem → │
│  • BGTaskScheduler   │           │    write to git tree       │
│  • Registers domain  │           │  • deleteItem → remove     │
│  • signalEnumerator  │           │  • 20 MB memory ceiling    │
│    after git pull    │           │  • No libgit2 here         │
└──────────┬───────────┘           └────────────┬──────────────┘
           │                                    │
           └──────────────┬─────────────────────┘
                          │
           ┌──────────────▼──────────────────┐
           │     App Group Container          │
           │                                  │
           │  /repo/                          │
           │    .git/                         │
           │    pages/  journals/  logseq/    │
           │                                  │
           │  /metadata.sqlite                │
           │    (itemID ↔ path mapping,       │
           │     sync anchors, versions)      │
           └──────────────────────────────────┘
```

A single `NSFileProviderDomain` represents the repository. Register it from the main app at launch:

```swift
let domain = NSFileProviderDomain(
    identifier: NSFileProviderDomainIdentifier("logseq-repo"),
    displayName: "Logseq Knowledge Base"
)
NSFileProviderManager.add(domain) { error in /* handle */ }
```

The extension target should be **thin** — a `main.swift` entry point plus an `Extension` class conforming to `NSFileProviderReplicatedExtension`. All reusable logic (enumeration, database access, file operations) belongs in a **shared framework** that both the app and extension link against. This pattern (used by Cryptomator and Apple's FruitBasket sample) enables unit testing and keeps the extension process lean.

---

## Implementation checklist in build order

**Phase 1: Project setup.** Add a File Provider Extension target in Xcode (the template generates replicated model scaffolding). Create an App Group (`group.com.yourapp`) and enable it on both targets. Set `NSExtensionFileProviderDocumentGroup` in the extension's Info.plist to match. Move the git working tree into the shared container so both processes can access it. Create a shared framework for the metadata database and file-mapping logic.

**Phase 2: Metadata database.** Build a SQLite database (in the shared container) that maps each file's relative path to a stable UUID (`NSFileProviderItemIdentifier`), stores content versions (file modification timestamp or git blob SHA), and tracks sync anchors (monotonically increasing integer). The extension and main app both read this database; the main app writes after git operations, the extension writes after handling mutations.

**Phase 3: Item model.** Implement an `NSFileProviderItem`-conforming struct that wraps a database row:

```swift
struct FileProviderItem: NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier  // UUID from DB
    let parentItemIdentifier: NSFileProviderItemIdentifier  // Parent's UUID
    let filename: String
    let contentType: UTType  // .folder, .plainText for .md, etc.
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let creationDate: Date?
    let itemVersion: NSFileProviderItemVersion  // content + metadata versions
    let capabilities: NSFileProviderItemCapabilities = [
        .allowsReading, .allowsWriting, .allowsRenaming,
        .allowsReparenting, .allowsDeleting, .allowsContentEnumerating
    ]
}
```

**Phase 4: Enumeration.** Implement `NSFileProviderEnumerator` for three container types: `.rootContainer` (top-level directory listing), per-directory containers (subdirectory listings), and `.workingSet` (recently modified files plus materialized items and their siblings). Both `enumerateItems(for:startingAt:)` and `enumerateChanges(for:from:)` must be implemented. Paginate in batches of 50–100 items to stay within memory limits. The sync anchor is an opaque `Data` blob — encode your monotonic counter.

**Phase 5: Content fetching.** Implement `fetchContents(for:version:request:completionHandler:)` — look up the item's relative path in your database, construct the full path in the shared container, and return that URL. The system clones the file via APFS.

**Phase 6: Mutation handling.** Implement `createItem`, `modifyItem`, `deleteItem`. When Logseq creates or edits a `.md` file, the system calls these methods with a temporary URL containing the new content. Copy/move that content to the correct location in the git working tree, update the metadata database, and return the updated item. For `modifyItem`, check `changedFields` to determine what changed — content changes provide a non-nil `contents` URL; metadata-only changes (rename, move) do not.

**Phase 7: Change signaling.** After the main app completes a `git pull`, diff the working tree against the previous state, update the metadata database with new/changed/deleted items and increment the sync anchor, then call `signalEnumerator(for: .workingSet)`. The system responds by calling `enumerateChanges` on the working set enumerator. Return all changes since the provided sync anchor via `observer.didUpdate([items])` and `observer.didDeleteItems(identifiers:)`.

**Phase 8: App Intents integration.** Expose pull/commit/push as `AppIntent` implementations. After pull completes, signal the enumerator. After Logseq makes edits (which arrive via `modifyItem`/`createItem`), the commit intent reads the working tree state and commits.

**Phase 9: Background refresh.** Register a `BGAppRefreshTask` in the main app to periodically git-fetch. When changes are detected, pull and signal the enumerator. Optionally configure PushKit with the `fileprovider` push type for server-triggered refresh.

---

## Key code patterns for critical operations

### Enumeration with sync anchors

```swift
class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    let db: MetadataDatabase
    
    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        let (items, nextPage) = db.getWorkingSetItems(startingAt: page, limit: 100)
        observer.didEnumerate(items)
        if let nextPage { observer.finishEnumerating(upTo: nextPage) }
        else { observer.finishEnumerating(upTo: nil) }
    }
    
    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from syncAnchor: NSFileProviderSyncAnchor) {
        let anchor = decodeSyncAnchor(syncAnchor)
        let changes = db.getChangesSince(anchor: anchor)
        
        if !changes.updatedItems.isEmpty {
            observer.didUpdate(changes.updatedItems)
        }
        if !changes.deletedIdentifiers.isEmpty {
            observer.didDeleteItems(identifiers: changes.deletedIdentifiers)
        }
        observer.finishEnumeratingChanges(
            upTo: encodeSyncAnchor(changes.newAnchor),
            moreComing: false
        )
    }
    
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(encodeSyncAnchor(db.currentAnchor))
    }
    func invalidate() { /* cleanup */ }
}
```

### Handling Logseq file writes (modifyItem)

```swift
func modifyItem(_ item: NSFileProviderItem,
                baseVersion: NSFileProviderItemVersion,
                changedFields: NSFileProviderItemFields,
                contents newContents: URL?,
                options: NSFileProviderModifyItemOptions,
                request: NSFileProviderRequest,
                completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields,
                                              Bool, Error?) -> Void) -> Progress {
    let progress = Progress(totalUnitCount: 1)
    
    guard let relativePath = db.path(for: item.itemIdentifier) else {
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return progress
    }
    let targetURL = repoRoot.appendingPathComponent(relativePath)
    
    // Handle content change
    if changedFields.contains(.contents), let newContents {
        try? FileManager.default.removeItem(at: targetURL)
        try? FileManager.default.copyItem(at: newContents, to: targetURL)
    }
    
    // Handle rename
    if changedFields.contains(.filename) {
        let newPath = targetURL.deletingLastPathComponent()
            .appendingPathComponent(item.filename)
        try? FileManager.default.moveItem(at: targetURL, to: newPath)
        db.updatePath(for: item.itemIdentifier, newPath: /* relative */)
    }
    
    // Update metadata DB, bump version
    db.updateItem(item.itemIdentifier, modDate: Date())
    let updatedItem = db.fileProviderItem(for: item.itemIdentifier)!
    
    progress.completedUnitCount = 1
    completionHandler(updatedItem, [], false, nil)
    return progress
}
```

### Signaling after git pull

```swift
// In main app, after git pull completes:
func handlePostPull(changedFiles: [String], deletedFiles: [String]) {
    // Update metadata database
    for path in changedFiles {
        db.upsertItem(relativePath: path, modDate: fileModDate(path))
    }
    for path in deletedFiles {
        db.markDeleted(relativePath: path)
    }
    db.incrementSyncAnchor()
    
    // Signal the File Provider to re-enumerate
    guard let manager = NSFileProviderManager(for: domain) else { return }
    manager.signalEnumerator(for: .workingSet) { error in
        if let error { print("Signal failed: \(error)") }
    }
}
```

### Item identifier strategy

```swift
// Generate stable UUIDs on first discovery, persist in SQLite
// Schema: (identifier TEXT PRIMARY KEY, relativePath TEXT, 
//          contentVersion BLOB, metadataVersion BLOB,
//          isDirectory BOOL, parentIdentifier TEXT,
//          modDate REAL, size INTEGER, changeAnchor INTEGER)

func identifierFor(relativePath: String) -> NSFileProviderItemIdentifier {
    if let existing = db.identifier(forPath: relativePath) {
        return existing
    }
    let newID = NSFileProviderItemIdentifier(UUID().uuidString)
    db.insert(identifier: newID, path: relativePath)
    return newID
}
```

---

## Pitfalls, warnings, and their solutions

**The 20 MB memory wall is real and unforgiving.** The extension process receives `EXC_RESOURCE` if it exceeds approximately 20 MB. Never load entire files into memory — stream everything. Never run libgit2/SwiftGit2 in the extension process; opening a repository alone can consume 5–10 MB. Enumerate items in pages of 50–100 to avoid allocating large arrays. Use lightweight structs, not classes with reference cycles.

**`signalEnumerator` only reliably works with `.workingSet`.** Multiple developers confirm that passing specific folder identifiers to `signalEnumerator` is silently ignored. Always signal `.workingSet`. The system calls `enumerateChanges` on the working set enumerator and reconciles from there. Apple's push notification documentation also states that only `NSFileProviderWorkingSetContainerItemIdentifier` is valid in push payloads.

**Do not use `NSFileCoordinator` between the app and extension.** Apple's own TN2408 warned against this, and developers report dropped writes and deadlocks. Use atomic file writes (`Data.write(to:options:.atomic)`) and Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`) for cross-process signaling. Design the system so only one process writes to the git working tree at a time.

**The extension's managed directory is off-limits.** The system owns `~/Library/CloudStorage/yourApp-yourDomain`. Never read or write to this path directly. Return files via completion handlers; the system places them. Violating this causes corruption.

**Silent enumeration failures are maddening.** If your `itemIdentifier`→`parentItemIdentifier` hierarchy has any inconsistency, or if `contentType` is wrong (e.g., returning `.data` for a directory), the entire folder shows blank in Files.app with zero error logging. Validate your hierarchy carefully and log every enumerated item during development.

**`NSFileProviderDomain` construction differs between models.** When using `NSFileProviderReplicatedExtension`, do NOT pass `pathRelativeToDocumentStorage` to the domain constructor — this causes a crash (`beginRequestWithExtensionContext: unrecognized selector`). Use the simple `init(identifier:displayName:)` initializer.

**Development builds confuse the plugin registry.** The system's PlugInKit daemon scans the entire filesystem (including Trash and DerivedData) for extensions and loads the newest one found. If behavior diverges from your code, run `pluginkit -v -m -D -i your.extension.bundle.id` to verify which binary is loaded, and `pluginkit -r <path>` to remove stale entries. This causes hours of "my code isn't running" confusion.

**iOS Simulator support is unreliable for the replicated model.** Apple engineers have confirmed that some File Provider behaviors only work on physical devices. Use the simulator for basic development but always validate on real hardware. The extension may not appear in the simulator's Files app, or enumeration may silently fail.

**The "Duplicate" action in Files app has a bug.** Returning `NSError.fileProviderErrorForCollisionWithItem()` as documented doesn't work correctly. ownCloud's workaround: return a custom error for collisions instead. iOS sometimes calls `trashItem` when it should call `deleteItem` during replace operations — implement `trashItem` to redirect to delete behavior.

**Upload pipeline depth matters for Logseq's write patterns.** Logseq writes many small `.md` files in rapid bursts. The system limits concurrent `modifyItem` calls to the value of `NSExtensionFileProviderUploadPipelineDepth` in Info.plist (default varies, configurable 1–128). Set this to **8–16** to allow reasonable concurrency without overwhelming the extension's memory budget.

---

## What Working Copy reveals about this problem space

Working Copy, the dominant iOS git client by Anders Borum, almost certainly uses the **non-replicated** `NSFileProviderExtension` model. The app predates the replicated API (shipping File Provider support with iOS 11 in 2017), serves files directly from the git working tree without a separate replica, and exposes custom `NSFileProviderServiceSource` services (`WorkingCopyUrlService`) — a pattern associated with the older API. Anders Borum's open-source `open-in-place` sample project on GitHub references the non-replicated API surface.

Working Copy's approach is architecturally simple: the git working tree IS the File Provider's backing store. When an external app edits a file in-place, changes land directly in the working tree and appear as uncommitted modifications in Working Copy's Changes tab. There is no automatic conflict prevention between File Provider writes and concurrent git operations — the working tree can theoretically be modified by both the File Provider and a checkout/merge simultaneously. Working Copy does not perform automatic background git sync; users must manually fetch/pull or automate via Shortcuts. The app's documentation notes that some apps "do not write changes back automatically" and may require a manual save step — suggesting that file coordination across the File Provider boundary is not perfectly reliable for all apps.

A macOS version of Working Copy is in preparation, which will require migrating to `NSFileProviderReplicatedExtension` (macOS only supports the replicated model). This migration path mirrors what your app should do: start with the replicated model from day one to avoid a painful future migration.

---

## Background refresh and sync coordination

The File Provider extension **cannot independently initiate network operations** like git fetch/pull. Background sync must be orchestrated by the main app through three mechanisms:

**`BGTaskScheduler`** is the primary approach. Register `BGAppRefreshTask` or `BGProcessingTask` in the main app's Info.plist. Schedule periodic tasks to run git fetch, and if changes are detected, pull and call `signalEnumerator(for: .workingSet)`. Note that `BGTaskScheduler` tasks submitted by extensions are routed to the main app's handler — so registration must happen in the app, not the extension.

**PushKit with the `fileprovider` push type** enables server-triggered refresh. Send APNs pushes with push-type `fileprovider` and topic `{bundleID}.pushkit.fileprovider`. These wake the File Provider extension directly (without user notification), causing the system to call `enumerateChanges`. This requires a server component that monitors the git remote for changes — feasible if using a self-hosted Gitea/Forgejo or GitHub webhooks.

**App Intents / Shortcuts automation** lets users trigger pull/push manually or on a schedule. After the pull App Intent completes, signal the enumerator. This is the most reliable approach since iOS gives foreground Shortcuts execution generous resource budgets.

**Cross-process signaling between app and extension** uses Darwin notifications for lightweight pings and the shared metadata database for state transfer. When the main app completes a git pull, it writes change records to the shared SQLite database, increments the sync anchor, and signals the enumerator. The extension, when woken by the system, reads the database to determine what changed.

---

## Open-source implementations worth studying

**Apple's FruitBasket sample** (official name: "Synchronizing files using file provider extensions") is the canonical reference for the replicated model. It implements a complete `NSFileProviderReplicatedExtension` with sync anchors, change enumeration, conflict handling, and both iOS and macOS targets. The key architectural pattern — thin extension target plus logic framework — is essential to adopt. Available at `developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions`; a community mirror exists at `github.com/seanses/FileProviderTrial`.

**Cryptomator iOS** (`github.com/cryptomator/ios`) is the most architecturally relevant open-source project. Like this app, it transforms data before serving it through the File Provider (decryption vs. git-tree exposure). Its `FileProviderAdapter` abstraction, framework separation, and domain-per-vault pattern demonstrate production-quality patterns. It uses the non-replicated model but its adapter pattern translates cleanly.

**Nextcloud's experimental "apple-clients" repo** (`github.com/nextcloud/apple-clients`) implements `NSFileProviderReplicatedExtension` with a clean `NextSyncKit` framework separation. Written by Claudio Cambra, whose blog post at `claudiocambra.com/posts/build-file-provider-sync/` is the single best non-Apple technical resource on implementing the replicated model.

**ownCloud iOS** (`github.com/owncloud/ios-app`) contains extensive code comments documenting iOS File Provider quirks — particularly the `trashItem` workaround for the Files app's "Duplicate" bug and bundle document handling. Written in Objective-C but the patterns transfer.

**Nextcloud iOS** (main app, `github.com/nextcloud/ios`) demonstrates real-world non-replicated File Provider at scale, including working set management, background downloads via `NKBackground` sessions, and `signalEnumerator` usage patterns.

---

## Every relevant URL discovered

**Apple documentation:**
- File Provider framework overview: `developer.apple.com/documentation/fileprovider/`
- NSFileProviderReplicatedExtension: `developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension`
- NSFileProviderExtension: `developer.apple.com/documentation/fileprovider/nsfileproviderextension`
- Replicated File Provider topic: `developer.apple.com/documentation/fileprovider/replicated-file-provider-extension`
- Non-replicated File Provider topic: `developer.apple.com/documentation/fileprovider/nonreplicated-file-provider-extension`
- Synchronizing the extension: `developer.apple.com/documentation/fileprovider/replicated_file_provider_extension/synchronizing_the_file_provider_extension`
- NSFileProviderManager: `developer.apple.com/documentation/fileprovider/nsfileprovidermanager`
- NSFileProviderDomain: `developer.apple.com/documentation/fileprovider/nsfileproviderdomain`
- NSFileProviderItemIdentifier: `developer.apple.com/documentation/fileprovider/nsfileprovideritemidentifier`
- NSFileProviderError: `developer.apple.com/documentation/fileprovider/nsfileprovidererror`
- Using push notifications to signal changes: `developer.apple.com/documentation/FileProvider/using-push-notifications-to-signal-changes`
- FruitBasket sample code: `developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions`
- App Extension Programming Guide: `developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/FileProvider.html`

**WWDC sessions and tech talks:**
- WWDC 2017 Session 243 — "File Provider Enhancements": `developer.apple.com/videos/play/wwdc2017/243/`
- WWDC 2018 Session 216 — "Managing Documents In Your iOS Apps": `developer.apple.com/videos/play/wwdc2018/216/`
- WWDC 2019 Session 710 — "What's New in Apple File Systems": `developer.apple.com/videos/play/wwdc2019/710/`
- WWDC 2021 Session 10182 — "Sync files to the cloud with FileProvider on macOS": `developer.apple.com/videos/play/wwdc2021/10182/`
- Tech Talk 10067 — "Bring desktop class sync to iOS with FileProvider": `developer.apple.com/videos/play/tech-talks/10067/`

**Apple Developer Forums (key threads):**
- NSFileProviderReplicatedExtension on iOS (Miguel de Icaza): `developer.apple.com/forums/thread/710116`
- File Provider error -2001: `developer.apple.com/forums/thread/702971`
- olderExtensionVersionRunning (-2003): `developer.apple.com/forums/thread/729541`
- Extension doesn't show items: `developer.apple.com/forums/thread/85004`
- signalEnumerator reparenting bug: `developer.apple.com/forums/thread/100424`
- Working set approach: `developer.apple.com/forums/thread/691540`
- Extension memory limit (20 MB): `developer.apple.com/forums/thread/739839`
- PushKit enumerateChanges not triggering: `developer.apple.com/forums/thread/706004`
- fileproviderd deadlock: `developer.apple.com/forums/thread/715229`
- Invalidating materialized content: `forums.developer.apple.com/forums/thread/712371`
- Extension fails to launch: `developer.apple.com/forums/thread/729740`
- File Provider tag page: `developer.apple.com/forums/tags/fileprovider`

**Open-source repositories:**
- Apple FruitBasket mirror: `github.com/seanses/FileProviderTrial`
- Nextcloud iOS (non-replicated FP): `github.com/nextcloud/ios`
- Nextcloud NextSync (replicated FP): `github.com/nextcloud/apple-clients`
- Cryptomator iOS: `github.com/cryptomator/ios`
- ownCloud iOS: `github.com/owncloud/ios-app`
- Working Copy open-in-place sample: `github.com/palmin/open-in-place`
- LibGit2-On-iOS XCFramework: `github.com/light-tech/LibGit2-On-iOS`
- macOS File Provider example: `github.com/peterthomashorn/macosfileproviderexample`

**Third-party guides and blog posts:**
- Claudio Cambra's comprehensive guide: `claudiocambra.com/posts/build-file-provider-sync/`
- Apriorit macOS File Provider guide: `apriorit.com/dev-blog/730-mac-how-to-work-with-the-file-provider-for-macos`
- Kodeco (Ray Wenderlich) tutorial: `kodeco.com/697468-ios-file-provider-extension-tutorial`

**Working Copy:**
- Website: `workingcopy.app`
- User guide: `workingcopyapp.com/users-guide`
- Anders Borum's GitHub: `github.com/palmin`

---

## Open questions requiring hands-on testing

Several questions cannot be resolved through documentation alone and require building a prototype:

**Does the "Increased Memory Limit" entitlement (`com.apple.developer.kernel.increased-memory-limit`) work for File Provider extensions?** This entitlement raises memory limits for app targets, but it is undocumented whether it applies to extension processes. If it does, it could relax the 20 MB constraint enough to allow lightweight git index reads in the extension.

**How does Logseq specifically interact with File Provider locations?** Logseq on iOS may use `UIDocumentBrowserViewController`, direct file URLs, or its own file access layer. Testing whether Logseq performs file coordination correctly, handles File Provider error codes gracefully, and writes changes back promptly will determine whether additional workarounds are needed.

**What is the actual system behavior for rapid `modifyItem` bursts?** When Logseq saves multiple pages in quick succession (e.g., during a bulk rename or automated operation), does the system coalesce writes, queue them sequentially, or allow concurrent calls up to the pipeline depth? The interaction between Logseq's write patterns and the upload pipeline needs empirical measurement.

**Can `reimportItems(below:)` recover from database corruption?** If the metadata database falls out of sync with the git working tree (e.g., after a hard crash during a pull), `reimportItems(below: .rootContainer)` should trigger a full re-scan. Testing whether this nuclear option works reliably and how long it takes for a typical Logseq knowledge base (hundreds to thousands of `.md` files) is essential for disaster recovery planning.

**What happens during concurrent access — main app doing `git checkout` while extension serves files?** Branch switching replaces many files atomically from git's perspective but non-atomically from the filesystem's perspective. Whether the extension can serve partially-switched state and how the system handles resulting inconsistencies needs testing with concurrent access scenarios.

**Is there a meaningful performance difference between the non-replicated and replicated models for the all-local-files case?** While the replicated model is the recommended path, the non-replicated model avoids the storage duplication (system replica) and the bridging complexity. A prototype of each model, benchmarked with a real Logseq knowledge base of 1,000+ files, would quantify whether the replicated model's overhead is acceptable.