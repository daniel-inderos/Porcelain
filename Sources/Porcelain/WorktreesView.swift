import AppKit
import SwiftUI
import PorcelainCore

struct WorktreesView: View {
    @ObservedObject var viewModel: RepositoryViewModel
    let openWorktree: (URL) -> Void
    @State private var showingNewWorktreeSheet = false
    @State private var worktreePendingRemoval: WorktreeInfo?
    @State private var showingPruneConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showingNewWorktreeSheet) {
            NewWorktreeSheet(viewModel: viewModel)
        }
        .confirmationDialog(
            removalTitle,
            isPresented: removalDialogIsPresented,
            titleVisibility: .visible
        ) {
            if let info = worktreePendingRemoval {
                let hasLocalChanges = info.summary?.isClean == false
                Button(hasLocalChanges ? "Remove Anyway" : "Remove", role: .destructive) {
                    viewModel.removeWorktree(info.worktree, force: hasLocalChanges)
                    worktreePendingRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) {
                worktreePendingRemoval = nil
            }
        } message: {
            Text(removalMessage)
        }
        .confirmationDialog(
            "Prune Worktrees?",
            isPresented: $showingPruneConfirmation,
            titleVisibility: .visible
        ) {
            Button("Prune \(prunableCount)", role: .destructive) {
                viewModel.pruneWorktrees()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes stale worktree records for folders Git already considers prunable.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Worktrees")
                    .font(.headline)
                Text("\(viewModel.worktreeInfos.count) working \(viewModel.worktreeInfos.count == 1 ? "state" : "states")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if prunableCount > 0 {
                Button {
                    showingPruneConfirmation = true
                } label: {
                    Label("Prune \(prunableCount)", systemImage: "trash")
                }
                .disabled(viewModel.isBusy)
            }
            Button {
                showingNewWorktreeSheet = true
            } label: {
                Label("New Worktree", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isBusy)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if showsEmptyState {
            WorktreesEmptyState {
                showingNewWorktreeSheet = true
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.worktreeInfos) { info in
                        WorktreeCard(
                            info: info,
                            repositoryURL: viewModel.repository.url,
                            viewModel: viewModel,
                            openWorktree: openWorktree,
                            onRemove: {
                                worktreePendingRemoval = info
                            }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private var showsEmptyState: Bool {
        viewModel.worktreeInfos.count == 1 && viewModel.worktreeInfos.first?.worktree.isMain == true
    }

    private var prunableCount: Int {
        viewModel.worktreeInfos.filter(\.worktree.isPrunable).count
    }

    private var removalDialogIsPresented: Binding<Bool> {
        Binding {
            worktreePendingRemoval != nil
        } set: { isPresented in
            if !isPresented {
                worktreePendingRemoval = nil
            }
        }
    }

    private var removalTitle: String {
        guard let info = worktreePendingRemoval else { return "Remove Worktree?" }
        return "Remove \(info.worktree.displayName)?"
    }

    private var removalMessage: String {
        guard let info = worktreePendingRemoval else { return "" }
        if info.summary?.isClean == false {
            return "This worktree has local changes. Removing it will delete the folder and uncommitted work."
        }
        return "This removes the worktree folder from disk."
    }
}

private struct WorktreeCard: View {
    let info: WorktreeInfo
    let repositoryURL: URL
    @ObservedObject var viewModel: RepositoryViewModel
    let openWorktree: (URL) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(info.worktree.displayName)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        badges
                    }

                    Text(summaryText)
                        .font(.callout)
                        .foregroundStyle(summaryColor)

                    commitLine

                    Text(info.worktree.path.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    if !isCurrent {
                        Button {
                            openWorktree(info.worktree.path)
                        } label: {
                            Label("Open in Porcelain", systemImage: "arrow.up.forward.app")
                        }
                        .help("Open in Porcelain")
                    }

                    Menu {
                        menuItems
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .help("More actions")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrent ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.16))
        )
        .contextMenu {
            menuItems
        }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 5) {
            if isCurrent {
                WorktreeBadge("Current", color: .accentColor)
            }
            if info.worktree.isMain {
                WorktreeBadge("Main", color: .blue)
            }
            if info.worktree.isDetached {
                WorktreeBadge("Detached", color: .orange)
            }
            if info.worktree.isLocked {
                WorktreeBadge("Locked", color: .orange)
                    .help(info.worktree.lockReason ?? "This worktree is locked.")
            }
            if info.worktree.isPrunable {
                WorktreeBadge("Prunable", color: .red)
            }
        }
    }

    @ViewBuilder
    private var commitLine: some View {
        if let commit = info.summary?.lastCommit {
            HStack(spacing: 6) {
                Text(commit.subject.isEmpty ? "(no subject)" : commit.subject)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let date = commit.date {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.secondary)
        } else {
            Text(info.worktree.isBare ? "Bare repository" : "Latest commit unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if !isCurrent {
            Button("Open in Porcelain") {
                openWorktree(info.worktree.path)
            }
        }
        Button("Reveal in Finder") {
            viewModel.revealWorktreeInFinder(info.worktree)
        }
        Button("Open in Terminal") {
            viewModel.openWorktreeInTerminal(info.worktree)
        }
        Divider()
        Button("Remove", role: .destructive) {
            onRemove()
        }
        .disabled(!canRemove)
    }

    private var isCurrent: Bool {
        info.worktree.path.standardizedFileURL.path == repositoryURL.standardizedFileURL.path
    }

    private var canRemove: Bool {
        !info.worktree.isMain && !info.worktree.isLocked
    }

    private var iconName: String {
        if isCurrent { return "checkmark.circle.fill" }
        if info.worktree.isPrunable { return "exclamationmark.triangle.fill" }
        if info.worktree.isLocked { return "lock.fill" }
        return "folder"
    }

    private var iconColor: Color {
        if isCurrent { return .accentColor }
        if info.worktree.isPrunable { return .red }
        if info.worktree.isLocked { return .orange }
        return .secondary
    }

    private var summaryColor: Color {
        guard let summary = info.summary else {
            return info.worktree.isPrunable ? .red : .secondary
        }
        return summary.isClean ? .secondary : .primary
    }

    private var summaryText: String {
        guard let summary = info.summary else {
            if info.worktree.isPrunable {
                return "Prunable"
            }
            if info.worktree.isBare {
                return "Bare repository"
            }
            return "Status unavailable"
        }

        var parts: [String] = []
        if summary.isClean {
            parts.append("Clean")
        } else {
            parts.append("\(summary.total) changed \(summary.total == 1 ? "file" : "files") · +\(summary.insertions) −\(summary.deletions)")
            if summary.staged > 0 {
                parts.append("\(summary.staged) staged")
            }
            if summary.untracked > 0 {
                parts.append("\(summary.untracked) untracked")
            }
            if summary.conflicted > 0 {
                parts.append("\(summary.conflicted) conflicted")
            }
        }

        if let tracking = trackingSummary(for: summary) {
            parts.append(tracking)
        }
        return parts.joined(separator: " · ")
    }

    private func trackingSummary(for summary: WorktreeChangeSummary) -> String? {
        switch (summary.ahead, summary.behind) {
        case (0, 0):
            return nil
        case (let ahead, 0):
            return "\(ahead) ahead"
        case (0, let behind):
            return "\(behind) behind"
        case (let ahead, let behind):
            return "\(ahead) ahead, \(behind) behind"
        }
    }
}

private struct WorktreeBadge: View {
    let title: String
    let color: Color

    init(_ title: String, color: Color) {
        self.title = title
        self.color = color
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct WorktreesEmptyState: View {
    let onNewWorktree: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Only the main worktree is open")
                    .font(.headline)
                Text("Create worktrees for parallel agent sessions, risky experiments, or branch work that should stay isolated from your main checkout.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button {
                onNewWorktree()
            } label: {
                Label("New Worktree", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
