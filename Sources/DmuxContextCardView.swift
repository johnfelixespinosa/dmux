import SwiftUI

/// Floating context card that appears during merge/fork drags.
/// Shows a preview of the context being transferred.
struct DmuxContextCardView: View {
    let contextPreview: String
    let transferType: TransferType
    let progress: CGFloat
    let position: CGPoint

    enum TransferType {
        case merge
        case fork
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "text.quote")
                    .font(.system(size: 10, weight: .semibold))
                Text(transferType == .merge ? "Context Transfer" : "Fork Context")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(accentColor)

            Text(contextPreview)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .shadow(color: accentColor.opacity(0.3), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accentColor.opacity(0.4), lineWidth: 1)
        )
        .frame(width: 200)
        .scaleEffect(0.5 + progress * 0.5)
        .opacity(Double(min(1, progress * 2)))
        .position(position)
    }

    private var accentColor: Color {
        transferType == .merge ? .orange : Color(red: 0.063, green: 0.725, blue: 0.506)
    }
}
