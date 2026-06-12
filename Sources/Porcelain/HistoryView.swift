import SwiftUI
import PorcelainCore

struct HistoryView: View {
    @ObservedObject var viewModel: RepositoryViewModel
    @State private var diffMode: DiffMode = .unified

    var body: some View {
        // Same fit guarantee as ChangesView: width-scaled caps on the side
        // panes and a pinned ideal on the diff pane keep HSplitView from
        // overflowing the window.
        GeometryReader { proxy in
            let width = proxy.size.width
            HSplitView {
                CommitListView(viewModel: viewModel)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: max(280, min(460, width * 0.34)))

                CommitFileListView(viewModel: viewModel)
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: max(200, min(340, width * 0.24)))

                DiffPanelView(diff: viewModel.commitDiff, mode: $diffMode)
                    .frame(minWidth: 340, idealWidth: 460, maxWidth: .infinity)
            }
        }
    }
}

private struct CommitListView: View {
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        Group {
            if viewModel.commits.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No commits yet")
                        .font(.headline)
                    Text("History appears after the first commit.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selection) {
                    ForEach(viewModel.commits) { commit in
                        CommitRow(commit: commit)
                            .tag(commit.id)
                            .contextMenu {
                                Button("Copy Hash") { viewModel.copyCommitHash(commit) }
                                Button("Open on GitHub") { viewModel.openCommitOnRemote(commit) }
                            }
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            header
        }
    }

    private var header: some View {
        HStack {
            Text("History")
                .font(.headline)
            Spacer()
            Button {
                viewModel.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .help("Refresh history")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var selection: Binding<GitCommit.ID?> {
        Binding {
            viewModel.selectedCommit?.id
        } set: { commitID in
            guard
                let commitID,
                let commit = viewModel.commits.first(where: { $0.id == commitID })
            else { return }
            Task {
                await viewModel.selectCommit(commit)
            }
        }
    }
}

private struct CommitRow: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(commit.subject.isEmpty ? "(no subject)" : commit.subject)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(commit.shortHash)
                    .font(.system(.caption, design: .monospaced))
                Text(commit.authorName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text(formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 9)
    }

    private var formattedDate: String {
        guard let date = commit.date else { return "" }
        return date.formatted(.relative(presentation: .named))
    }
}

private struct CommitFileListView: View {
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        List(selection: selection) {
            if let commit = viewModel.selectedCommit {
                Section {
                    CommitDetailsBlock(commit: commit)
                }
            }

            Section {
                FullCommitDiffRow()
                    .tag(CommitFileSelectionKey.fullDiff)

                ForEach(viewModel.commitFiles) { file in
                    CommitFileRow(file: file)
                        .tag(CommitFileSelectionKey.file(file.id))
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaInset(edge: .top, spacing: 0) {
            header
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Commit")
                    .font(.headline)
                if let commit = viewModel.selectedCommit {
                    Text(commit.shortHash)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let commit = viewModel.selectedCommit {
                Menu {
                    Button("Copy Hash") { viewModel.copyCommitHash(commit) }
                    Button("Open on GitHub") { viewModel.openCommitOnRemote(commit) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var selection: Binding<CommitFileSelectionKey?> {
        Binding {
            guard viewModel.selectedCommit != nil else { return nil }
            guard let selectedFile = viewModel.selectedCommitFile else { return .fullDiff }
            return .file(selectedFile.id)
        } set: { key in
            guard let key else { return }
            switch key {
            case .fullDiff:
                Task {
                    await viewModel.selectCommitFile(nil)
                }
            case .file(let fileID):
                guard let file = viewModel.commitFiles.first(where: { $0.id == fileID }) else { return }
                Task {
                    await viewModel.selectCommitFile(file)
                }
            }
        }
    }
}

private enum CommitFileSelectionKey: Hashable {
    case fullDiff
    case file(GitCommitFile.ID)
}

private struct CommitDetailsBlock: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(commit.subject)
                .font(.callout.weight(.medium))
                .lineLimit(3)
            Text("\(commit.authorName) <\(commit.authorEmail)>")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

private struct FullCommitDiffRow: View {
    var body: some View {
        HStack {
            Image(systemName: "doc.text")
            Text("Full commit diff")
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

private struct CommitFileRow: View {
    let file: GitCommitFile

    var body: some View {
        HStack(spacing: 8) {
            Text(file.status.shortLabel)
                .font(.caption2.weight(.bold))
                .frame(width: 22, height: 18)
                .foregroundStyle(file.status == .deleted ? .red : .secondary)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let oldPath = file.oldPath {
                    Text("from \(oldPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.vertical, 7)
    }
}
