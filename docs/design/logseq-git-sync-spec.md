# LogseqGit: Minimal iOS Git Sync for Logseq

## Technical Specification v0.2

---

## 1. Overview

LogseqGit is a minimal iOS app that syncs a Logseq knowledge base between iOS and other devices using git. It exposes the local git working tree to Logseq via a File Provider extension and provides Shortcuts automations for pull/commit/push operations.

### Goals

- Single-graph git sync between iOS Logseq and any number of desktop/server devices
- Zero-friction daily workflow: open Logseq → edits are pulled automatically, leave Logseq → edits are committed and pushed automatically via layered Shortcuts triggers
- No dependency on iCloud, Logseq Sync, or any third-party sync service
- Self-hostable: works with GitHub, Gitea, bare SSH repos, or any standard git remote

### Non-Goals

- Multi-repo support (v1 handles one graph)
- Merge conflict resolution UI (v1 uses a last-write-wins strategy with automatic conflict commits; manual resolution via desktop)
- Branch management, diff viewing, or any general-purpose git UI
- Real-time sync (sync is event-driven: on app open, on app backgrounding/close, on manual trigger)
- Collaboration / multi-user concurrent editing

---

## 2. Architecture

```
┌─────────────────────────────────────────────────┐
│                  iOS Device                     │
│                                                 │
│  ┌──────────────┐       ┌────────────────────┐  │
│  │              │       │   File Provider     │  │
│  │  LogseqGit   │◄─────►│   Extension         │  │
│  │  (Main App)  │       │                    │  │
│  │              │       │  Exposes working   │  │
│  └──────┬───────┘       │  tree to Logseq    │  │
│         │               └────────┬───────────┘  │
│         │                        │              │
│         ▼                        ▼              │
│  ┌──────────────┐       ┌────────────────────┐  │
│  │  SwiftGit2   │       │     Logseq iOS     │  │
│  │  (libgit2)   │       │   (reads/writes    │  │
│  │              │       │    .md files)       │  │
│  └──────┬───────┘       └────────────────────┘  │
│         │                                       │
│  ┌──────┴───────┐       ┌────────────────────┐  │
│  │  Local Repo  │       │   App Intents      │  │
│  │  (Shared     │◄─────►│   (Shortcuts       │  │
│  │   Container) │       │    automation)     │  │
│  └──────┬───────┘       └────────────────────┘  │
│         │                                       │
└─────────┼───────────────────────────────────────┘
          │ SSH / HTTPS
          ▼
   ┌──────────────┐
   │  Git Remote   │
   │  (GitHub /    │
   │   Gitea /     │
   │   bare repo)  │
   └──────────────┘
```

### Shared App Group Container

The main app and the File Provider extension share data via an App Group container. The git repository clone lives in this shared container so both processes can access the working tree.

---

## 3. Components

### 3.1 Git Engine

**Library:** SwiftGit2 (wraps libgit2)

**Operations:**

| Operation | Trigger | Behavior |
|-----------|---------|----------|
| Clone | Initial setup | Clone remote repo into shared container. Checkout default branch. |
| Pull | App open, Shortcuts intent, manual | Fetch + fast-forward merge. If fast-forward fails, see conflict strategy below. |
| Commit | Pre-push, debounced from File Provider writes | Stage all changes (`git add -A`), commit with auto-generated message including timestamp and device name. |
| Push | App backgrounded (primary), app closed (secondary), BGTask (safety net), Shortcuts intent, manual | Commit any pending changes, then push to remote. |
| Status | UI display, pre-pull/push checks | Return list of modified/added/deleted files relative to HEAD. |

**Conflict Strategy (v1):**

When a pull cannot fast-forward (diverged histories), the app:

1. Stashes any local uncommitted changes
2. Attempts a merge with `theirs` strategy for `.md` files (remote wins for content, preserving local-only new files)
3. If merge succeeds, commits the merge and pops the stash
4. If merge fails, aborts the merge, creates a `CONFLICT-{timestamp}` branch from the current state, resets to remote HEAD, and notifies the user

Rationale: Logseq files are individual markdown pages. In a single-user workflow, true conflicts (same file edited on two devices without syncing in between) are rare. When they occur, preserving both versions on separate branches lets the user resolve on desktop with proper tooling.

**Authentication:**

| Method | Implementation |
|--------|---------------|
| SSH key (ed25519, ecdsa, rsa) | Imported from external source (e.g., Bitwarden, clipboard, Files). Stored in iOS Keychain via the app's keychain access group. Passed to libgit2 via SwiftGit2's credential callback. |
| HTTPS + PAT | Personal access token stored in Keychain. Passed via libgit2 credential callback. |
| HTTPS + OAuth | Out of scope for v1. |

### 3.2 File Provider Extension

**Purpose:** Expose the git working tree as a browsable directory in the iOS Files app, allowing Logseq to open the graph folder directly.

**How This Solves the iOS Sandbox Problem:**

iOS normally restricts apps to reading/writing files within their own sandboxed container or iCloud. Logseq cannot open arbitrary directories on the filesystem — it can only browse locations surfaced through the iOS document picker (`UIDocumentPickerViewController`). The File Provider API is Apple's official mechanism for one app to expose files to other apps through this picker. When LogseqGit registers a File Provider extension, its repo working tree appears as a browsable location in the document picker alongside iCloud Drive, "On My iPhone," etc. Logseq uses this picker when adding a graph, so it sees the LogseqGit directory and can read/write `.md` files directly through it. No special cooperation from Logseq is needed.

**Important:** Logseq must open the folder with "open" access (not "import," which would copy files into Logseq's own sandbox and break bidirectional sync). Working Copy's established use as a Logseq sync tool confirms Logseq uses the correct access mode, but this should be verified during initial prototyping.

**Model:** To be determined by research (see research prompt), but the likely choice is:

- **Replicated extension** (`NSFileProviderReplicatedExtension`, iOS 16+) if Apple has deprecated the non-replicated API, or if the replicated model handles local-only files cleanly
- **Non-replicated extension** (`NSFileProviderExtension`) if it maps more naturally to "files already on disk" without the overhead of the replicated model's upload/download lifecycle

**Key Behaviors:**

**Enumeration:**
- The extension enumerates the git working tree directory recursively
- Each file/directory maps to an `NSFileProviderItem` with a stable identifier derived from its relative path within the repo
- `.git/` directory and patterns from `.gitignore` are excluded from enumeration
- The `logseq/bak/` and `logseq/.recycle/` directories are excluded

**Handling Writes from Logseq:**
- When Logseq creates or modifies a `.md` file, the File Provider extension receives the write via its mutation methods
- The extension writes the file to the git working tree in the shared container
- The extension does NOT auto-commit — it only updates the working tree
- Commits happen on explicit trigger (Shortcuts automation, manual, or app lifecycle)

**Signaling Changes After Git Pull:**
- After a `git pull` that modifies the working tree, the main app calls `NSFileProviderManager.signalEnumerator(for:)` to notify the system that items have changed
- The extension re-enumerates changed items so Logseq picks up the new content
- This is the most latency-sensitive path — Logseq needs to see updated files immediately after a pull

**Domain Configuration:**
- Single `NSFileProviderDomain` representing the one synced graph
- Domain display name is the graph/repo name (user-configurable)

**Item Identifier Strategy:**
- Root item: `NSFileProviderItemIdentifier.rootContainer`
- All other items: relative path from repo root, URL-encoded (e.g., `pages%2FProject%20Ideas.md`)
- If research reveals that path-based identifiers are fragile across renames, switch to a persistent UUID mapping stored in a SQLite database in the shared container

### 3.3 App Intents (Shortcuts Integration)

Three intents, each exposed as an App Intent for use in iOS Shortcuts automations:

**PullIntent**
- Display name: "Pull Logseq Graph"
- Parameters: none
- Behavior: fetch + pull from remote
- Returns: summary string (e.g., "Pulled 3 updated files" or "Already up to date")
- Error cases: no network, auth failure, merge conflict

**CommitAndPushIntent**
- Display name: "Push Logseq Graph"
- Parameters: optional commit message (defaults to "Auto-sync from {device name} at {timestamp}")
- Behavior: stage all → commit → push
- Returns: summary string (e.g., "Pushed 5 changes")
- Error cases: no network, auth failure, nothing to commit (this is not an error — return "No changes to push")

**SyncStatusIntent**
- Display name: "Logseq Sync Status"
- Parameters: none
- Behavior: check for uncommitted local changes and unpulled remote changes
- Returns: summary string (e.g., "3 local changes, remote is 2 commits ahead")

**Recommended Shortcuts Automations (documented for user):**

| Automation | Trigger | Actions | Role |
|------------|---------|---------|------|
| Pull on Open | Personal Automation → App → Logseq → Is Opened | Commit any local changes (safety), then run "Pull Logseq Graph" | Primary pull trigger. The pre-pull commit captures any state from a previous session where the push may have failed. |
| Push on Background | Personal Automation → App → Logseq → Is No Longer In Foreground | Run "Push Logseq Graph" | **Primary push trigger.** Fires when the user switches away from Logseq, which is far more reliable than waiting for iOS to terminate the app. |
| Push on Close | Personal Automation → App → Logseq → Is Closed | Run "Push Logseq Graph" | Secondary push trigger. Catches the case where Logseq is terminated without going through background first (e.g., force-quit). |

**Additional Push Reliability Layers (implemented in-app, not via Shortcuts):**

| Mechanism | Behavior | Role |
|-----------|----------|------|
| Debounced commit from File Provider | When the File Provider extension detects no write activity for 60 seconds after the last Logseq write, it posts a notification to the main app to commit (but not push) pending changes. | Ensures local changes are committed even if no Shortcuts automation fires. Reduces data loss window. |
| BGAppRefreshTask | A `BGAppRefreshTask` registered with `BGTaskScheduler` that checks for uncommitted changes, commits, and pushes. iOS schedules this opportunistically (not predictable timing). | Safety net. Catches any changes that slipped through all other triggers. Budget ~30 seconds of execution. |

### 3.4 SSH Key Management

**Import (primary flow — no in-app key generation):**

Keys are generated and managed externally (e.g., in Bitwarden, on a desktop machine, etc.) and imported into LogseqGit. This keeps key management centralized in the user's existing workflow.

- **Paste from clipboard** — copy private key from password manager, paste into a text field in the app. This is the primary import method.
- **Import from Files** — pick a key file (`.pem`, `id_ed25519`, etc.) via the iOS document picker, for cases where the key is saved in Files, AirDropped, or shared from another app.

On import, the app:
1. Validates the key format (ed25519, ecdsa, or rsa)
2. Stores the private key in the iOS Keychain with appropriate access control (accessible when device is unlocked)
3. Derives and displays the public key in a read-only view with a copy button (useful for quick reference when adding the key to a new Gitea instance without opening Bitwarden)

**Supported key types:** ed25519 (preferred), ecdsa, rsa

**Known Hosts:**
- On first connection, prompt user to verify the remote host's fingerprint
- Store accepted fingerprints in the shared container
- Alternatively, for v1 simplicity, auto-accept on first connection with a warning (common in mobile git clients)

### 3.5 UI

Minimal single-screen interface. The app is primarily a background service; users interact with it during setup and for occasional status checks.

**Setup Flow (first launch):**

1. Configure remote URL (text field)
2. Configure authentication (import SSH key from clipboard/Files, or enter HTTPS PAT)
3. Clone repository (progress indicator)
4. Name the graph / File Provider domain
5. Instructions screen: "Open Logseq → Add Graph → Browse → Select {graph name} from File Provider"
6. Instructions screen: "Set up Shortcuts automations" (with deep links or step-by-step screenshots)

**Main Screen (post-setup):**

```
┌─────────────────────────────┐
│  LogseqGit                  │
├─────────────────────────────┤
│                             │
│  Graph: my-knowledge-base   │
│  Remote: git@github.com:... │
│  Last sync: 2 minutes ago   │
│  Status: 3 local changes    │
│                             │
│  ┌─────────┐  ┌──────────┐  │
│  │  Pull   │  │   Push   │  │
│  └─────────┘  └──────────┘  │
│                             │
│  ┌─────────────────────────┐│
│  │      Sync Now           ││
│  └─────────────────────────┘│
│                             │
│  Recent Activity            │
│  • Pulled 3 files (2m ago)  │
│  • Pushed 1 file (1h ago)   │
│  • Pulled 0 files (1h ago)  │
│                             │
│  ⚙️ Settings                │
└─────────────────────────────┘
```

**Settings Screen:**

- Remote URL (editable)
- Authentication method and key management
- Graph name
- Auto-commit message template
- SSH known hosts
- Reset / re-clone graph
- Export logs (for debugging)

---

## 4. Data Model

### Shared Container Layout

```
/AppGroup/group.com.logseqgit/
├── repo/                    # Git working tree (this is what File Provider exposes)
│   ├── .git/
│   ├── pages/
│   ├── journals/
│   ├── logseq/
│   │   ├── config.edn
│   │   └── ...
│   └── ...
├── config.json              # App configuration
├── known_hosts              # SSH known hosts
├── sync.log                 # Recent sync activity log
└── fileprovider.sqlite      # (if needed) Item identifier mapping for File Provider
```

### config.json

```json
{
  "remote_url": "git@github.com:user/logseq-graph.git",
  "auth_method": "ssh",
  "ssh_key_ref": "keychain://logseqgit-ed25519",
  "branch": "main",
  "graph_name": "my-knowledge-base",
  "commit_message_template": "Auto-sync from {{device}} at {{timestamp}}",
  "last_pull": "2025-12-01T10:30:00Z",
  "last_push": "2025-12-01T10:30:05Z"
}
```

---

## 5. Excluded Files

The following patterns are excluded from git tracking (committed as `.gitignore` in the repo) and from File Provider enumeration:

```
logseq/bak/
logseq/.recycle/
logseq/.git-temp/
.DS_Store
*.DS_Store
.Spotlight-V100
.Trashes
```

---

## 6. Error Handling

| Scenario | Behavior |
|----------|----------|
| No network on pull/push | Return error to Shortcuts / show in UI. Do not block Logseq usage — the local working tree is always usable. |
| Auth failure | Surface error with actionable message ("SSH key not accepted — check that your public key is added to the remote"). |
| Merge conflict | Follow conflict strategy from §3.1. Notify user via local notification. |
| File Provider extension crashes | iOS will restart it automatically. The working tree on disk is unaffected. |
| Shared container disk space low | Check available space before clone/pull. Warn user if below 100MB. |
| Corrupt git state | Offer "Reset & Re-clone" in settings as the nuclear option. |

---

## 7. Platform Requirements

- **Minimum iOS version:** 16.0 (for modern File Provider APIs and App Intents framework)
- **Swift version:** 5.9+
- **Dependencies:**
  - SwiftGit2 (libgit2 bindings) — via Swift Package Manager
  - No other external dependencies for v1
- **Entitlements:**
  - App Groups (shared container between app and extension)
  - File Provider (for the extension)
  - Keychain Sharing (for SSH key access from both app and extension)
  - Background Modes → Background fetch (for `BGAppRefreshTask`)
  - Network (outbound SSH/HTTPS)

---

## 8. Project Structure

```
LogseqGit/
├── LogseqGit/                     # Main app target
│   ├── App.swift
│   ├── Views/
│   │   ├── SetupFlow/
│   │   │   ├── RemoteConfigView.swift
│   │   │   ├── AuthConfigView.swift
│   │   │   ├── CloneProgressView.swift
│   │   │   └── InstructionsView.swift
│   │   ├── MainView.swift
│   │   └── SettingsView.swift
│   ├── Services/
│   │   ├── GitService.swift        # Wraps SwiftGit2 operations
│   │   ├── KeychainService.swift   # SSH key import/storage/retrieval
│   │   ├── ConfigService.swift     # Read/write config.json
│   │   ├── BackgroundSyncService.swift  # BGTaskScheduler registration and handling
│   │   └── SyncLogger.swift        # Activity log
│   └── Intents/
│       ├── PullIntent.swift
│       ├── CommitAndPushIntent.swift
│       └── SyncStatusIntent.swift
├── FileProviderExtension/          # File Provider extension target
│   ├── FileProviderExtension.swift # Main extension class
│   ├── FileProviderItem.swift      # NSFileProviderItem implementation
│   ├── FileProviderEnumerator.swift
│   ├── WriteActivityMonitor.swift  # Debounced commit trigger on write inactivity
│   └── Info.plist
├── Shared/                         # Code shared between app and extension
│   ├── RepoManager.swift           # Shared repo path/state access
│   └── Constants.swift
└── Package.swift / project config
```

---

## 9. Testing Strategy

**Unit Tests:**
- GitService: clone, pull, commit, push against a local bare repo (no network needed)
- Conflict resolution logic
- Config serialization
- Item identifier generation and stability

**Integration Tests:**
- File Provider enumeration against a real repo checkout
- End-to-end: write file via File Provider → verify it appears in working tree → commit → verify commit exists
- Pull with file changes → verify File Provider signals enumeration → verify updated items

**Manual Test Script (pre-release checklist):**
1. Fresh install → setup flow → clone repo (importing SSH key from clipboard)
2. Open Logseq → verify graph loads from File Provider
3. Create a new page in Logseq → verify file appears in working tree
4. Trigger push (via Shortcuts or manual) → verify commit appears on remote
5. Edit a file on desktop → push to remote → trigger pull on iOS → verify Logseq shows updated content
6. Airplane mode → edit in Logseq → verify local changes persist → restore network → push
7. Edit same file on desktop and iOS without syncing → trigger pull → verify conflict branch created
8. Edit in Logseq → switch to another app (background trigger) → verify commit + push happens automatically
9. Edit in Logseq → wait 60+ seconds idle → verify debounced local commit occurs (without push)
10. Edit in Logseq → kill all Shortcuts automations → wait for BGTask to fire → verify eventual push

---

## 10. Future Considerations (Out of Scope for v1)

- **Multi-repo support:** Multiple File Provider domains, repo switcher UI
- **Proactive background sync:** Extend `BGTaskScheduler` usage to also pull remote changes and signal the File Provider, not just push local changes
- **Conflict resolution UI:** In-app diff viewer for `.md` files with side-by-side comparison
- **Encryption:** git-crypt or similar for at-rest encryption of the repo
- **Logseq-aware merge:** Custom merge driver that understands Logseq's block-level structure to do smarter conflict resolution than line-level git merge
- **Widget:** Home screen widget showing sync status and last sync time
- **Push notifications:** Webhook-triggered notifications when the remote repo is updated (for Gitea/GitHub webhook → push notification service)
