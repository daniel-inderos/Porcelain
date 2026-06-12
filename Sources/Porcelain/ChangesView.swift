import AppKit
import SwiftUI
import PorcelainCore

struct ChangesView: View {
    @ObservedObject var viewModel: RepositoryViewModel
    @State private var diffMode: DiffMode = .unified

    var body: some View {
        HSplitView {
            ChangeListView(viewModel: viewModel)
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)

            DiffPanelView(diff: viewModel.diff, mode: $diffMode)
                .frame(minWidth: 380)

            CommitPanelView(viewModel: viewModel)
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
        }
    }
}

private struct ChangeListView: View {
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        Group {
            if viewModel.status.isClean {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No local changes")
                        .font(.headline)
                    Text("The working tree is clean.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selection) {
                    ChangeSection(
                        title: "Staged",
                        count: viewModel.stagedChanges.count,
                        changes: viewModel.stagedChanges,
                        staged: true,
                        viewModel: viewModel
                    )

                    ChangeSection(
                        title: "Unstaged",
                        count: viewModel.unstagedChanges.count,
                        changes: viewModel.unstagedChanges,
                        staged: false,
                        viewModel: viewModel
                    )
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
            Text("Changes")
                .font(.headline)
            Spacer()
            Button {
                viewModel.stageAll()
            } label: {
                Label("Stage All", systemImage: "plus.square")
            }
            .buttonStyle(.glass)
            .disabled(viewModel.unstagedChanges.isEmpty)
            .help("Stage all changes")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var selection: Binding<ChangeSelectionKey?> {
        Binding {
            guard let selectedChange = viewModel.selectedChange else { return nil }
            return ChangeSelectionKey(
                changeID: selectedChange.id,
                staged: viewModel.selectedChangeIsStaged
            )
        } set: { key in
            guard let key else { return }
            let changes = key.staged ? viewModel.stagedChanges : viewModel.unstagedChanges
            guard let change = changes.first(where: { $0.id == key.changeID }) else { return }
            Task {
                await viewModel.selectChange(change, staged: key.staged)
            }
        }
    }
}

private struct ChangeSelectionKey: Hashable {
    let changeID: GitChange.ID
    let staged: Bool
}

private struct ChangeSection: View {
    let title: String
    let count: Int
    let changes: [GitChange]
    let staged: Bool
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        Section {
            if changes.isEmpty {
                Text(staged ? "Nothing staged" : "No unstaged changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                ForEach(changes) { change in
                    ChangeRow(change: change)
                    .tag(ChangeSelectionKey(changeID: change.id, staged: staged))
                    .contextMenu {
                        if staged {
                            Button("Unstage") { viewModel.unstage(change) }
                        } else {
                            Button("Stage") { viewModel.stage(change) }
                            Button("Discard...") {
                                if confirmDestructive(
                                    title: "Discard Changes?",
                                    message: change.isUntracked
                                        ? "This will permanently delete the untracked file \(change.path)."
                                        : "This will permanently discard local changes to \(change.path)."
                                ) {
                                    viewModel.discard(change)
                                }
                            }
                        }
                        Divider()
                        Button("Open File") { viewModel.openFile(change) }
                        Button("Reveal in Finder") { viewModel.revealInFinder(change) }
                        Button("Copy Path") { viewModel.copyPath(change.path) }
                    }
                }
            }
        } header: {
            ChangeSectionHeader(title: title, count: count) {
                if staged, count > 0 {
                    Button("Unstage All") {
                        viewModel.unstageAll()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ChangeSectionHeader<Accessory: View>: View {
    let title: String
    let count: Int
    let accessory: Accessory

    init(title: String, count: Int, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.count = count
        self.accessory = accessory()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.14))
                .clipShape(Capsule())
            Spacer()
            accessory
        }
        .padding(.vertical, 4)
        .textCase(nil)
    }
}

private struct ChangeRow: View {
    let change: GitChange

    var body: some View {
        HStack(spacing: 8) {
            Text(change.displayState.shortLabel)
                .font(.caption2.weight(.bold))
                .frame(width: 22, height: 18)
                .foregroundStyle(labelColor)
                .background(labelColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(change.path)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let originalPath = change.originalPath {
                    Text("from \(originalPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(change.displayState.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if change.isConflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 7)
    }

    private var labelColor: Color {
        switch change.displayState {
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

private struct CommitPanelView: View {
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit")
                .font(.headline)

            TextField("Summary", text: $viewModel.commitSummary)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $viewModel.commitDescription)
                .font(.body)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quinary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.18))
                )

            Toggle("Amend previous commit", isOn: $viewModel.amendCommit)

            VStack(alignment: .leading, spacing: 4) {
                Text("Author")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(viewModel.identity.displayName)
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(viewModel.stagedChanges.count) staged")
                        .font(.callout.weight(.medium))
                    Text(viewModel.syncSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.commit()
                } label: {
                    Label(viewModel.amendCommit ? "Amend" : "Commit", systemImage: "checkmark.circle")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Commit staged changes (⌘↩)")
                .disabled(viewModel.commitSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.stagedChanges.isEmpty)
            }

            Spacer()

            if !viewModel.rawGitOutput.isEmpty {
                DisclosureGroup("Latest Git Output") {
                    ScrollView {
                        Text(viewModel.rawGitOutput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
        .padding(14)
        .background(.background)
    }
}

@MainActor
func confirmDestructive(title: String, message: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}
