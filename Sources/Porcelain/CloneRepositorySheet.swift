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
        VStack(alignment: .leading, spacing: 16) {
            Text("Clone Repository")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Repository URL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("https://github.com/owner/repo.git", text: $remoteURL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Destination Folder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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
                }
            }

            if let errorMessage = appModel.cloneErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
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
                .buttonStyle(.borderedProminent)
                .disabled(remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appModel.isCloning)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onDisappear {
            appModel.cloneErrorMessage = nil
        }
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
