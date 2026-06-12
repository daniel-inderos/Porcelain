import SwiftUI
import PorcelainCore

struct WorktreeReviewView: View {
    let info: WorktreeInfo
    let parentRepositoryURL: URL
    @ObservedObject var viewModel: RepositoryViewModel
    let openWorktree: (URL) -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ChangesView(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            viewModel.start()
        }
        .overlay(alignment: .top) {
            activityOverlay
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

                Text(statsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statsText: String {
        let changedCount = viewModel.status.changes.count
        let stagedCount = viewModel.stagedChanges.count
        let conflictCount = viewModel.status.conflicts.count
        return "\(changedCount) changed \(changedCount == 1 ? "file" : "files") · \(stagedCount) staged · \(conflictCount) \(conflictCount == 1 ? "conflict" : "conflicts")"
    }

    @ViewBuilder
    private var activityOverlay: some View {
        if let message = viewModel.activityMessage {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 10, y: 4)
            .padding(.top, 10)
        }
    }
}
