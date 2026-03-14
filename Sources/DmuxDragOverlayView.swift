import SwiftUI

/// Overlay view that renders drag animation state.
/// Driven entirely by DmuxDragCoordinator's published properties.
/// Renders above all panes but below the cursor.
struct DmuxDragOverlayView: View {
    @ObservedObject var coordinator: DmuxDragCoordinator
    let paneFrames: [UUID: CGRect]

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if coordinator.isDragging {
                    switch coordinator.currentIntent {
                    case .split(let direction):
                        splitPreview(direction: direction, progress: coordinator.dragProgress)

                    case .merge(let targetId):
                        mergeHighlight(targetId: targetId, progress: coordinator.dragProgress)

                    case .fork(let direction):
                        forkPreview(direction: direction, progress: coordinator.dragProgress)

                    case .none:
                        EmptyView()
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.8), value: coordinator.isDragging)
    }

    // MARK: - Split Preview

    @ViewBuilder
    private func splitPreview(direction: SplitDirection, progress: CGFloat) -> some View {
        if let sourceId = coordinator.sourcePanelId,
           let frame = paneFrames[sourceId] {
            if direction.isHorizontal {
                // Vertical line moving horizontally
                Rectangle()
                    .fill(Color(red: 0.506, green: 0.549, blue: 0.973)) // #818cf8
                    .frame(width: 2)
                    .frame(height: frame.height * min(1, progress + 0.3))
                    .position(
                        x: frame.midX + (direction == .right ? 1 : -1) * frame.width * 0.5 * progress,
                        y: frame.midY
                    )
                    .shadow(color: Color(red: 0.506, green: 0.549, blue: 0.973).opacity(0.5), radius: 12)
                    .opacity(Double(min(1, progress * 2)))
            } else {
                // Horizontal line moving vertically
                Rectangle()
                    .fill(Color(red: 0.753, green: 0.522, blue: 0.988)) // #c084fc
                    .frame(height: 2)
                    .frame(width: frame.width * min(1, progress + 0.3))
                    .position(
                        x: frame.midX,
                        y: frame.midY + (direction == .down ? 1 : -1) * frame.height * 0.5 * progress
                    )
                    .shadow(color: Color(red: 0.753, green: 0.522, blue: 0.988).opacity(0.5), radius: 12)
                    .opacity(Double(min(1, progress * 2)))
            }
        }
    }

    // MARK: - Merge Highlight

    @ViewBuilder
    private func mergeHighlight(targetId: UUID, progress: CGFloat) -> some View {
        if let frame = paneFrames[targetId] {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange, lineWidth: 3)
                .shadow(color: Color.orange.opacity(0.4), radius: 20)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .opacity(Double(min(1, progress * 1.5)))
        }
    }

    // MARK: - Fork Preview

    @ViewBuilder
    private func forkPreview(direction: SplitDirection, progress: CGFloat) -> some View {
        if let sourceId = coordinator.sourcePanelId,
           let frame = paneFrames[sourceId] {
            let color = Color(red: 0.063, green: 0.725, blue: 0.506) // #10b981
            if direction.isHorizontal {
                Rectangle()
                    .fill(color)
                    .frame(width: 2)
                    .frame(height: frame.height)
                    .position(
                        x: direction == .right ? frame.maxX : frame.minX,
                        y: frame.midY
                    )
                    .shadow(color: color.opacity(0.5), radius: 12)
                    .opacity(Double(min(1, progress * 2)))
            } else {
                Rectangle()
                    .fill(color)
                    .frame(height: 2)
                    .frame(width: frame.width)
                    .position(
                        x: frame.midX,
                        y: direction == .down ? frame.maxY : frame.minY
                    )
                    .shadow(color: color.opacity(0.5), radius: 12)
                    .opacity(Double(min(1, progress * 2)))
            }
        }
    }
}
