import AppKit
import SwiftUI

struct CloneRepositorySheet: View {
    @ObservedObject var appModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var remoteURL = ""
    @State private var parentURL = CloneRepositorySheet.defaultParentDirectory()

    private static func defaultParentDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let developer = home.appendingPathComponent("Developer", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: developer.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return developer
        }
        return home
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            Form {
                repositorySection
                destinationSection
                statusSection
            }
            .formStyle(.grouped)

            Divider()
            buttonRow
        }
        .frame(width: 520)
        .onDisappear {
            appModel.cloneErrorMessage = nil
        }
    }

    private var sheetHeader: some View {
        HStack {
            Text("Clone Repository")
                .font(.title2.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var repositorySection: some View {
        Section {
            LabeledContent("Repository URL") {
                TextField("https://github.com/owner/repo.git", text: $remoteURL)
                    .textFieldStyle(.roundedBorder)
            }
        } header: {
            Text("Repository")
        } footer: {
            Text("Enter the remote repository URL to clone.")
                .foregroundStyle(.secondary)
        }
    }

    private var destinationSection: some View {
        Section {
            LabeledContent("Destination Folder") {
                HStack {
                    Text(parentURL.path)
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
            Text("Porcelain clones into a folder inside this destination.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let errorMessage = appModel.cloneErrorMessage {
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
                Task {
                    if await appModel.cloneRepository(from: remoteURL, into: parentURL) {
                        dismiss()
                    }
                }
            } label: {
                if appModel.isCloning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Clone")
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appModel.isCloning)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Destination"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            parentURL = url
        }
    }
}
