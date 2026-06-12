import SwiftUI

struct ActivityOverlay: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect()
        .padding(.top, 10)
    }
}
