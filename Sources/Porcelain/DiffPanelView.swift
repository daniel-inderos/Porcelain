import SwiftUI
import PorcelainCore

struct DiffPanelView: View {
    let diff: DiffContent
    @Binding var mode: DiffMode

    var body: some View {
        Group {
            if diff.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyDiffView()
            } else if diff.isBinary {
                BinaryDiffView(diff: diff)
            } else {
                switch mode {
                case .unified:
                    UnifiedDiffView(text: diff.text)
                case .sideBySide:
                    SideBySideDiffView(text: diff.text)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            diffHeader
        }
        .background(.background)
    }

    private var diffHeader: some View {
        GlassEffectContainer(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(diff.path.isEmpty ? "Diff" : diff.path)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if diff.didTruncate {
                        Text("Preview truncated")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Picker("Diff Mode", selection: $mode) {
                    ForEach(DiffMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
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

private struct EmptyDiffView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Select a file to inspect its diff.")
                .font(.headline)
            Text("Binary, missing, and very large files are summarized here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BinaryDiffView: View {
    let diff: DiffContent

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Binary file")
                .font(.headline)
            Text(diff.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct UnifiedDiffView: View {
    let text: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .background(line.background)
                        .foregroundStyle(line.foreground)
                }
            }
            .frame(minWidth: 700, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var diffLines: [RenderedDiffLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { RenderedDiffLine(String($0)) }
    }
}

private struct SideBySideDiffView: View {
    let text: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, rawLine in
                    let line = String(rawLine)
                    HStack(spacing: 0) {
                        Text(leftText(for: line))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 420, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                            .background(leftBackground(for: line))
                            .textSelection(.enabled)
                        Divider()
                        Text(rightText(for: line))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 420, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                            .background(rightBackground(for: line))
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(minWidth: 860, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private func leftText(for line: String) -> String {
        if isAddition(line) { return "" }
        return trimmedMarker(line)
    }

    private func rightText(for line: String) -> String {
        if isDeletion(line) { return "" }
        return trimmedMarker(line)
    }

    private func leftBackground(for line: String) -> Color {
        isDeletion(line) ? Color.red.opacity(0.14) : Color.clear
    }

    private func rightBackground(for line: String) -> Color {
        isAddition(line) ? Color.green.opacity(0.14) : Color.clear
    }

    private func trimmedMarker(_ line: String) -> String {
        guard line.first == "+" || line.first == "-" || line.first == " " else { return line }
        return String(line.dropFirst())
    }

    private func isAddition(_ line: String) -> Bool {
        line.hasPrefix("+") && !line.hasPrefix("+++")
    }

    private func isDeletion(_ line: String) -> Bool {
        line.hasPrefix("-") && !line.hasPrefix("---")
    }
}

private struct RenderedDiffLine {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var background: Color {
        if text.hasPrefix("+") && !text.hasPrefix("+++") {
            return Color.green.opacity(0.16)
        }
        if text.hasPrefix("-") && !text.hasPrefix("---") {
            return Color.red.opacity(0.16)
        }
        if text.hasPrefix("@@") {
            return Color.accentColor.opacity(0.14)
        }
        return Color.clear
    }

    var foreground: Color {
        if text.hasPrefix("diff --git") || text.hasPrefix("index ") {
            return .secondary
        }
        return .primary
    }
}
