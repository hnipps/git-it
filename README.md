# Git It

Git-based sync for [Logseq](https://logseq.com) on iOS. Clone your graph from any git remote into a Logseq-accessible Files folder, then let Git It handle pull, commit, and push in the background.

## Features

- **One-tap sync** -- pull, commit, and push from a single button
- **Logseq folder mode** -- pick a folder inside Files > Logseq so Logseq and Git It read/write the same graph
- **Background sync** -- periodic background refresh keeps your graph up to date
- **Shortcuts / App Intents** -- automate pull, commit & push, and status checks from the Shortcuts app or Siri
- **SSH and HTTPS auth** -- works with GitHub, Gitea, bare SSH repos, or any standard git remote
- **Conflict-safe** -- on divergence, local changes are saved to a side branch so nothing is lost

## Requirements

| Tool | Version |
|------|---------|
| macOS | 13+ |
| Xcode | 15.0+ |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 2.38+ |
| iOS device | 16.0+ |
| Apple Developer account | Free or paid (paid required for File Provider) |

## Getting Started

### 1. Install XcodeGen

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project from `project.yml`. Install it with Homebrew:

```bash
brew install xcodegen
```

### 2. Clone the repo

```bash
git clone https://github.com/hnipps/git-it.git
cd git-it
```

### 3. Generate the Xcode project

```bash
xcodegen generate
```

This reads `project.yml` and produces `LogseqGit.xcodeproj`. Re-run this command any time you change `project.yml`.

### 4. Open in Xcode

```bash
open LogseqGit.xcodeproj
```

### 5. Configure signing

1. Select the **LogseqGit** project in the navigator.
2. For each target (**LogseqGit**, **LogseqGitTests**, **FileProviderExtension**):
   - Go to **Signing & Capabilities**.
   - Select your Team.
   - Change the Bundle Identifier to something unique (e.g. replace `com.logseqgit` with your own prefix).
3. Under **Signing & Capabilities**, add the following capabilities to the **LogseqGit** target if they aren't already present:
   - **App Groups** -- use the identifier `group.com.logseqgit` (or match your bundle ID prefix).
   - **Keychain Sharing** -- use `com.logseqgit.shared` (or match your prefix).
4. Add the same **App Groups** capability to the **FileProviderExtension** target with the same group identifier.

> **Note:** The App Group identifier in Xcode must match the value of `Constants.appGroupID` in `Shared/Constants.swift`. If you change one, update the other.

### 6. Build and run on your iPhone

1. Connect your iPhone via USB (or use wireless debugging if already set up).
2. Select your device from the run destination dropdown in Xcode.
3. Press **Cmd+R** to build and run.
4. If this is your first time deploying to the device, you may need to trust the developer certificate on your phone: **Settings > General > VPN & Device Management** and tap Trust.

## Usage

### Initial setup

When you first launch Git It, a setup wizard walks you through:

1. **Remote URL** -- enter your git repo URL (SSH or HTTPS).
2. **Authentication** -- paste an SSH private key or a personal access token.
3. **Graph Folder** -- choose a folder inside **Files > Logseq**.
4. **Clone** -- the app clones the repo into that selected folder.
5. **Instructions** -- brief guide on opening that folder in Logseq iOS.

### Day-to-day workflow

- Open Git It and tap **Sync Now** to pull remote changes, commit any local edits, and push -- all in one step.
- Use the individual **Pull** and **Push** buttons for finer control.
- The status indicator shows sync state at a glance: green (up to date), yellow (local changes), blue (syncing), red (error).
- Background sync runs approximately every 15 minutes when the system allows.

### Shortcuts automation

Git It exposes three App Intents you can use in the Shortcuts app:

| Shortcut | What it does |
|----------|-------------|
| **Pull Logseq Graph** | Fetches and fast-forwards from the remote |
| **Push Logseq Graph** | Commits all changes and pushes (accepts an optional commit message) |
| **Logseq Sync Status** | Returns the current sync status as a string |

Combine these with Shortcuts automations (e.g. "When I open Logseq, run Pull") for hands-free sync.

## Project Structure

```
.
├── project.yml                  # XcodeGen project definition
├── LogseqGit/                   # Main app target
│   ├── App.swift                # App entry point and bootstrap
│   ├── Views/                   # SwiftUI views (MainView, SettingsView, SetupFlow)
│   ├── Services/                # GitService, BackgroundSyncService, KeychainService, etc.
│   └── Intents/                 # App Intents for Shortcuts integration
├── FileProviderExtension/       # File Provider extension (exposes repo to Logseq)
├── Shared/                      # Code shared between the app and extension
│   ├── Constants.swift          # App Group IDs, paths, notification names
│   ├── AppConfig.swift          # Persisted configuration model
│   ├── ConfigService.swift      # Read/write config from shared container
│   ├── RepoManager.swift        # Repository path and clone-state helpers
│   └── MetadataDatabase.swift   # SQLite metadata for the File Provider
└── LogseqGitTests/              # Unit and integration tests
```

## Running Tests

```bash
xcodegen generate
xcodebuild test \
  -project LogseqGit.xcodeproj \
  -scheme LogseqGit \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## License

This project is not yet published under a license. All rights reserved.
