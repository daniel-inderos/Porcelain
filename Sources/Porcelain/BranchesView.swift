import SwiftUI
import PorcelainCore

struct BranchesView: View {
    @ObservedObject var viewModel: RepositoryViewModel
    @State private var newBranchName = ""
    @State private var checkoutNewBranch = true
    @State private var renameText = ""
    @State private var branchBeingRenamed: GitBranch?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Branches")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.openBranchOnRemote()
                } label: {
                    Label("Open Branch", systemImage: "safari")
                }
                .disabled(!viewModel.hasGitHubRemote || viewModel.status.branchName == nil)
            }
            .padding(12)

            Divider()

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Create Branch")
                        .font(.headline)
                    TextField("feature/name", text: $newBranchName)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Check out new branch", isOn: $checkoutNewBranch)
                    Button {
                        viewModel.createBranch(named: newBranchName, checkout: checkoutNewBranch)
                        newBranchName = ""
                    } label: {
                        Label("Create", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Divider()

                    Text("Current State")
                        .font(.headline)
                    LabeledContent("Branch", value: viewModel.status.branchDisplayName)
                    LabeledContent("Upstream", value: viewModel.status.upstreamName ?? "None")
                    LabeledContent("Sync", value: viewModel.syncSummary)

                    if viewModel.status.upstreamName == nil, viewModel.status.branchName != nil {
                        Button {
                            viewModel.pushAndSetUpstream()
                        } label: {
                            Label("Push and Set Upstream", systemImage: "arrow.up.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(width: 280, alignment: .topLeading)
                .padding(16)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.branches) { branch in
                            BranchRow(
                                branch: branch,
                                isRenaming: branchBeingRenamed?.id == branch.id,
                                renameText: $renameText,
                                onCheckout: {
                                    viewModel.checkoutBranch(named: branch.name)
                                },
                                onRenameStart: {
                                    branchBeingRenamed = branch
                                    renameText = branch.name
                                },
                                onRenameCommit: {
                                    viewModel.renameBranch(from: branch.name, to: renameText)
                                    branchBeingRenamed = nil
                                    renameText = ""
                                },
                                onRenameCancel: {
                                    branchBeingRenamed = nil
                                    renameText = ""
                                },
                                onMerge: {
                                    if confirmDestructive(title: "Merge \(branch.name)?", message: "Porcelain will run a no-fast-forward merge into the current branch.") {
                                        viewModel.mergeBranch(named: branch.name)
                                    }
                                },
                                onDelete: {
                                    if confirmDestructive(title: "Delete \(branch.name)?", message: "Git will refuse if the branch has unmerged work.") {
                                        viewModel.deleteBranch(named: branch.name)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

private struct BranchRow: View {
    let branch: GitBranch
    let isRenaming: Bool
    @Binding var renameText: String
    let onCheckout: () -> Void
    let onRenameStart: () -> Void
    let onRenameCommit: () -> Void
    let onRenameCancel: () -> Void
    let onMerge: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                if isRenaming {
                    TextField("Branch name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                } else {
                    Text(branch.name)
                        .font(.callout.weight(.medium))
                        .textSelection(.enabled)
                }
                Text(branch.trackingSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if isRenaming {
                Button("Save", action: onRenameCommit)
                Button("Cancel", action: onRenameCancel)
            } else {
                Button("Checkout", action: onCheckout)
                    .disabled(branch.isCurrent)
                Menu {
                    Button("Rename", action: onRenameStart)
                    Button("Merge into Current", action: onMerge)
                        .disabled(branch.isCurrent)
                    Button("Delete", role: .destructive, action: onDelete)
                        .disabled(branch.isCurrent)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(branch.isCurrent ? Color.accentColor.opacity(0.10) : Color.clear)
    }
}
