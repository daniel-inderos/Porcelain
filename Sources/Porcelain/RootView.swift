import SwiftUI
import PorcelainCore

struct RootView: View {
    @ObservedObject var appModel: AppViewModel
    @State private var showingCloneSheet = false

    var body: some View {
        NavigationSplitView {
            SidebarView(appModel: appModel, showingCloneSheet: $showingCloneSheet)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            if let viewModel = appModel.repositoryViewModel {
                RepositoryView(viewModel: viewModel, openWorktree: appModel.openWorktree(at:))
                    .id(viewModel.id)
            } else {
                EmptyRepositoryView(appModel: appModel, showingCloneSheet: $showingCloneSheet)
            }
        }
        .sheet(isPresented: $showingCloneSheet) {
            CloneRepositorySheet(appModel: appModel)
        }
        .alert(item: $appModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCloneSheet)) { _ in
            showingCloneSheet = true
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var appModel: AppViewModel
    @Binding var showingCloneSheet: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Porcelain")
                    .font(.title3.weight(.semibold))
                Spacer()
                Menu {
                    Button {
                        appModel.chooseExistingRepository()
                    } label: {
                        Label("Open Repository", systemImage: "folder")
                    }
                    Button {
                        showingCloneSheet = true
                    } label: {
                        Label("Clone Repository", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        appModel.chooseFolderAndInitializeRepository()
                    } label: {
                        Label("Initialize Repository", systemImage: "plus.square.on.folder")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.button)
                .help("Add a repository")
            }
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 10)

            TextField("Search repositories", text: $appModel.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            if appModel.filteredRepositories.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(appModel.repositories.isEmpty ? "No recent repositories" : "No matches")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(appModel.filteredRepositories) { repository in
                        RepositorySidebarRow(
                            repository: repository,
                            isSelected: appModel.selectedRepository == repository
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appModel.select(repository)
                        }
                        .contextMenu {
                            Button("Forget") {
                                appModel.forget(repository)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            HStack {
                Image(systemName: appModel.gitVersion == "Git unavailable" ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(appModel.gitVersion == "Git unavailable" ? .orange : .secondary)
                Text(appModel.gitVersion)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption)
            .padding(12)
        }
    }
}

private struct RepositorySidebarRow: View {
    let repository: Repository
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(isSelected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(repository.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(repository.url.path)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct EmptyRepositoryView: View {
    @ObservedObject var appModel: AppViewModel
    @Binding var showingCloneSheet: Bool

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            VStack(spacing: 8) {
                Text("Porcelain")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                Text("A fast, native Git client for everyday work.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    appModel.chooseExistingRepository()
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showingCloneSheet = true
                } label: {
                    Label("Clone", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    appModel.chooseFolderAndInitializeRepository()
                } label: {
                    Label("Initialize", systemImage: "plus.square.on.folder")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Text("Recent repositories will appear in the sidebar.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
