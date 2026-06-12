# Porcelain

Porcelain is a lightweight native macOS Git client built with Swift and SwiftUI. It is intended as a fast, calm alternative to GitHub Desktop for everyday Git work: open or clone repositories, review changes, stage files, commit, switch branches, inspect history, manage remotes, and sync with upstreams.

Porcelain is an MVP. It focuses on common workflows and keeps Git operations centralized through `GitService`, which runs the system `git` executable asynchronously.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer, or the Swift toolchain included with Xcode
- Git available through the system path

## Build

```sh
swift build
```

Run tests:

```sh
swift test
```

Run the app from SwiftPM:

```sh
swift run Porcelain
```

Create a local clickable app bundle:

```sh
./scripts/make_app_bundle.sh
open .build/Porcelain.app
```

You can also open the package in Xcode and run the `Porcelain` executable target.

## MVP Features

- First-launch empty state for opening, cloning, or initializing a repository
- Recent repository sidebar with search and local persistence
- Toolbar with current repository, branch picker, refresh, fetch, pull, push, and settings
- Changes view with staged, unstaged, untracked, renamed, deleted, binary, large, and conflicted file handling
- Unified and side-by-side diff rendering
- Stage, unstage, discard with confirmation, and commit with validation
- Branch list with checkout, create, rename, safe delete, merge, and ahead/behind state
- History view with commit metadata, changed files, diff, copy hash, and open-on-remote actions
- Remote add/edit/remove plus fetch, pull, push
- GitHub URL helpers for repository, branch, commit, compare, and pull request pages
- Optional GitHub token storage in Keychain
- Debounced repository file watching and async Git execution

## Design Principles

- Native macOS UI and behavior
- No Electron, embedded web runtime, React Native, or large cross-platform framework
- Small dependency surface
- Git calls go through `PorcelainCore/GitService.swift`
- Credentials are stored only in Keychain
- Git work never blocks the main actor

## Project Layout

```text
Sources/
  Porcelain/       SwiftUI app, view models, AppKit integration
  PorcelainCore/   Git service, parsers, models, persistence, Keychain
Tests/
  PorcelainCoreTests/
docs/
  ARCHITECTURE.md
  FEATURE_STATUS.md
```

## License

Porcelain is released under the [MIT License](LICENSE).
