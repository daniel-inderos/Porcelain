import SwiftUI
import PorcelainCore

struct RepositoryView: View {
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.hasConflicts {
                ConflictBanner(viewModel: viewModel)
            }

            Picker("Section", selection: $viewModel.selectedTab) {
                ForEach(PorcelainTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider()

            Group {
                switch viewModel.selectedTab {
                case .changes:
                    ChangesView(viewModel: viewModel)
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
        .toolbar {
            ToolbarItemGroup {
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.repository.name)
                        .font(.headline)
                    Text(viewModel.repository.url.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(width: 220, alignment: .leading)

                Picker("Branch", selection: branchSelection) {
                    if viewModel.branches.isEmpty {
                        Text(viewModel.status.branchDisplayName).tag(viewModel.status.branchDisplayName)
                    } else {
                        ForEach(viewModel.branches) { branch in
                            Text(branch.name).tag(branch.name)
                        }
                    }
                }
                .frame(width: 180)
                .help("Current branch")

                Text(viewModel.syncSummary)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)

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

                Button {
                    viewModel.selectedTab = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .overlay(alignment: .top) {
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
        .background(Color.orange.opacity(0.12))
    }
}

