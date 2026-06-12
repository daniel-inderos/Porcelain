import SwiftUI
import PorcelainCore

struct RepositoryView: View {
    @ObservedObject var viewModel: RepositoryViewModel
    var openWorktree: (URL) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.hasConflicts {
                ConflictBanner(viewModel: viewModel)
            }

            Group {
                switch viewModel.selectedTab {
                case .changes:
                    ChangesView(viewModel: viewModel)
                case .worktrees:
                    WorktreesView(viewModel: viewModel, openWorktree: openWorktree)
                case .history:
                    HistoryView(viewModel: viewModel)
                case .branches:
                    BranchesView(viewModel: viewModel)
                case .remotes:
                    RemotesView(viewModel: viewModel)
                case .settings:
                    SettingsPaneView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(viewModel.repository.name)
        .navigationSubtitle(viewModel.syncSummary)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $viewModel.selectedTab) {
                    ForEach(PorcelainTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            ToolbarItemGroup {
                Picker("Branch", selection: branchSelection) {
                    if viewModel.branches.isEmpty {
                        Text(viewModel.status.branchDisplayName).tag(viewModel.status.branchDisplayName)
                    } else {
                        ForEach(viewModel.branches) { branch in
                            Text(branch.name).tag(branch.name)
                        }
                    }
                }
                .frame(maxWidth: 160)
                .help("Current branch")
            }

            ToolbarItemGroup {
                Button {
                    viewModel.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh")
                .disabled(viewModel.isBusy)

                Button {
                    viewModel.fetch()
                } label: {
                    Label("Fetch", systemImage: "arrow.down.circle")
                }
                .help("Fetch")
                .disabled(viewModel.isBusy)

                Button {
                    viewModel.pull()
                } label: {
                    Label("Pull", systemImage: "arrow.down")
                }
                .help("Pull")
                .disabled(viewModel.isBusy)

                Button {
                    viewModel.push()
                } label: {
                    Label("Push", systemImage: "arrow.up")
                }
                .help(viewModel.status.upstreamName == nil ? "Push and set upstream" : "Push")
                .disabled(viewModel.isBusy)
            }
        }
        .overlay(alignment: .top) {
            if let message = viewModel.activityMessage {
                ActivityOverlay(message: message)
                    .padding(.top, viewModel.hasConflicts ? 58 : 0)
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

    private var branchSelection: Binding<String> {
        Binding {
            viewModel.status.branchName ?? viewModel.status.branchDisplayName
        } set: { newValue in
            viewModel.checkoutBranch(named: newValue)
        }
    }
}

private struct ConflictBanner: View {
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("This repository has merge conflicts.")
                .font(.headline)
            Text("Resolve the listed files, then stage and commit the result.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Show Changes") {
                viewModel.selectedTab = .changes
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.orange.opacity(0.2)), in: .rect(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
