# Contributing

Porcelain is intended to stay native, lightweight, and easy to reason about.

## Development

Build:

```sh
swift build
```

Test:

```sh
swift test
```

Run:

```sh
swift run Porcelain
```

## Guidelines

- Keep Git subprocess calls centralized in `Sources/PorcelainCore/GitService.swift`.
- Do not add Electron, embedded web views, React Native, or large cross-platform UI frameworks.
- Keep view logic in SwiftUI and repository behavior in view models or `PorcelainCore`.
- Add parser tests for new Git output formats.
- Add service tests for behavior that can run safely in temporary repositories.
- Confirm destructive operations in the UI.
- Keep credentials in Keychain only.
- Prefer clear errors with optional raw Git output.

## Pull Requests

Before opening a pull request:

1. Run `swift test`.
2. Confirm the app still launches.
3. Update `docs/FEATURE_STATUS.md` if behavior changes.
4. Keep changes focused and avoid unrelated formatting churn.

