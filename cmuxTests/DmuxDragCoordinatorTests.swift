import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class DmuxDragCoordinatorTests: XCTestCase {

    @MainActor
    func test_toggleDragMode() {
        let coordinator = DmuxDragCoordinator()
        XCTAssertFalse(coordinator.dragModeActive)
        coordinator.toggleDragMode()
        XCTAssertTrue(coordinator.dragModeActive)
        coordinator.toggleDragMode()
        XCTAssertFalse(coordinator.dragModeActive)
    }

    @MainActor
    func test_beginDrag_requiresDragMode() {
        let coordinator = DmuxDragCoordinator()
        // Without drag mode, beginDrag should be a no-op
        coordinator.beginDrag(at: NSPoint(x: 100, y: 100), sourcePanelId: UUID(), sourcePaneBounds: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertFalse(coordinator.isDragging)
    }

    @MainActor
    func test_dragIntent_belowThreshold_returnsNone() {
        let coordinator = DmuxDragCoordinator()
        coordinator.toggleDragMode()
        let sourceId = UUID()
        coordinator.beginDrag(at: NSPoint(x: 100, y: 100), sourcePanelId: sourceId, sourcePaneBounds: NSRect(x: 0, y: 0, width: 400, height: 400))
        let intent = coordinator.computeIntent(currentPoint: NSPoint(x: 110, y: 105), targetPanelId: nil)
        XCTAssertEqual(intent, .none)
    }

    @MainActor
    func test_dragIntent_staysInsidePane_returnsSplitRight() {
        let coordinator = DmuxDragCoordinator()
        coordinator.toggleDragMode()
        let sourceId = UUID()
        coordinator.beginDrag(at: NSPoint(x: 100, y: 200), sourcePanelId: sourceId, sourcePaneBounds: NSRect(x: 0, y: 0, width: 400, height: 400))
        let intent = coordinator.computeIntent(currentPoint: NSPoint(x: 250, y: 200), targetPanelId: nil)
        if case .split(let dir) = intent {
            XCTAssertEqual(dir, .right)
        } else {
            XCTFail("Expected split intent, got \(intent)")
        }
    }

    @MainActor
    func test_dragIntent_staysInsidePane_returnsSplitDown() {
        let coordinator = DmuxDragCoordinator()
        coordinator.toggleDragMode()
        let sourceId = UUID()
        coordinator.beginDrag(at: NSPoint(x: 200, y: 100), sourcePanelId: sourceId, sourcePaneBounds: NSRect(x: 0, y: 0, width: 400, height: 400))
        let intent = coordinator.computeIntent(currentPoint: NSPoint(x: 200, y: 250), targetPanelId: nil)
        if case .split(let dir) = intent {
            XCTAssertEqual(dir, .down)
        } else {
            XCTFail("Expected split down, got \(intent)")
        }
    }

    @MainActor
    func test_dragIntent_crossesIntoPaneB_returnsMerge() {
        let coordinator = DmuxDragCoordinator()
        coordinator.toggleDragMode()
        let sourceId = UUID()
        let targetId = UUID()
        coordinator.beginDrag(at: NSPoint(x: 200, y: 200), sourcePanelId: sourceId, sourcePaneBounds: NSRect(x: 0, y: 0, width: 400, height: 400))
        let intent = coordinator.computeIntent(currentPoint: NSPoint(x: 500, y: 200), targetPanelId: targetId)
        if case .merge(let id) = intent {
            XCTAssertEqual(id, targetId)
        } else {
            XCTFail("Expected merge intent, got \(intent)")
        }
    }

    @MainActor
    func test_dragIntent_crossesIntoEmptySpace_returnsFork() {
        let coordinator = DmuxDragCoordinator()
        coordinator.toggleDragMode()
        let sourceId = UUID()
        coordinator.beginDrag(at: NSPoint(x: 200, y: 200), sourcePanelId: sourceId, sourcePaneBounds: NSRect(x: 0, y: 0, width: 400, height: 400))
        let intent = coordinator.computeIntent(currentPoint: NSPoint(x: 500, y: 200), targetPanelId: nil)
        if case .fork(let dir) = intent {
            XCTAssertEqual(dir, .right)
        } else {
            XCTFail("Expected fork intent, got \(intent)")
        }
    }

    @MainActor
    func test_endDrag_returnsLastIntentAndExitsDragMode() {
        let coordinator = DmuxDragCoordinator()
        coordinator.toggleDragMode()
        let sourceId = UUID()
        coordinator.beginDrag(at: NSPoint(x: 100, y: 100), sourcePanelId: sourceId, sourcePaneBounds: NSRect(x: 0, y: 0, width: 400, height: 400))
        _ = coordinator.computeIntent(currentPoint: NSPoint(x: 300, y: 100), targetPanelId: nil)
        let (panelId, intent) = coordinator.endDrag()
        XCTAssertEqual(panelId, sourceId)
        if case .split = intent { } else { XCTFail("Expected split") }
        XCTAssertFalse(coordinator.isDragging)
        XCTAssertFalse(coordinator.dragModeActive, "Drag mode should auto-exit after completing a gesture")
    }

    @MainActor
    func test_deactivateDragMode_cancelsActiveDrag() {
        let coordinator = DmuxDragCoordinator()
        coordinator.toggleDragMode()
        coordinator.beginDrag(at: .zero, sourcePanelId: UUID(), sourcePaneBounds: .zero)
        XCTAssertTrue(coordinator.isDragging)
        coordinator.deactivateDragMode()
        XCTAssertFalse(coordinator.isDragging)
        XCTAssertFalse(coordinator.dragModeActive)
        XCTAssertNil(coordinator.sourcePanelId)
    }
}
