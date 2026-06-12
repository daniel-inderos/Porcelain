# Feature Status

Status values:

- Done: implemented in the MVP
- Partial: implemented with known scope limits
- Later: intentionally out of v1 scope

| Area | Status | Notes |
| --- | --- | --- |
| Native SwiftUI macOS app | Done | Swift Package executable target using SwiftUI and AppKit where needed |
| Recent repositories | Done | Stored locally with `UserDefaults` |
| Open existing repository | Done | Uses `NSOpenPanel` and validates with Git |
| Clone repository by URL | Done | Supports public/private URLs as accepted by system Git |
| Initialize repository | Done | Creates folder if needed and runs `git init` |
| Centralized Git service | Done | `GitService` actor is the subprocess boundary |
| Missing Git handling | Done | Validates `git --version` on launch |
| Status and dirty state | Done | Parses porcelain status and watches the repository directory |
| Stage/unstage | Done | Per-file and all-files actions |
| Discard changes | Done | Confirmation in UI; tracked restore and untracked removal |
| Commit | Done | Summary validation, description, author display, amend toggle |
| Unified diff | Done | Additions/deletions highlighted |
| Side-by-side diff | Done | Lightweight side-by-side rendering |
| Binary and large diffs | Done | Summarized or truncated |
| File actions | Done | Open, reveal in Finder, copy path |
| Conflict detection | Done | Porcelain unmerged states show banner and file markers |
| Branch list | Done | Current branch and tracking summary |
| Branch create/checkout/rename/delete | Done | Delete uses safe `git branch -d` by default |
| Branch merge | Done | Uses no-fast-forward merge and reports conflicts |
| Fetch/pull/push | Done | Uses system Git and shows raw output/errors; push sets the upstream automatically when the branch has none |
| Remotes | Done | Add, edit URL, remove, list fetch/push URLs |
| History | Done | Commit list, changed files, commit diff |
| GitHub links | Done | Repo, branch, commit, compare, new PR URL helpers |
| GitHub token storage | Done | Stored in Keychain and used through a token-free `GIT_ASKPASS` helper for HTTPS GitHub operations |
| Full PR review/commenting | Later | Explicitly out of v1 scope |
| Advanced rebase/cherry-pick/stash | Later | Not part of MVP |
