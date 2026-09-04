import SwiftUI
import AppKit

/// Transparent input layer over the graph canvas.
///
/// SwiftUI gestures reach neither the scroll wheel, the middle button, nor
/// pointer hover, and `MagnificationGesture` only reports a cumulative scale
/// with no anchor. All graph input therefore comes through this AppKit view,
/// which speaks to the engine in view coordinates.
struct GraphInputSurface: NSViewRepresentable {
    @ObservedObject var engine: GraphEngine

    func makeNSView(context: Context) -> GraphInputView {
        let view = GraphInputView()
        view.engine = engine
        return view
    }

    func updateNSView(_ view: GraphInputView, context: Context) {
        view.engine = engine
    }
}

final class GraphInputView: NSView {
    weak var engine: GraphEngine?

    private var trackingArea: NSTrackingArea?
    private var leftDown = false
    private var middlePanning = false
    private var orbiting = false
    private var dragDistance: CGFloat = 0
    private var lastMiddlePoint: CGPoint = .zero

    /// Distance in points a press may travel and still count as a click.
    private static let clickSlop: CGFloat = 3
    /// Zoom per notch of a non-precise wheel.
    private static let wheelZoomStep: CGFloat = 1.15
    /// Trackpad twist is reported in degrees; the engine orbits in pixels.
    private static let twistToPixels: CGFloat = 2.5

    /// Match SwiftUI's top-left origin so no coordinate flipping is needed.
    override var isFlipped: Bool { true }
    /// Never take first responder: scroll and gesture events arrive by hit
    /// testing anyway, and holding focus would swallow Escape and ⌘-shortcuts
    /// that the SwiftUI hierarchy handles.
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The window is movable by its background, and this is a transparent
    /// overlay — so without this a drag across the canvas slid the whole
    /// window instead of panning the graph.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: Hover

    override func mouseMoved(with event: NSEvent) {
        engine?.setHover(engine?.hitTest(viewPoint: location(event)))
        applyCursor()
    }

    override func mouseExited(with event: NSEvent) {
        engine?.setHover(nil)
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor()
    }

    private func applyCursor() {
        if middlePanning || orbiting {
            NSCursor.closedHand.set()
        } else if engine?.hoveredIndex != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: Left button - orbit, drag a node, or pan the canvas

    override func mouseDown(with event: NSEvent) {
        let point = location(event)
        leftDown = true
        dragDistance = 0
        // Shift claims the drag for the camera, so a plain drag keeps meaning
        // exactly what it always did: move a node, or pan.
        if event.modifierFlags.contains(.shift), engine?.is3D == true {
            orbiting = true
            engine?.setHover(nil)
            applyCursor()
            return
        }
        engine?.setHover(engine?.hitTest(viewPoint: point))
        engine?.beginPrimaryDrag(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard leftDown else { return }
        dragDistance += hypot(event.deltaX, event.deltaY)
        if orbiting {
            engine?.orbitBy(dx: Double(event.deltaX), dy: Double(event.deltaY))
            return
        }
        engine?.continuePrimaryDrag(to: location(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard leftDown else { return }
        leftDown = false
        if orbiting {
            orbiting = false
            applyCursor()
            return
        }
        engine?.endPrimaryDrag(at: location(event), moved: dragDistance > Self.clickSlop)
        applyCursor()
    }

    // MARK: Middle button - pan

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        middlePanning = true
        lastMiddlePoint = location(event)
        applyCursor()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard middlePanning else { return super.otherMouseDragged(with: event) }
        let point = location(event)
        engine?.panBy(CGSize(width: point.x - lastMiddlePoint.x, height: point.y - lastMiddlePoint.y))
        lastMiddlePoint = point
    }

    override func otherMouseUp(with event: NSEvent) {
        guard middlePanning else { return super.otherMouseUp(with: event) }
        middlePanning = false
        applyCursor()
    }

    // MARK: Wheel and trackpad

    override func scrollWheel(with event: NSEvent) {
        guard let engine else { return }
        let point = location(event)
        let wantsZoom = event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.option)

        // Precise deltas mean a trackpad or Magic Mouse: two fingers pan, the
        // way dragging the canvas does. A notched wheel zooms instead.
        if event.hasPreciseScrollingDeltas && !wantsZoom {
            // In 3D the same two fingers orbit, since panning a projection you
            // cannot turn is close to useless; shift falls back to panning.
            if engine.is3D && !event.modifierFlags.contains(.shift) {
                engine.orbitBy(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY))
                return
            }
            // Use the delta as macOS reports it, so the canvas follows the
            // user's own natural-scrolling preference.
            engine.panBy(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            engine.setHover(engine.hitTest(viewPoint: point))
            return
        }

        // A precise device held with a zoom modifier reports pixels, not notches.
        let notches = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / 40
            : event.scrollingDeltaY
        guard notches != 0 else { return }
        engine.zoomBy(pow(Self.wheelZoomStep, notches), around: point)
    }

    // MARK: Multitouch gestures

    override func magnify(with event: NSEvent) {
        guard let engine else { return }
        // `magnification` is the increment for this event, so it composes
        // directly into the running zoom.
        if engine.is3D {
            // Pinching out means "get closer", which is a shorter camera
            // distance rather than a bigger picture.
            engine.dollyBy(1 - Double(event.magnification))
        } else {
            engine.zoomBy(1 + event.magnification, around: location(event))
        }
    }

    override func rotate(with event: NSEvent) {
        guard let engine, engine.is3D else { return }
        engine.orbitBy(dx: Double(CGFloat(event.rotation) * Self.twistToPixels), dy: 0)
    }

    override func smartMagnify(with event: NSEvent) {
        engine?.fitToView()
    }
}
