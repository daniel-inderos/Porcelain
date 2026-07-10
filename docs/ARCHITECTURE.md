# Architecture

Porcelain uses a small MVVM architecture with a strict boundary around Git execution.

## Targets

- `Porcelain`: SwiftUI macOS executable target. Owns views, view models, menus, sheets, file dialogs, Finder integration, browser opening, and pasteboard actions.
- `PorcelainCore`: Testable library target. Owns Git models, parsing, `GitService`, recent repository persistence, Keychain storage, GitHub link generation, and file watching.
- `PorcelainTests`: Deterministic app-layer tests for view-model concurrency, stale-response suppression, activity state, and diagnostics.
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
- `worktrees(in:)`
- `addWorktree(at:branch:createBranch:in:)`
- `removeWorktree(at:force:in:)`
- `pruneWorktrees(in:)`
- `changeSummary(forWorktreeAt:)`
- `fetch(in:)`, `pull(in:)`, `push(in:setUpstreamBranch:)`
- `history(in:limit:)`
- `remotes(in:)`

Internally, `GitService` launches `/usr/bin/env git` in a detached task, disables terminal prompts with `GIT_TERMINAL_PROMPT=0`, captures stdout/stderr with command-specific byte limits, and returns structured results or friendly errors. Parser-critical output uses an explicit full-capture path, while large diffs and ordinary command output are drained without being retained beyond their limits.

If a GitHub token is stored in Keychain, GitService exposes it only to operations whose resolved remote is exact HTTPS `github.com`, through a host-restricted temporary `GIT_ASKPASS` helper; the helper script does not contain the token. Configured top-level remotes are fetched separately so a mixed remote set does not share one authentication environment. Local-only Git commands never receive Porcelain's authentication environment.

Git hooks installed for authenticated network commands remain enabled to preserve native Git behavior and are treated as trusted local code.

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
- worktree list and per-worktree summaries
- commit form state
- raw Git output and user-facing alerts

Views are intentionally thin. They render state, collect user input, confirm destructive actions, and call view model methods.

Selection and refresh work is owned by `RepositoryViewModel`. Replaced tasks are cancelled and request identities are checked before publishing state, so a slow earlier response cannot overwrite a newer selection or refresh. Activity messages use independent tokens so overlapping operations cannot clear each other's progress state.

## Worktrees

`GitWorktree` represents one entry from `git worktree list --porcelain -z`. `WorktreeChangeSummary` is the card-level summary for a worktree: status counts, staged/untracked/conflicted counts, insertions and deletions from shortstat, ahead/behind state, branch name, and the latest commit when available.

`RepositoryViewModel` loads worktree summaries concurrently with a task group. Each summary is isolated with `try?`, so a failed summary for one worktree leaves that worktree with an unavailable status instead of failing the whole list. Bare and prunable worktrees are listed without summary loading. Because each summary costs several Git invocations, summaries load only while the Worktrees tab is visible: entering the tab triggers a refresh, repository state loads include worktrees only on that tab, and overlapping refreshes are skipped.

The in-place review flow uses a second `RepositoryViewModel` rooted at the selected worktree path. `WorktreesView` owns that review session lifecycle and embeds `WorktreeReviewView`, which reuses `ChangesView` against the worktree model. The parent worktree list refreshes when the user returns from a review, so commits, staging, and discards made during the review are reflected on the cards.

Cross-worktree comparison first builds the visible file set for each side, compares regular files with bounded streaming reads, and snapshots only changed candidates. Symlinks are compared without following their targets, ignored files remain excluded independently per worktree, and per-file diffs use literal pathspecs limited to the requested paths.

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
