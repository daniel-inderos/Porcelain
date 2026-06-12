import SwiftUI

@main
struct PorcelainApp: App {
    @StateObject private var appModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootView(appModel: appModel)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Repository...") {
                    appModel.chooseExistingRepository()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Clone Repository...") {
                    NotificationCenter.default.post(name: .showCloneSheet, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("Go") {
                Button("Changes") {
                    appModel.repositoryViewModel?.selectedTab = .changes
                }
                .keyboardShortcut("1", modifiers: [.command])
                .disabled(appModel.repositoryViewModel == nil)

                Button("Worktrees") {
                    appModel.repositoryViewModel?.selectedTab = .worktrees
                }
                .keyboardShortcut("2", modifiers: [.command])
                .disabled(appModel.repositoryViewModel == nil)

                Button("History") {
                    appModel.repositoryViewModel?.selectedTab = .history
                }
                .keyboardShortcut("3", modifiers: [.command])
                .disabled(appModel.repositoryViewModel == nil)

                Button("Branches") {
                    appModel.repositoryViewModel?.selectedTab = .branches
                }
                .keyboardShortcut("4", modifiers: [.command])
                .disabled(appModel.repositoryViewModel == nil)

                Button("Remotes") {
                    appModel.repositoryViewModel?.selectedTab = .remotes
                }
                .keyboardShortcut("5", modifiers: [.command])
                .disabled(appModel.repositoryViewModel == nil)

                Button("Settings") {
                    appModel.repositoryViewModel?.selectedTab = .settings
                }
                .keyboardShortcut("6", modifiers: [.command])
                .disabled(appModel.repositoryViewModel == nil)
            }
        }
    }
}

extension Notification.Name {
    static let showCloneSheet = Notification.Name("app.porcelain.showCloneSheet")
}
