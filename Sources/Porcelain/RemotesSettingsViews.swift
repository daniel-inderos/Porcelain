import SwiftUI
import PorcelainCore

struct RemotesView: View {
    @ObservedObject var viewModel: RepositoryViewModel
    @State private var remoteName = "origin"
    @State private var remoteURL = ""
    @State private var editingRemote: GitRemote?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Remotes")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.openRepositoryOnRemote()
                } label: {
                    Label("Open Repository", systemImage: "safari")
                }
                .disabled(!viewModel.hasGitHubRemote)
            }
            .padding(12)

            Divider()

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(editingRemote == nil ? "Add Remote" : "Edit Remote")
                        .font(.headline)
                    TextField("Name", text: $remoteName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(editingRemote != nil)
                    TextField("URL", text: $remoteURL)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button {
                            if editingRemote == nil {
                                viewModel.addRemote(named: remoteName, url: remoteURL)
                            } else {
                                viewModel.setRemote(named: remoteName, url: remoteURL)
                            }
                            clearForm()
                        } label: {
                            Label(editingRemote == nil ? "Add" : "Save", systemImage: editingRemote == nil ? "plus" : "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(remoteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if editingRemote != nil {
                            Button("Cancel", action: clearForm)
                        }
                    }

                    Divider()

                    Text("GitHub")
                        .font(.headline)
                    Button {
                        viewModel.openNewPullRequest()
                    } label: {
                        Label("Create Pull Request", systemImage: "arrow.triangle.pull")
                    }
                    .disabled(!viewModel.hasGitHubRemote || viewModel.status.branchName == nil)

                    Button {
                        viewModel.openCompareOnRemote()
                    } label: {
                        Label("Open Compare", systemImage: "arrow.left.arrow.right")
                    }
                    .disabled(!viewModel.hasGitHubRemote || viewModel.status.branchName == nil)
                }
                .frame(width: 300, alignment: .topLeading)
                .padding(16)

                Divider()

                if viewModel.remotes.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "network")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No remotes")
                            .font(.headline)
                        Text("Add a remote to fetch, pull, and push.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.remotes) { remote in
                                RemoteRow(
                                    remote: remote,
                                    onEdit: {
                                        editingRemote = remote
                                        remoteName = remote.name
                                        remoteURL = remote.fetchURL ?? remote.pushURL ?? ""
                                    },
                                    onRemove: {
                                        if confirmDestructive(title: "Remove \(remote.name)?", message: "This removes the remote from local Git configuration.") {
                                            viewModel.removeRemote(named: remote.name)
                                        }
                                    },
                                    onCopy: {
                                        viewModel.copyPath(remote.displayURL)
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

    private func clearForm() {
        editingRemote = nil
        remoteName = "origin"
        remoteURL = ""
    }
}

private struct RemoteRow: View {
    let remote: GitRemote
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(remote.name)
                    .font(.callout.weight(.medium))
                if let fetch = remote.fetchURL {
                    LabeledContent("Fetch", value: fetch)
                        .font(.caption)
                }
                if let push = remote.pushURL {
                    LabeledContent("Push", value: push)
                        .font(.caption)
                }
            }
            .textSelection(.enabled)
            Spacer()
            Button("Edit", action: onEdit)
            Menu {
                Button("Copy URL", action: onCopy)
                Button("Remove", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct SettingsPaneView: View {
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        Form {
            Section("Repository") {
                LabeledContent("Name", value: viewModel.repository.name)
                LabeledContent("Path", value: viewModel.repository.url.path)
                LabeledContent("Branch", value: viewModel.status.branchDisplayName)
                LabeledContent("State", value: viewModel.status.isClean ? "Clean" : "\(viewModel.status.changes.count) changed")
            }

            Section("Git Identity") {
                LabeledContent("Name", value: viewModel.identity.name ?? "Git default")
                LabeledContent("Email", value: viewModel.identity.email ?? "Git default")
            }

            Section("GitHub Token") {
                HStack {
                    SecureField(viewModel.hasGitHubToken ? "Token stored in Keychain" : "ghp_...", text: $viewModel.githubToken)
                    Button("Save") {
                        viewModel.saveGitHubToken()
                    }
                    .disabled(viewModel.githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Delete") {
                        viewModel.deleteGitHubToken()
                    }
                    .disabled(!viewModel.hasGitHubToken)
                }
                Text(viewModel.hasGitHubToken ? "A token is stored in Keychain." : "Tokens are stored only in Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Actions") {
                HStack {
                    Button {
                        viewModel.openRepositoryOnRemote()
                    } label: {
                        Label("Open Remote", systemImage: "safari")
                    }
                    .disabled(!viewModel.hasGitHubRemote)

                    Button {
                        viewModel.openNewPullRequest()
                    } label: {
                        Label("New Pull Request", systemImage: "arrow.triangle.pull")
                    }
                    .disabled(!viewModel.hasGitHubRemote || viewModel.status.branchName == nil)
                }
            }

            if !viewModel.rawGitOutput.isEmpty {
                Section("Latest Git Output") {
                    ScrollView {
                        Text(viewModel.rawGitOutput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 120)
                }
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }
}

