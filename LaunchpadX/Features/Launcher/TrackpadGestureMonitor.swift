import AppKit
import SwiftUI

enum TrackpadGesture: Equatable {
    case previousPage
    case nextPage
    case dismiss
}

struct OptionModifierState {
    private(set) var isPressed = false

    mutating func update(modifiers: NSEvent.ModifierFlags) -> Bool? {
        let next = modifiers.contains(.option)
        guard next != isPressed else { return nil }
        isPressed = next
        return next
    }
}

struct TrackpadGestureClassifier {
    private var horizontalDistance: CGFloat = 0
    private var verticalDistance: CGFloat = 0
    private var hasRecognizedGesture = false
    // Lower than the old 46 pt threshold so a deliberate two-finger flick
    // changes pages before the gesture has lost its momentum.
    private let threshold: CGFloat = 24

    mutating func consume(
        horizontal: CGFloat,
        vertical: CGFloat,
        reversesPageDirection: Bool = false
    ) -> TrackpadGesture? {
        guard !hasRecognizedGesture else { return nil }
        horizontalDistance += horizontal
        verticalDistance += vertical

        if abs(horizontalDistance) >= threshold, abs(horizontalDistance) > abs(verticalDistance) * 1.35 {
            hasRecognizedGesture = true
            let nativeGesture: TrackpadGesture = horizontalDistance > 0 ? .nextPage : .previousPage
            guard reversesPageDirection else { return nativeGesture }
            return nativeGesture == .nextPage ? .previousPage : .nextPage
        }
        if verticalDistance <= -threshold, abs(verticalDistance) > abs(horizontalDistance) * 1.35 {
            hasRecognizedGesture = true
            return .dismiss
        }
        return nil
    }

    mutating func reset() {
        horizontalDistance = 0
        verticalDistance = 0
        hasRecognizedGesture = false
    }
}

struct TrackpadGestureMonitor: NSViewRepresentable {
    let gridMode: LauncherGridMode
    let reversesPageDirection: Bool
    let handleGesture: (TrackpadGesture) -> Bool
    let onOptionStateChanged: (Bool) -> Void
    let handleKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            gridMode: gridMode,
            reversesPageDirection: reversesPageDirection,
            handleGesture: handleGesture,
            onOptionStateChanged: onOptionStateChanged,
            handleKeyDown: handleKeyDown
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.gridMode = gridMode
        context.coordinator.reversesPageDirection = reversesPageDirection
        context.coordinator.handleGesture = handleGesture
        context.coordinator.onOptionStateChanged = onOptionStateChanged
        context.coordinator.handleKeyDown = handleKeyDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        weak var hostView: NSView?
        var gridMode: LauncherGridMode
        var reversesPageDirection: Bool
        var handleGesture: (TrackpadGesture) -> Bool
        var onOptionStateChanged: (Bool) -> Void
        var handleKeyDown: (NSEvent) -> Bool
        private var classifier = TrackpadGestureClassifier()
        private var optionModifierState = OptionModifierState()
        private var monitor: Any?

        init(
            gridMode: LauncherGridMode,
            reversesPageDirection: Bool,
            handleGesture: @escaping (TrackpadGesture) -> Bool,
            onOptionStateChanged: @escaping (Bool) -> Void,
            handleKeyDown: @escaping (NSEvent) -> Bool
        ) {
            self.gridMode = gridMode
            self.reversesPageDirection = reversesPageDirection
            self.handleGesture = handleGesture
            self.onOptionStateChanged = onOptionStateChanged
            self.handleKeyDown = handleKeyDown
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .flagsChanged, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .flagsChanged {
                    if let isPressed = self.optionModifierState.update(modifiers: event.modifierFlags) {
                        self.onOptionStateChanged(isPressed)
                    }
                    return event
                }
                guard event.window === self.hostView?.window else { return event }
                switch event.type {
                case .scrollWheel:
                    return self.handleScroll(event)
                case .keyDown:
                    return self.handleKeyDown(event) ? nil : event
                default:
                    return event
                }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if optionModifierState.update(modifiers: []) != nil {
                onOptionStateChanged(false)
            }
        }

        private func handleScroll(_ event: NSEvent) -> NSEvent? {
            guard event.hasPreciseScrollingDeltas else { return event }
            // Vertical-scroll mode uses AppKit's native scroll view. Capturing
            // its upward deltas here used to interpret scrolling toward the
            // top as a swipe-to-dismiss gesture.
            guard gridMode == .pages else {
                classifier.reset()
                return event
            }
            if !event.momentumPhase.isEmpty {
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    classifier.reset()
                }
                return event
            }
            if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
                classifier.reset()
            }
            if event.phase.contains(.cancelled) {
                classifier.reset()
                return event
            }
            let direction: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
            let gesture = classifier.consume(
                horizontal: event.scrollingDeltaX * direction,
                vertical: event.scrollingDeltaY * direction,
                reversesPageDirection: reversesPageDirection
            )
            if let gesture { _ = handleGesture(gesture) }
            if event.phase.contains(.ended) { classifier.reset() }
            // Do not remove a packet from AppKit's scroll stream. The page
            // change is handled independently and all other scrolling stays native.
            return event
        }
    }
}
