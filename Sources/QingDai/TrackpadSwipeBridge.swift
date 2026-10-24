import AppKit
import SwiftUI

struct TrackpadSwipeBridge: NSViewRepresentable {
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> TrackpadSwipeView {
        let view = TrackpadSwipeView()
        view.onChange = onChange
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ nsView: TrackpadSwipeView, context: Context) {
        nsView.onChange = onChange
        nsView.onEnd = onEnd
    }

    static func dismantleNSView(_ nsView: TrackpadSwipeView, coordinator: ()) {
        nsView.detach()
    }
}

final class TrackpadSwipeView: NSView {
    var onChange: ((CGFloat) -> Void)?
    var onEnd: ((CGFloat) -> Void)?
    private var isDetached = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            TrackpadSwipeCoordinator.shared.unregister(self)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !isDetached {
            TrackpadSwipeCoordinator.shared.register(self)
        }
    }

    func detach() {
        isDetached = true
        TrackpadSwipeCoordinator.shared.unregister(self)
        onChange = nil
        onEnd = nil
    }

    fileprivate var isAvailable: Bool {
        guard !isDetached, let window, window.isVisible,
              !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return false }
        var ancestor: NSView? = self
        while let current = ancestor {
            if current.alphaValue < 0.01 { return false }
            ancestor = current.superview
        }
        return true
    }

    fileprivate func contains(_ event: NSEvent) -> Bool {
        guard isAvailable, event.window === window else { return false }
        return visibleRect.contains(convert(event.locationInWindow, from: nil))
    }
}

private final class TrackpadSwipeCoordinator {
    static let shared = TrackpadSwipeCoordinator()

    private final class WeakView {
        weak var value: TrackpadSwipeView?
        init(_ value: TrackpadSwipeView) { self.value = value }
    }

    private final class Session {
        enum Axis { case undecided, horizontal, vertical }

        weak var owner: TrackpadSwipeView?
        weak var window: NSWindow?
        var x: CGFloat = 0
        var y: CGFloat = 0
        var axis = Axis.undecided

        init(owner: TrackpadSwipeView) {
            self.owner = owner
            window = owner.window
        }
    }

    private var views: [WeakView] = []
    private var monitor: Any?
    private var watchdog: Timer?
    private var session: Session?
    private weak var momentumWindow: NSWindow?
    private var swallowsMomentum = false

    func register(_ view: TrackpadSwipeView) {
        views.removeAll { $0.value == nil || $0.value === view }
        views.append(WeakView(view))
        guard monitor == nil else { return }
        // One monitor owns the entire gesture, even when its row disappears.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func unregister(_ view: TrackpadSwipeView) {
        if session?.owner === view {
            // AppKit can detach this view during a SwiftUI render transaction.
            finish(cancelled: true, deferCallback: true)
        }
        views.removeAll { $0.value == nil || $0.value === view }
        if views.isEmpty {
            watchdog?.invalidate()
            watchdog = nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            session = nil
            swallowsMomentum = false
            momentumWindow = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.hasPreciseScrollingDeltas else { return event }

        if !event.momentumPhase.isEmpty {
            // A missing terminal event must never turn momentum into a commit.
            if session != nil { finish(cancelled: true) }
            let swallow = swallowsMomentum && event.window === momentumWindow
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                swallowsMomentum = false
                momentumWindow = nil
            }
            return swallow ? nil : event
        }

        if event.phase.contains(.began) {
            finish(cancelled: true)
            swallowsMomentum = false
            momentumWindow = nil
            views.removeAll { $0.value == nil }
            guard let owner = views.reversed().compactMap(\.value).first(where: { $0.contains(event) }) else {
                return event
            }
            session = Session(owner: owner)
        }

        // Never join a gesture in progress, including one that began on another row.
        guard let session else { return event }
        guard let owner = session.owner, owner.isAvailable,
              event.window === session.window, owner.window === session.window else {
            let swallow = session.axis == .horizontal && event.window === session.window
            finish(cancelled: true)
            return swallow ? nil : event
        }

        if event.phase.contains(.cancelled) {
            let swallow = session.axis == .horizontal
            finish(cancelled: true)
            return swallow ? nil : event
        }

        // Phase-less mouse-wheel events cannot start or advance a trackpad swipe.
        guard !event.phase.isEmpty else { return event }
        session.x += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        session.y += event.scrollingDeltaY

        if session.axis == .undecided {
            let horizontal = abs(session.x)
            let vertical = abs(session.y)
            if horizontal >= 8, horizontal > vertical * 1.35 {
                session.axis = .horizontal
            } else if vertical >= 8 {
                session.axis = .vertical
            }
        }

        let swallow = session.axis == .horizontal
        if event.phase.contains(.ended) {
            finish(cancelled: false)
        } else {
            armWatchdog()
            if swallow { owner.onChange?(session.x) }
        }
        return swallow ? nil : event
    }

    private func armWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            // Interrupted gestures spring back; elapsed time never completes a task.
            self?.finish(cancelled: true)
        }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finish(cancelled: Bool, deferCallback: Bool = false) {
        watchdog?.invalidate()
        watchdog = nil
        guard let current = session else { return }
        session = nil
        guard current.axis == .horizontal else { return }
        swallowsMomentum = true
        momentumWindow = current.window
        guard let callback = current.owner?.onEnd else { return }
        let distance = cancelled ? 0 : current.x
        if deferCallback {
            DispatchQueue.main.async { callback(distance) }
        } else {
            callback(distance)
        }
    }
}
