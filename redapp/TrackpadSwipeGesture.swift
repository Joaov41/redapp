import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Horizontal two-finger trackpad swipe (Magic Keyboard / Magic Trackpad).
///
/// SwiftUI's `DragGesture` only follows touches and click-drags, so a plain
/// two-finger swipe on a trackpad never reaches it. This recognizer listens to
/// trackpad scroll events only (`allowedTouchTypes` is empty), so finger swipes
/// on the screen keep going to the existing drag gestures untouched.
struct TrackpadSwipe {
    /// Horizontal travel so far, positive to the right (follows the fingers).
    var onChanged: (CGFloat) -> Void = { _ in }
    /// Final travel and horizontal velocity (points per second).
    var onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
}

#if os(iOS)
extension TrackpadSwipe: UIGestureRecognizerRepresentable {
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.allowedTouchTypes = []
        recognizer.allowedScrollTypesMask = .continuous
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let view = recognizer.view
        switch recognizer.state {
        case .began, .changed:
            onChanged(recognizer.translation(in: view).x)
        case .ended:
            onEnded(recognizer.translation(in: view).x, recognizer.velocity(in: view).x)
        case .cancelled, .failed:
            onEnded(0, 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        // Only take mostly-sideways swipes; vertical two-finger scrolling stays with the list.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

extension View {
    func trackpadSwipe(
        onChanged: @escaping (CGFloat) -> Void = { _ in },
        onEnded: @escaping (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    ) -> some View {
        gesture(TrackpadSwipe(onChanged: onChanged, onEnded: onEnded))
    }
}
#else
extension View {
    func trackpadSwipe(
        onChanged: @escaping (CGFloat) -> Void = { _ in },
        onEnded: @escaping (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    ) -> some View {
        self
    }
}
#endif
