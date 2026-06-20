import AppKit
import SwiftUI
import PorcelainCore

struct WorktreesView: View {
    @ObservedObject var viewModel: RepositoryViewModel
    let openWorktree: (URL) -> Void
    @State private var showingNewWorktreeSheet = false
    @State private var worktreePendingRemoval: WorktreeInfo?
    @State private var showingPruneConfirmation = false
    @State private var reviewSession: WorktreeReviewSession?
    @State private var comparisonSession: WorktreeComparisonSession?
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 24) {
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
                Text(headerSubtitle)
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
                .buttonStyle(.glass)
            }
            Button {
                showingNewWorktreeSheet = true
            } label: {
                Label("New Worktree", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .disabled(viewModel.isBusy)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private var content: some View {
        if let comparisonSession {
            WorktreeComparisonView(
                baseInfo: comparisonSession.baseInfo,
                comparisonInfo: comparisonSession.comparisonInfo,
                viewModel: viewModel,
                glassNamespace: glassNamespace,
                onBack: dismissComparison
            )
        } else if let reviewSession {
            WorktreeReviewView(
                info: reviewSession.info,
                parentRepositoryURL: viewModel.repository.url,
                viewModel: reviewSession.viewModel,
                openWorktree: openWorktree,
                glassNamespace: glassNamespace,
                onBack: dismissReview
            )
        } else {
            worktreesOverview
        }
    }

    private var worktreesOverview: some View {
        GeometryReader { proxy in
            ScrollView {
                if showsEmptyState {
                    WorktreesEmptyState {
                        showingNewWorktreeSheet = true
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.worktreeInfos) { info in
                            WorktreeCard(
                                info: info,
                                repositoryURL: viewModel.repository.url,
                                viewModel: viewModel,
                                openWorktree: openWorktree,
                                glassNamespace: glassNamespace,
                                onReview: {
                                    beginReview(for: info)
                                },
                                onCompare: {
                                    beginComparison(for: info)
                                },
                                onRemove: {
                                    worktreePendingRemoval = info
                                }
                            )
                        }
                    }
                    .padding(16)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaInset(edge: .top) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    private var headerSubtitle: String {
        let count = viewModel.worktreeInfos.count
        let base = "\(count) working \(count == 1 ? "state" : "states")"
        let dirtyCount = viewModel.worktreeInfos.filter { $0.summary?.isClean == false }.count
        guard dirtyCount > 0 else { return base }
        return "\(base) · \(dirtyCount) with uncommitted changes"
    }

    private var showsEmptyState: Bool {
        viewModel.worktreeInfos.count == 1 && viewModel.worktreeInfos.first?.worktree.isMain == true
    }

    private var prunableCount: Int {
        viewModel.worktreeInfos.filter(\.worktree.isPrunable).count
    }

    private func beginReview(for info: WorktreeInfo) {
        guard !info.worktree.isBare, !info.worktree.isPrunable else { return }
        if isCurrent(info) {
            withAnimation(.smooth) {
                viewModel.selectedTab = .changes
            }
            return
        }

        let session = WorktreeReviewSession(info: info, viewModel: viewModel.makeWorktreeReviewViewModel(for: info.worktree))
        withAnimation(.smooth) {
            reviewSession = session
        }
    }

    private func dismissReview() {
        withAnimation(.smooth) {
            reviewSession = nil
        }
        viewModel.refreshWorktrees()
    }

    private func beginComparison(for info: WorktreeInfo) {
        guard !isCurrent(info), !info.worktree.isBare, !info.worktree.isPrunable else { return }
        let baseInfo = viewModel.worktreeInfos.first(where: isCurrent)
        withAnimation(.smooth) {
            reviewSession = nil
            comparisonSession = WorktreeComparisonSession(baseInfo: baseInfo, comparisonInfo: info)
        }
    }

    private func dismissComparison() {
        withAnimation(.smooth) {
            comparisonSession = nil
        }
        viewModel.refreshWorktrees()
    }

    private func isCurrent(_ info: WorktreeInfo) -> Bool {
        info.worktree.isCurrent(for: viewModel.repository.url)
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

private struct WorktreeReviewSession {
    let info: WorktreeInfo
    let viewModel: RepositoryViewModel
}

private struct WorktreeComparisonSession {
    let baseInfo: WorktreeInfo?
    let comparisonInfo: WorktreeInfo
}

private struct WorktreeCard: View {
    let info: WorktreeInfo
    let repositoryURL: URL
    @ObservedObject var viewModel: RepositoryViewModel
    let openWorktree: (URL) -> Void
    let glassNamespace: Namespace.ID
    let onReview: () -> Void
    let onCompare: () -> Void
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
                        WorktreeBadgesView(info: info, currentRepositoryURL: repositoryURL)
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
                    reviewButton
                    compareButton

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
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .glassEffectID(info.id, in: glassNamespace)
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
            }
        }
        .contextMenu {
            menuItems
        }
    }

    @ViewBuilder
    private var reviewButton: some View {
        if showsReviewButton {
            let button = Button {
                onReview()
            } label: {
                Label("Review", systemImage: "doc.text.magnifyingglass")
            }
            .help("Review this worktree")

            if isDirty {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var compareButton: some View {
        if canCompare {
            Button {
                onCompare()
            } label: {
                Label("Compare", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
            .help("Compare with current worktree")
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
        if canReview && !showsReviewButton {
            Button("Review") {
                onReview()
            }
        }
        if canCompare {
            Button("Compare with Current") {
                onCompare()
            }
        }
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
        info.worktree.isCurrent(for: repositoryURL)
    }

    private var canRemove: Bool {
        !info.worktree.isMain && !info.worktree.isLocked
    }

    private var canReview: Bool {
        !info.worktree.isBare && !info.worktree.isPrunable
    }

    private var canCompare: Bool {
        canReview && !isCurrent
    }

    private var isDirty: Bool {
        info.summary?.isClean == false
    }

    private var showsReviewButton: Bool {
        canReview && (isCurrent || isDirty)
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

        if let tracking = summary.trackingSummary {
            parts.append(tracking)
        }
        return parts.joined(separator: " · ")
    }
}

private struct WorktreeComparisonView: View {
    let baseInfo: WorktreeInfo?
    let comparisonInfo: WorktreeInfo
    @ObservedObject var viewModel: RepositoryViewModel
    let glassNamespace: Namespace.ID
    let onBack: () -> Void

    @State private var comparison: WorktreeComparison?
    @State private var diff = DiffContent(path: "", text: "")
    @State private var diffMode: DiffMode = .unified
    @State private var selection: WorktreeComparisonSelection? = .fullDiff
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if isLoading && comparison == nil {
                ProgressView("Comparing worktrees")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                comparisonContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: comparisonInfo.id) {
            await loadComparison()
        }
        .onExitCommand {
            onBack()
        }
    }

    private var comparisonContent: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HSplitView {
                comparisonList
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: max(260, min(460, width * 0.34)))

                DiffPanelView(
                    diff: diff,
                    mode: $diffMode,
                    emptyTitle: "No differences",
                    emptyMessage: "These worktrees have the same tracked and visible untracked file contents."
                )
                .frame(minWidth: 340, idealWidth: 520, maxWidth: .infinity)
            }
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
                    Text("Compare Worktrees")
                        .font(.headline)
                    WorktreeBadgesView(info: comparisonInfo, currentRepositoryURL: viewModel.repository.url)
                }

                HStack(spacing: 6) {
                    Text(baseDisplayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                    Text(comparisonInfo.worktree.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                Task {
                    await loadComparison()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh comparison")
            .disabled(isLoading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .glassEffectID(comparisonInfo.id, in: glassNamespace)
    }

    private var comparisonList: some View {
        List(selection: selectionBinding) {
            Section {
                WorktreeComparisonDetailsBlock(
                    baseName: baseDisplayName,
                    comparisonName: comparisonInfo.worktree.displayName,
                    fileCount: comparison?.files.count ?? 0
                )
            }

            Section {
                WorktreeFullComparisonRow(fileCount: comparison?.files.count ?? 0)
                    .tag(WorktreeComparisonSelection.fullDiff)

                ForEach(comparison?.files ?? []) { file in
                    WorktreeComparisonFileRow(file: file)
                        .tag(WorktreeComparisonSelection.file(file.id))
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var selectionBinding: Binding<WorktreeComparisonSelection?> {
        Binding {
            selection
        } set: { newSelection in
            guard let newSelection else { return }
            selection = newSelection
            Task {
                await select(newSelection)
            }
        }
    }

    private var baseURL: URL {
        baseInfo?.worktree.path ?? viewModel.repository.url
    }

    private var baseDisplayName: String {
        baseInfo?.worktree.displayName ?? "Current"
    }

    private func loadComparison() async {
        isLoading = true
        selection = .fullDiff
        let loaded = await viewModel.compareWorktrees(
            baseURL: baseURL,
            comparisonURL: comparisonInfo.worktree.path
        )
        guard !Task.isCancelled else { return }
        comparison = loaded
        diff = loaded?.diff ?? DiffContent(path: "\(baseDisplayName) vs \(comparisonInfo.worktree.displayName)", text: "")
        isLoading = false
    }

    private func select(_ selection: WorktreeComparisonSelection) async {
        switch selection {
        case .fullDiff:
            diff = comparison?.diff ?? DiffContent(path: "\(baseDisplayName) vs \(comparisonInfo.worktree.displayName)", text: "")
        case .file(let fileID):
            guard let file = comparison?.files.first(where: { $0.id == fileID }) else { return }
            let loaded = await viewModel.diffBetweenWorktrees(
                baseURL: baseURL,
                comparisonURL: comparisonInfo.worktree.path,
                file: file
            )
            guard !Task.isCancelled, self.selection == selection else { return }
            if let loaded {
                diff = loaded
            }
        }
    }
}

private enum WorktreeComparisonSelection: Hashable {
    case fullDiff
    case file(WorktreeComparisonFile.ID)
}

private struct WorktreeComparisonDetailsBlock: View {
    let baseName: String
    let comparisonName: String
    let fileCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(fileCount) changed \(fileCount == 1 ? "file" : "files")")
                .font(.callout.weight(.medium))
            HStack(spacing: 6) {
                Text(baseName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.right")
                Text(comparisonName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

private struct WorktreeFullComparisonRow: View {
    let fileCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
            VStack(alignment: .leading, spacing: 2) {
                Text("Full comparison")
                Text("\(fileCount) changed \(fileCount == 1 ? "file" : "files")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

private struct WorktreeComparisonFileRow: View {
    let file: WorktreeComparisonFile

    var body: some View {
        HStack(spacing: 8) {
            Text(file.status.shortLabel)
                .font(.caption2.weight(.bold))
                .frame(width: 22, height: 18)
                .foregroundStyle(labelColor)
                .background(labelColor.opacity(0.12))
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
                } else {
                    Text(file.status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    private var labelColor: Color {
        switch file.status {
        case .added, .untracked:
            .green
        case .deleted:
            .red
        case .renamed, .copied:
            .blue
        case .unmerged:
            .orange
        default:
            .secondary
        }
    }
}

struct WorktreeBadgesView: View {
    let info: WorktreeInfo
    let currentRepositoryURL: URL

    var body: some View {
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

    private var isCurrent: Bool {
        info.worktree.isCurrent(for: currentRepositoryURL)
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
            .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
