# Architecture

Porcelain uses a small MVVM architecture with a strict boundary around Git execution.

## Targets

- `Porcelain`: SwiftUI macOS executable target. Owns views, view models, menus, sheets, file dialogs, Finder integration, browser opening, and pasteboard actions.
- `PorcelainCore`: Testable library target. Owns Git models, parsing, `GitService`, recent repository persistence, Keychain storage, GitHub link generation, and file watching.
- `PorcelainCoreTests`: Parser and service behavior tests.

## Git Boundary

All Git subprocess work is centralized in `GitService`.

`GitService` is an actor. Public app actions call async methods such as:

- `status(in:)`
- `diff(for:in:staged:)`
- `stage(paths:in:)`
- `unstage(paths:in:)`
- `discard(paths:in:)`
- `commit(summary:description:author:amend:in:)`
- `branches(in:)`
- `fetch(in:)`, `pull(in:)`, `push(in:setUpstreamBranch:)`
- `history(in:limit:)`
- `remotes(in:)`

Internally, `GitService` launches `/usr/bin/env git` in a detached task, disables terminal prompts with `GIT_TERMINAL_PROMPT=0`, captures stdout/stderr, and returns structured results or friendly errors. If a GitHub token is stored in Keychain, GitService exposes it to HTTPS GitHub operations through a temporary `GIT_ASKPASS` helper; the helper script does not contain the token.

## State Flow

`AppViewModel` owns application-level state:

- recent repositories
- selected repository
- clone/open/init flows
- Git availability status

`RepositoryViewModel` owns repository-level state:

- status and selected changes
- diff content
- commits and selected commit files
- branches and remotes
- commit form state
- raw Git output and user-facing alerts

Views are intentionally thin. They render state, collect user input, confirm destructive actions, and call view model methods.

## Persistence

- Recent repositories are stored in `UserDefaults` via `RecentRepositoryStore`.
- GitHub tokens are stored in Keychain via `KeychainStore`.
- No credentials are written to `UserDefaults`, files, or logs.

## File Watching

`RepositoryFileWatcher` watches the repository directory with a dispatch source and debounces refreshes. The watcher only triggers refresh; Git remains authoritative for status and conflict detection.

## Error Handling

`GitError` maps common Git failures to friendly messages:

- missing Git
- invalid repository
- authentication failures
- conflicts and unsafe working tree states
- empty commit summaries
- unsafe paths

Raw Git output remains available through the UI when users need details.
