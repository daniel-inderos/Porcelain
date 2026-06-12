import SwiftUI
import PorcelainCore

struct RemotesView: View {
    @ObservedObject var viewModel: RepositoryViewModel
    @State private var remoteName = "origin"
    @State private var remoteURL = ""
    @State private var editingRemote: GitRemote?

    var body: some View {
        Form {
            remoteEditorSection
            githubSection
            remotesSection
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaInset(edge: .top) {
            remotesHeader
        }
    }

    private var remotesHeader: some View {
        GlassEffectContainer(spacing: 12) {
            HStack {
                Text("Remotes")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.openRepositoryOnRemote()
                } label: {
                    Label("Open Repository", systemImage: "safari")
                }
                .buttonStyle(.glass)
                .disabled(!viewModel.hasGitHubRemote)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var remoteEditorSection: some View {
        Section {
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
                .buttonStyle(.glassProminent)
                .disabled(remoteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if editingRemote != nil {
                    Button("Cancel", action: clearForm)
                        .buttonStyle(.glass)
                }
            }
        } header: {
            Text(editingRemote == nil ? "Add Remote" : "Edit Remote")
        } footer: {
            Text("Remote settings are written to this repository's local Git configuration.")
                .foregroundStyle(.secondary)
        }
    }

    private var githubSection: some View {
        Section("GitHub") {
            Button {
                viewModel.openNewPullRequest()
            } label: {
                Label("Create Pull Request", systemImage: "arrow.triangle.pull")
            }
            .buttonStyle(.glass)
            .disabled(!viewModel.hasGitHubRemote || viewModel.status.branchName == nil)

            Button {
                viewModel.openCompareOnRemote()
            } label: {
                Label("Open Compare", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.glass)
            .disabled(!viewModel.hasGitHubRemote || viewModel.status.branchName == nil)
        }
    }

    private var remotesSection: some View {
        Section("Configured Remotes") {
            if viewModel.remotes.isEmpty {
                emptyRemotesView
            } else {
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
        }
    }

    private var emptyRemotesView: some View {
        VStack(spacing: 10) {
            Image(systemName: "network")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No remotes")
                .font(.headline)
            Text("Add a remote to fetch, pull, and push.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
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
                .buttonStyle(.glass)
            Menu {
                Button("Copy URL", action: onCopy)
                Button("Remove", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
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
                    .buttonStyle(.glassProminent)
                    .disabled(viewModel.githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Delete") {
                        viewModel.deleteGitHubToken()
                    }
                    .buttonStyle(.glass)
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
                    .buttonStyle(.glass)
                    .disabled(!viewModel.hasGitHubRemote)

                    Button {
                        viewModel.openNewPullRequest()
                    } label: {
                        Label("New Pull Request", systemImage: "arrow.triangle.pull")
                    }
                    .buttonStyle(.glass)
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
