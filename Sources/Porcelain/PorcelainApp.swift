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
        }
    }
}

extension Notification.Name {
    static let showCloneSheet = Notification.Name("app.porcelain.showCloneSheet")
}

