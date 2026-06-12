import SwiftUI
import PorcelainCore

struct HistoryView: View {
    @ObservedObject var viewModel: RepositoryViewModel
    @State private var diffMode: DiffMode = .unified

    var body: some View {
        HSplitView {
            CommitListView(viewModel: viewModel)
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)

            CommitFileListView(viewModel: viewModel)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            DiffPanelView(diff: viewModel.diff, mode: $diffMode)
                .frame(minWidth: 440)
        }
    }
}

private struct CommitListView: View {
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh history")
            }
            .padding(12)

            Divider()

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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.commits) { commit in
                            CommitRow(
                                commit: commit,
                                isSelected: viewModel.selectedCommit?.hash == commit.hash
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task {
                                    await viewModel.selectCommit(commit)
                                }
                            }
                            .contextMenu {
                                Button("Copy Hash") { viewModel.copyCommitHash(commit) }
                                Button("Open on GitHub") { viewModel.openCommitOnRemote(commit) }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

private struct CommitRow: View {
    let commit: GitCommit
    let isSelected: Bool

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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
    }

    private var formattedDate: String {
        guard let date = commit.date else { return "" }
        return date.formatted(.relative(presentation: .named))
    }
}

private struct CommitFileListView: View {
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        VStack(spacing: 0) {
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
            .padding(12)

            Divider()

            if let commit = viewModel.selectedCommit {
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
                .padding(12)
                Divider()
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    Button {
                        Task {
                            await viewModel.selectCommitFile(nil)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "doc.text")
                            Text("Full commit diff")
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)

                    ForEach(viewModel.commitFiles) { file in
                        CommitFileRow(
                            file: file,
                            isSelected: viewModel.selectedCommitFile?.id == file.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task {
                                await viewModel.selectCommitFile(file)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

private struct CommitFileRow: View {
    let file: GitCommitFile
    let isSelected: Bool

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
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
    }
}

