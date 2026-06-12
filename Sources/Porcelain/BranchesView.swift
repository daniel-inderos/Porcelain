import SwiftUI
import PorcelainCore

struct BranchesView: View {
    @ObservedObject var viewModel: RepositoryViewModel
    @State private var newBranchName = ""
    @State private var checkoutNewBranch = true
    @State private var renameText = ""
    @State private var branchBeingRenamed: GitBranch?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            branchControls
                .frame(width: 300, alignment: .topLeading)

            Divider()

            branchList
        }
        .background(.background)
    }

    private var branchControls: some View {
        Form {
            Section("Create Branch") {
                TextField("feature/name", text: $newBranchName)
                    .textFieldStyle(.roundedBorder)
                Toggle("Check out new branch", isOn: $checkoutNewBranch)
                Button {
                    viewModel.createBranch(named: newBranchName, checkout: checkoutNewBranch)
                    newBranchName = ""
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Current State") {
                LabeledContent("Branch", value: viewModel.status.branchDisplayName)
                LabeledContent("Upstream", value: viewModel.status.upstreamName ?? "None")
                LabeledContent("Sync", value: viewModel.syncSummary)

                if viewModel.status.upstreamName == nil, viewModel.status.branchName != nil {
                    Button {
                        viewModel.pushAndSetUpstream()
                    } label: {
                        Label("Push and Set Upstream", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var branchList: some View {
        List {
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
        .listStyle(.plain)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaInset(edge: .top, spacing: 0) {
            branchesHeader
        }
    }

    private var branchesHeader: some View {
        GlassEffectContainer(spacing: 12) {
            HStack {
                Text("Branches")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.openBranchOnRemote()
                } label: {
                    Label("Open Branch", systemImage: "safari")
                }
                .buttonStyle(.glass)
                .disabled(!viewModel.hasGitHubRemote || viewModel.status.branchName == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
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
                    HStack(spacing: 6) {
                        Text(branch.name)
                            .font(.callout.weight(.medium))
                            .textSelection(.enabled)
                        if branch.isCurrent {
                            Text("Current")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.12), in: Capsule())
                        }
                    }
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
    }
}
