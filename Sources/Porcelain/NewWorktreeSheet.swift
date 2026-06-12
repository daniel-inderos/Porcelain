import AppKit
import SwiftUI
import PorcelainCore

struct NewWorktreeSheet: View {
    @ObservedObject var viewModel: RepositoryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: WorktreeBranchMode = .newBranch
    @State private var newBranchName = ""
    @State private var existingBranchName: String
    @State private var destinationURL: URL
    @State private var usesCustomDestination = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(viewModel: RepositoryViewModel) {
        self.viewModel = viewModel
        let availableBranches = Self.availableExistingBranches(
            branches: viewModel.branches,
            worktreeInfos: viewModel.worktreeInfos
        )
        let initialBranch = availableBranches.first?.name ?? ""
        _existingBranchName = State(initialValue: initialBranch)
        _destinationURL = State(initialValue: Self.defaultDestination(for: viewModel.repository.url, branch: "new-branch"))
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            Form {
                branchSection
                destinationSection
                statusSection
            }
            .formStyle(.grouped)

            Divider()
            buttonRow
        }
        .frame(width: 540)
        .onAppear {
            resetExistingBranchIfNeeded()
            updateDestinationForCurrentBranch()
        }
        .onChange(of: mode) { _, _ in
            resetExistingBranchIfNeeded()
            updateDestinationForCurrentBranch()
        }
        .onChange(of: newBranchName) { _, _ in
            updateDestinationForCurrentBranch()
        }
        .onChange(of: existingBranchName) { _, _ in
            updateDestinationForCurrentBranch()
        }
        .onDisappear {
            errorMessage = nil
        }
    }

    @ViewBuilder
    private var sheetHeader: some View {
        HStack {
            Text("New Worktree")
                .font(.title2.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var branchSection: some View {
        Section {
            Picker("Mode", selection: $mode) {
                ForEach(WorktreeBranchMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .newBranch:
                LabeledContent("Branch Name") {
                    TextField("feature/name", text: $newBranchName)
                        .textFieldStyle(.roundedBorder)
                }
            case .existingBranch:
                Picker("Branch", selection: $existingBranchName) {
                    if availableExistingBranches.isEmpty {
                        Text("No available branches").tag("")
                    } else {
                        ForEach(availableExistingBranches) { branch in
                            Text(branch.name).tag(branch.name)
                        }
                    }
                }
                .disabled(availableExistingBranches.isEmpty)
            }
        } header: {
            Text("Branch")
        } footer: {
            if let validationMessage {
                Label(validationMessage, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var destinationSection: some View {
        Section {
            LabeledContent("Destination Folder") {
                HStack {
                    Text(destinationURL.standardizedFileURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button("Choose...") {
                        chooseDestination()
                    }
                    .buttonStyle(.glass)
                }
            }
        } header: {
            Text("Location")
        } footer: {
            Text("Porcelain creates the worktree at this folder.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var buttonRow: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                createWorktree()
            } label: {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Create")
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var availableExistingBranches: [GitBranch] {
        Self.availableExistingBranches(branches: viewModel.branches, worktreeInfos: viewModel.worktreeInfos)
    }

    private var branchName: String {
        switch mode {
        case .newBranch:
            newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        case .existingBranch:
            existingBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var canCreate: Bool {
        !branchName.isEmpty &&
            !destinationURL.path.isEmpty &&
            !isCreating &&
            !viewModel.isBusy &&
            (mode == .newBranch || availableExistingBranches.contains { $0.name == existingBranchName })
    }

    private var validationMessage: String? {
        if mode == .existingBranch, availableExistingBranches.isEmpty {
            return "Every local branch is already checked out in a worktree."
        }
        if mode == .newBranch, branchName.isEmpty {
            return "Enter a branch name."
        }
        return nil
    }

    private func createWorktree() {
        errorMessage = nil
        isCreating = true
        viewModel.addWorktree(branch: branchName, createBranch: mode == .newBranch, at: destinationURL) { succeeded, alert in
            isCreating = false
            if succeeded {
                dismiss()
            } else {
                errorMessage = alert?.message ?? "Porcelain could not create the worktree."
            }
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Worktree Destination"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            destinationURL = url
            usesCustomDestination = true
        }
    }

    private func resetExistingBranchIfNeeded() {
        guard !availableExistingBranches.contains(where: { $0.name == existingBranchName }) else { return }
        existingBranchName = availableExistingBranches.first?.name ?? ""
    }

    private func updateDestinationForCurrentBranch() {
        guard !usesCustomDestination else { return }
        destinationURL = Self.defaultDestination(for: viewModel.repository.url, branch: branchName)
    }

    private static func availableExistingBranches(branches: [GitBranch], worktreeInfos: [WorktreeInfo]) -> [GitBranch] {
        let checkedOutBranches = Set(worktreeInfos.compactMap(\.worktree.branch))
        return branches.filter { !checkedOutBranches.contains($0.name) }
    }

    private static func defaultDestination(for repositoryURL: URL, branch: String) -> URL {
        repositoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(repositoryURL.lastPathComponent)-worktrees", isDirectory: true)
            .appendingPathComponent(pathComponent(for: branch), isDirectory: true)
    }

    private static func pathComponent(for branch: String) -> String {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "new-branch" : trimmed
        return fallback.replacingOccurrences(of: "/", with: "-")
    }
}

private enum WorktreeBranchMode: String, CaseIterable, Identifiable {
    case newBranch = "New branch"
    case existingBranch = "Existing branch"

    var id: String { rawValue }
}
