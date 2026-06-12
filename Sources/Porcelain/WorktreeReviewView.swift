import SwiftUI
import PorcelainCore

struct WorktreeReviewView: View {
    let info: WorktreeInfo
    let parentRepositoryURL: URL
    @ObservedObject var viewModel: RepositoryViewModel
    let openWorktree: (URL) -> Void
    let glassNamespace: Namespace.ID
    let onBack: () -> Void

    var body: some View {
        ChangesView(viewModel: viewModel)
            .safeAreaInset(edge: .top) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                viewModel.start()
            }
            .onExitCommand {
                onBack()
            }
            .overlay(alignment: .top) {
                if let message = viewModel.activityMessage {
                    ActivityOverlay(message: message)
                }
            }
            .alert(item: $viewModel.alert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                onBack()
            } label: {
                Label("Back to Worktrees", systemImage: "chevron.left")
            }
            .help("Back to Worktrees")

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(info.worktree.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    WorktreeBadgesView(info: info, currentRepositoryURL: parentRepositoryURL)
                }

                HStack(spacing: 8) {
                    Text(statsText)
                        .foregroundStyle(.secondary)

                    if isClean {
                        Label {
                            Text("All changes committed")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .font(.caption)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button {
                    viewModel.revealWorktreeInFinder(info.worktree)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal in Finder")

                Button {
                    viewModel.openWorktreeInTerminal(info.worktree)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
                .help("Open in Terminal")

                Button {
                    openWorktree(info.worktree.path)
                } label: {
                    Label("Open in Porcelain", systemImage: "arrow.up.forward.app")
                }
                .help("Open in Porcelain")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .glassEffectID(info.id, in: glassNamespace)
    }

    private var statsText: String {
        let changedCount = viewModel.status.changes.count
        let stagedCount = viewModel.stagedChanges.count
        let conflictCount = viewModel.status.conflicts.count
        return "\(changedCount) changed \(changedCount == 1 ? "file" : "files") · \(stagedCount) staged · \(conflictCount) \(conflictCount == 1 ? "conflict" : "conflicts")"
    }

    private var isClean: Bool {
        viewModel.status.changes.isEmpty
    }
}
