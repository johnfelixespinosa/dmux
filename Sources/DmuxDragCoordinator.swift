import AppKit

/// Workspace-level drag gesture coordinator.
/// Determines intent from drag distance and target:
/// - Stays inside source pane → split (direction from drag vector)
/// - Crosses into another pane → merge
/// - Crosses into empty space → fork
@MainActor
final class DmuxDragCoordinator: ObservableObject {

    enum DragIntent: Equatable {
        case none
        case split(SplitDirection)
        case merge(targetPanelId: UUID)
        case fork(SplitDirection)
    }

    /// The modifier keys that activate dmux drag mode.
    static let activationModifiers: NSEvent.ModifierFlags = [.control, .shift]

    @Published private(set) var currentIntent: DragIntent = .none
    @Published private(set) var isDragging: Bool = false
    @Published private(set) var dragProgress: CGFloat = 0

    private(set) var sourcePanelId: UUID?
    private var dragStartPoint: NSPoint = .zero
    private var sourcePaneBounds: NSRect = .zero
    private let minDragThreshold: CGFloat = 30.0

    static func isActivated(event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .contains(activationModifiers)
    }

    func beginDrag(at point: NSPoint, sourcePanelId: UUID, sourcePaneBounds: NSRect) {
        self.isDragging = true
        self.dragStartPoint = point
        self.sourcePanelId = sourcePanelId
        self.sourcePaneBounds = sourcePaneBounds
        self.currentIntent = .none
        self.dragProgress = 0
    }

    func computeIntent(currentPoint: NSPoint, targetPanelId: UUID?) -> DragIntent {
        guard isDragging, let sourceId = sourcePanelId else { return .none }

        let dx = currentPoint.x - dragStartPoint.x
        let dy = currentPoint.y - dragStartPoint.y
        let distance = max(abs(dx), abs(dy))

        guard distance >= minDragThreshold else {
            currentIntent = .none
            dragProgress = 0
            return .none
        }

        let direction: SplitDirection
        if abs(dx) > abs(dy) {
            direction = dx > 0 ? .right : .left
        } else {
            direction = dy > 0 ? .up : .down
        }

        let insideSource = sourcePaneBounds.contains(currentPoint)

        let intent: DragIntent
        if insideSource {
            let maxDrag = direction.isHorizontal ? sourcePaneBounds.width : sourcePaneBounds.height
            dragProgress = min(1.0, distance / (maxDrag * 0.5))
            intent = .split(direction)
        } else if let targetId = targetPanelId, targetId != sourceId {
            dragProgress = min(1.0, distance / 200.0)
            intent = .merge(targetPanelId: targetId)
        } else {
            let maxDrag = direction.isHorizontal ? sourcePaneBounds.width : sourcePaneBounds.height
            dragProgress = min(1.0, distance / maxDrag)
            intent = .fork(direction)
        }

        currentIntent = intent
        return intent
    }

    func endDrag() -> (sourcePanelId: UUID?, intent: DragIntent) {
        let result = (sourcePanelId, currentIntent)
        isDragging = false
        sourcePanelId = nil
        currentIntent = .none
        dragProgress = 0
        return result
    }

    func cancelDrag() {
        isDragging = false
        sourcePanelId = nil
        currentIntent = .none
        dragProgress = 0
    }
}
