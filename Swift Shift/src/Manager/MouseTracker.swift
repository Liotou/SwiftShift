import Cocoa
import Accessibility
import CGEventSupervisor
enum MouseAction: String { case move, resize, none }
enum Quadrant { case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight }
private enum MouseLocationCoordinateSpace { case appKit, coreGraphics }
class MouseTracker {
    static let shared = MouseTracker()
    private var mouseEventMonitor: Any?, initialMouseLocation, initialWindowLocation: NSPoint?
    private var trackedWindow: AXUIElement?, trackedWindowIsFocused = false, shouldFocusWindow = false
    private var currentAction: MouseAction = .none, trackingTimer: Timer?
    private let trackingTimeout: TimeInterval = 10
    private var shouldUseQuadrants = false, quadrant: Quadrant?, windowSize: CGSize?, isTracking = false
    private var spaceChangeObserver: Any?, pendingMouseLocation: NSPoint?
    private var snapRects: [CGRect] = []
    private let snapDistance: CGFloat = 10
    private var mouseLocationCoordinateSpace: MouseLocationCoordinateSpace = .appKit
    private let trackingQueue = DispatchQueue(label: "com.swiftshift.mousetracker")
    private var queuedExternalMouseUpdate: (location: NSPoint, timestamp: TimeInterval)?
    private var queuedExternalMouseUpdateScheduled = false
    private var enhancedUIApp: AXUIElement?
    private var enhancedUIPrev: Bool?
    private var cursorBeforeGesture: NSCursor?
    private var isOverridingCursor = false
    private var pinnedCursor: NSCursor?
    private var cursorPinTimer: DispatchSourceTimer?
    private var titleBarDrag: TitleBarDrag?
    private lazy var cursorStandIn = CursorStandInWindow()
    private init() { registerForSpaceChangeNotifications() }
    deinit { unregisterForSpaceChangeNotifications() }
    private func registerForSpaceChangeNotifications() {
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.handleSpaceChange() }
    }
    private func unregisterForSpaceChangeNotifications() { if let obs = spaceChangeObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) } }
    private func handleSpaceChange() {
        guard currentAction != .none, trackedWindow != nil else { return }
        if isTracking { forceResetTracking() }
    }
    func startTracking(for action: MouseAction, button: MouseButton) {
        if currentAction != .none { stopTracking(for: currentAction) }
        prepareTracking(for: action, mouseLocation: NSEvent.mouseLocation, coordinateSpace: .appKit)
        guard trackedWindow != nil else { return }
        // A keyboard move becomes a native drag of the title bar when the window has a safe point to
        // press (see `armTitleBarDrag`); otherwise, and for every other gesture, the window follows
        // the pointer through AX writes.
        let isNative = action == .move && button == .none && armTitleBarDrag()
        if !isNative { registerMouseEventMonitor(button: button) }
        startTrackingTimer(); isTracking = true; applyCursor()
    }
    @discardableResult
    func startTrackingForExternalMouseUpdates(for action: MouseAction, initialMouseLocation: NSPoint) -> Bool {
        if currentAction != .none { stopTracking(for: currentAction) }
        prepareTracking(for: action, mouseLocation: initialMouseLocation, coordinateSpace: .coreGraphics)
        guard trackedWindow != nil else {
            return false
        }
        isTracking = true
        startTrackingTimer()
        applyCursor()
        return true
    }
    func stopTracking(for action: MouseAction) {
        guard currentAction == action else { return }
        let cursorHandedBackLater = endTitleBarDrag()
        // Apply the final pending move/resize while Enhanced UI is still disabled (fast path),
        // then restore the attribute, then run the remaining cleanup.
        flushQueuedExternalMouseUpdate(); flushPendingMouseUpdate()
        AXWindowWriter.shared.endGesture()
        restoreEnhancedUIForTrackedApp()
        invalidateTrackingTimer(); removeMouseEventMonitor(); resetTrackingVariables(); clearQueuedExternalMouseUpdate(); isTracking = false
        if !cursorHandedBackLater { resetCursor() }
    }
    /// Cursor shown while a move/resize gesture is armed or in progress, since the
    /// tracked window belongs to another app and won't show one for a gesture it
    /// knows nothing about. Needs `BackgroundCursor.enable()` first: the Window
    /// Server ignores `NSCursor.set()` from an app that isn't frontmost, and
    /// SwiftShift never becomes frontmost during a gesture (that would steal
    /// keyboard focus from the window being dragged).
    ///
    /// The app under the pointer re-asserts its own cursor rects as the pointer
    /// moves across it — and while a window is being dragged, its views slide
    /// under a stationary pointer, so it does that constantly. Both of us write
    /// the cursor in reaction to the same mouse-moved event and the last writer
    /// wins, which alternates and reads as flicker. So rather than only writing
    /// on each event, pin the cursor for the whole gesture: a frame-rate timer
    /// re-applies it, bounding how long a competing cursor can stay on screen to
    /// well under one frame.
    private func applyCursor() {
        guard isTracking else { return }
        BackgroundCursor.enable()
        if !isOverridingCursor {
            // Remember what the app under the pointer was showing, to hand the
            // cursor back on mouse-up instead of forcing a possibly-wrong arrow.
            cursorBeforeGesture = NSCursor.currentSystem
            isOverridingCursor = true
        }
        let cursor = cursor(for: currentAction)
        pinnedCursor = cursor
        cursor.set()
        startCursorPinTimer()
    }
    /// Re-applies the pinned cursor well above display refresh rate. A `Timer`
    /// coalesces and is bound to run loop modes; a dispatch timer with no leeway
    /// keeps firing at a steady rate through event tracking, which is exactly
    /// when a drag is happening.
    private func startCursorPinTimer() {
        guard cursorPinTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 240.0, leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            // Reads `pinnedCursor` rather than recomputing from `currentAction`,
            // which `stopTracking` clears before the cursor is handed back.
            guard let self, self.isOverridingCursor, let cursor = self.pinnedCursor else { return }
            cursor.set()
        }
        timer.resume()
        cursorPinTimer = timer
    }
    private func resetCursor() {
        cursorPinTimer?.cancel()
        cursorPinTimer = nil
        pinnedCursor = nil
        guard isOverridingCursor else { return }
        isOverridingCursor = false
        (cursorBeforeGesture ?? .arrow).set()
        cursorBeforeGesture = nil
    }
    private func cursor(for action: MouseAction) -> NSCursor {
        switch action {
        case .move: return .closedHand
        case .resize: return resizeCursor()
        case .none: return .arrow
        }
    }
    /// AppKit has no public diagonal resize cursor, so corner quadrants — and the
    /// no-quadrants default, which always resizes diagonally from the bottom-right —
    /// fall back to a crosshair.
    private func resizeCursor() -> NSCursor {
        guard shouldUseQuadrants, let quadrant else { return .crosshair }
        switch quadrant {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .topRight, .bottomLeft, .bottomRight, .center: return .crosshair
        }
    }
    private static let enhancedUIAttribute = "AXEnhancedUserInterface" as CFString
    /// Disables `AXEnhancedUserInterface` on the tracked window's app for the duration of a
    /// move/resize gesture, remembering the previous value so it can be restored on mouse-up.
    /// Chromium/Electron apps enable this attribute while an AX client is active, which makes
    /// AX `kAXPosition`/`kAXSize` updates slow and non-live (laggy drag/resize) even though native
    /// title-bar drag / corner-resize of the same window stays smooth. Apps that don't set the
    /// attribute (most native AppKit apps) are unaffected. Public AX API, no SIP.
    private func disableEnhancedUIForTrackedApp() {
        guard let window = trackedWindow else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid > 0 else { return }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let readOK = AXUIElementCopyAttributeValue(app, MouseTracker.enhancedUIAttribute, &value) == .success
        var wasOn = false
        if readOK, let v = value, CFGetTypeID(v) == CFBooleanGetTypeID() { wasOn = CFBooleanGetValue((v as! CFBoolean)) }
        enhancedUIApp = app
        enhancedUIPrev = readOK ? wasOn : nil
        if wasOn { AXUIElementSetAttributeValue(app, MouseTracker.enhancedUIAttribute, kCFBooleanFalse) }
    }
    /// Restores the tracked app's `AXEnhancedUserInterface` to the value captured when the gesture
    /// began (only when it was originally enabled) and clears the saved reference.
    private func restoreEnhancedUIForTrackedApp() {
        if let app = enhancedUIApp, enhancedUIPrev == true {
            AXUIElementSetAttributeValue(app, MouseTracker.enhancedUIAttribute, kCFBooleanTrue)
        }
        enhancedUIApp = nil
        enhancedUIPrev = nil
    }
    func forceResetTracking() {
        guard currentAction != .none, let window = trackedWindow else { return }
        // Wait out any in-flight background write first, so the geometry read
        // below reflects everything actually applied to the window.
        AXWindowWriter.shared.synchronize()
        initialMouseLocation = currentMouseLocation()
        // A busy app can time out the re-read; keep the previous baseline then —
        // a slightly stale anchor beats a dead gesture (nil aborts every update).
        if let position = WindowManager.getPosition(window: window) { initialWindowLocation = position }
        if let size = WindowManager.getSize(window: window) { windowSize = size }
        pendingMouseLocation = nil
        AXWindowWriter.shared.reset(origin: initialWindowLocation, size: windowSize)
        if currentAction == .resize, shouldUseQuadrants, let m = initialMouseLocation, let w = initialWindowLocation, let s = windowSize {
            quadrant = determineQuadrant(mouseLocation: windowBoundsMouseLocation(m), windowSize: s, windowLocation: w)
        }
        applyCursor()
    }
    private func prepareTracking(for action: MouseAction, mouseLocation: NSPoint, coordinateSpace: MouseLocationCoordinateSpace) {
        // A double-tap maximize/restore glide shares AXWindowWriter with this
        // gesture. Cancel it first so an in-flight animation can't keep writing
        // frames for the wrong window (or detach the writer mid-drag when it finishes).
        WindowSnapActionRunner.shared.cancelAnimation()
        mouseLocationCoordinateSpace = coordinateSpace
        let currentWindow = coordinateSpace == .coreGraphics ? WindowManager.getCurrentWindow(at: mouseLocation) : WindowManager.getCurrentWindow()
        guard let currentWindow = currentWindow, !shouldIgnore(window: currentWindow) else { trackedWindow = nil; return }
        shouldFocusWindow = PreferencesManager.loadBool(for: .focusOnApp)
        shouldUseQuadrants = PreferencesManager.loadBool(for: .useQuadrants)
        trackedWindowIsFocused = false; currentAction = action; initialMouseLocation = mouseLocation
        trackedWindow = currentWindow; initialWindowLocation = WindowManager.getPosition(window: currentWindow)
        windowSize = WindowManager.getSize(window: currentWindow); pendingMouseLocation = nil
        snapRects = PreferencesManager.loadBool(for: .snapToWindows, defaultValue: true)
            ? WindowManager.getVisibleWindowRects(excluding: currentWindow)
            : []
        AXWindowWriter.shared.beginGesture(window: currentWindow, origin: initialWindowLocation, size: windowSize)
        if action == .resize && shouldUseQuadrants, let m = initialMouseLocation, let w = initialWindowLocation, let s = windowSize {
            quadrant = determineQuadrant(mouseLocation: windowBoundsMouseLocation(m), windowSize: s, windowLocation: w)
        }
        disableEnhancedUIForTrackedApp()
    }
    private func shouldIgnore(window: AXUIElement) -> Bool {
        guard let app = WindowManager.getNSApplication(from: window), let bid = app.bundleIdentifier, PreferencesManager.isAppIgnored(bid) else { return false }
        return true
    }
    private func verticalDelta(from initial: NSPoint, to current: NSPoint) -> CGFloat {
        switch mouseLocationCoordinateSpace {
        case .appKit:
            return current.y - initial.y
        case .coreGraphics:
            return initial.y - current.y
        }
    }
    private func windowBoundsMouseLocation(_ mouseLocation: NSPoint) -> NSPoint {
        switch mouseLocationCoordinateSpace {
        case .appKit:
            return mouseLocation
        case .coreGraphics:
            return WindowManager.convertYCoordinateBecauseTheAreTwoFuckingCoordinateSystems(point: mouseLocation)
        }
    }
    private func determineQuadrant(mouseLocation: NSPoint, windowSize: CGSize, windowLocation: NSPoint) -> Quadrant {
        let b = WindowManager.getWindowBounds(windowLocation: windowLocation, windowSize: windowSize)
        let cSize = 0.25, sSize = (1 - cSize) / 2
        let tx = (b.topRight.x - b.topLeft.x) * sSize, ty = (b.topLeft.y - b.bottomLeft.y) * sSize
        let lx = b.topLeft.x + tx, rx = b.topRight.x - tx, tyP = b.topLeft.y - ty, by = b.bottomLeft.y + ty
        switch (mouseLocation.x, mouseLocation.y) {
            case (..<lx, tyP...): return .topLeft
            case (lx..<rx, tyP...): return .top
            case (rx..., tyP...): return .topRight
            case (..<lx, by..<tyP): return .left
            case (lx..<rx, by..<tyP): return .center
            case (rx..., by..<tyP): return .right
            case (..<lx, ..<by): return .bottomLeft
            case (lx..<rx, ..<by): return .bottom
            default: return .bottomRight
        }
    }
    private func registerMouseEventMonitor(button: MouseButton) {
        removeMouseEventMonitor()
        let mask: NSEvent.EventTypeMask
        switch button {
        case .left:
            mask = .leftMouseDragged
        case .right:
            mask = .rightMouseDragged
        case .both:
            mask = [.leftMouseDragged, .rightMouseDragged]
        case .none:
            mask = .mouseMoved
        }
        mouseEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [mask]) { [weak self] e in self?.handleMouseMoved(e) }
    }
    private func startTrackingTimer() {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: trackingTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.stopTracking(for: self.currentAction)
        }
    }
    private func handleMouseMoved(_ event: NSEvent) {
        updateTrackingFromCurrentMouseLocation(timestamp: event.timestamp)
    }
    func updateTrackingFromCurrentMouseLocation(timestamp: TimeInterval) {
        updateTracking(withMouseLocation: currentMouseLocation(), timestamp: timestamp)
    }
    func queueExternalMouseUpdate(withMouseLocation mouseLocation: NSPoint, timestamp: TimeInterval) {
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            self.queuedExternalMouseUpdate = (mouseLocation, timestamp)
            guard !self.queuedExternalMouseUpdateScheduled else { return }
            self.queuedExternalMouseUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in self?.drainQueuedExternalMouseUpdate() }
        }
    }
    func updateTracking(withMouseLocation mouseLocation: NSPoint, timestamp: TimeInterval, allowsKeyInterruption: Bool = true) {
        guard isTracking, let _ = initialMouseLocation, let _ = initialWindowLocation, let _ = trackedWindow else {
            return
        }
        applyCursor()
        if allowsKeyInterruption && checkForKeyPresses() {
            pauseTracking()
            return
        }
        if shouldFocusWindow && !trackedWindowIsFocused, let w = trackedWindow { WindowManager.focus(window: w); trackedWindowIsFocused = true }
        pendingMouseLocation = mouseLocation
        // No throttling here: the math below is trivial and AXWindowWriter
        // self-paces (latest-wins), so every event improves temporal resolution.
        flushPendingMouseUpdate()
        // Re-assert last: the app under the pointer sets its own cursor while
        // handling this same mouse-moved event, and whoever writes last wins.
        pinnedCursor?.set()
    }
    private func drainQueuedExternalMouseUpdate() {
        guard let update = takeQueuedExternalMouseUpdate() else { return }
        updateTracking(withMouseLocation: update.location, timestamp: update.timestamp, allowsKeyInterruption: false)
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            if self.queuedExternalMouseUpdate != nil {
                DispatchQueue.main.async { [weak self] in self?.drainQueuedExternalMouseUpdate() }
            } else {
                self.queuedExternalMouseUpdateScheduled = false
            }
        }
    }
    private func flushQueuedExternalMouseUpdate() {
        guard let update = takeQueuedExternalMouseUpdate() else { return }
        updateTracking(withMouseLocation: update.location, timestamp: update.timestamp, allowsKeyInterruption: false)
    }
    private func takeQueuedExternalMouseUpdate() -> (location: NSPoint, timestamp: TimeInterval)? {
        trackingQueue.sync {
            let update = queuedExternalMouseUpdate
            queuedExternalMouseUpdate = nil
            if update == nil { queuedExternalMouseUpdateScheduled = false }
            return update
        }
    }
    private func clearQueuedExternalMouseUpdate() {
        trackingQueue.sync {
            queuedExternalMouseUpdate = nil
            queuedExternalMouseUpdateScheduled = false
        }
    }
    private func flushPendingMouseUpdate() {
        guard let loc = pendingMouseLocation else { return }; pendingMouseLocation = nil
        if currentAction == .move { moveWindowBasedOnMouseLocation(loc) } else if currentAction == .resize { resizeWindowBasedOnMouseLocation(loc) }
    }
    private func moveWindowBasedOnMouseLocation(_ loc: NSPoint) {
        guard let im = initialMouseLocation, let iw = initialWindowLocation, trackedWindow != nil else { return }
        let dx = loc.x - im.x, dy = loc.y - im.y
        let newY = mouseLocationCoordinateSpace == .coreGraphics ? iw.y + dy : iw.y - dy
        var newO = NSPoint(x: iw.x + dx, y: newY)
        if let size = windowSize { newO = snappedOrigin(forMoving: CGRect(origin: newO, size: size)) }
        AXWindowWriter.shared.requestMove(to: newO)
    }
    private func resizeWindowBasedOnMouseLocation(_ loc: NSPoint) {
        guard let s = windowSize, let im = initialMouseLocation, let iw = initialWindowLocation, trackedWindow != nil else { return }
        var nw = s.width, nh = s.height, no = iw
        if shouldUseQuadrants, let q = quadrant {
            let dx = loc.x - im.x, dy = verticalDelta(from: im, to: loc)
            switch q {
                case .topLeft: nw -= dx; nh += dy; no.x += dx; no.y -= dy
                case .top: nh += dy; no.y -= dy
                case .topRight: nw += dx; nh += dy; no.y -= dy
                case .left: nw -= dx; no.x += dx
                case .center: nw += 2*dx; no.x -= dx; nh += 2*dy; no.y -= dy
                case .right: nw += dx
                case .bottomLeft: nw -= dx; nh -= dy; no.x += dx
                case .bottom: nh -= dy
                case .bottomRight: nw += dx; nh -= dy
            }
        } else {
            nw = s.width + (loc.x - im.x); nh = s.height - verticalDelta(from: im, to: loc)
        }
        nw = max(nw, 1); nh = max(nh, 1)
        let snapped = snappedResize(origin: no, size: CGSize(width: nw, height: nh))
        no = snapped.origin; nw = snapped.size.width; nh = snapped.size.height
        AXWindowWriter.shared.requestResize(origin: no, size: CGSize(width: nw, height: nh))
    }
    private func snappedOrigin(forMoving rect: CGRect) -> NSPoint {
        let dx = closestSnapDelta(
            from: [rect.minX, rect.maxX],
            candidates: snapRects.filter { rangesOverlap(rect.minY...rect.maxY, $0.minY...$0.maxY) }.flatMap { [$0.minX, $0.maxX] }
        ) ?? 0
        let dy = closestSnapDelta(
            from: [rect.minY, rect.maxY],
            candidates: snapRects.filter { rangesOverlap(rect.minX...rect.maxX, $0.minX...$0.maxX) }.flatMap { [$0.minY, $0.maxY] }
        ) ?? 0
        return NSPoint(x: rect.origin.x + dx, y: rect.origin.y + dy)
    }
    private func snappedResize(origin: NSPoint, size: CGSize) -> (origin: NSPoint, size: CGSize) {
        var left = origin.x, right = origin.x + size.width, top = origin.y, bottom = origin.y + size.height
        let edges = activeResizeEdges()
        let horizontalCandidates = snapRects.filter { rangesOverlap(top...bottom, $0.minY...$0.maxY) }.flatMap { [$0.minX, $0.maxX] }
        let verticalCandidates = snapRects.filter { rangesOverlap(left...right, $0.minX...$0.maxX) }.flatMap { [$0.minY, $0.maxY] }
        if edges.left, let dx = closestSnapDelta(from: [left], candidates: horizontalCandidates) { left += dx }
        if edges.right, let dx = closestSnapDelta(from: [right], candidates: horizontalCandidates) { right += dx }
        if edges.top, let dy = closestSnapDelta(from: [top], candidates: verticalCandidates) { top += dy }
        if edges.bottom, let dy = closestSnapDelta(from: [bottom], candidates: verticalCandidates) { bottom += dy }
        let snappedOrigin = NSPoint(x: min(left, right - 1), y: min(top, bottom - 1))
        let snappedSize = CGSize(width: max(right - left, 1), height: max(bottom - top, 1))
        return (snappedOrigin, snappedSize)
    }
    private func activeResizeEdges() -> (left: Bool, right: Bool, top: Bool, bottom: Bool) {
        guard shouldUseQuadrants, let q = quadrant else { return (false, true, false, true) }
        switch q {
            case .topLeft: return (true, false, true, false)
            case .top: return (false, false, true, false)
            case .topRight: return (false, true, true, false)
            case .left: return (true, false, false, false)
            case .center: return (true, true, true, true)
            case .right: return (false, true, false, false)
            case .bottomLeft: return (true, false, false, true)
            case .bottom: return (false, false, false, true)
            case .bottomRight: return (false, true, false, true)
        }
    }
    private func closestSnapDelta(from movingEdges: [CGFloat], candidates targetEdges: [CGFloat]) -> CGFloat? {
        var closest: CGFloat?
        for moving in movingEdges {
            for target in targetEdges {
                let delta = target - moving
                guard abs(delta) <= snapDistance else { continue }
                if closest == nil || abs(delta) < abs(closest!) { closest = delta }
            }
        }
        return closest
    }
    private func rangesOverlap(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> Bool {
        return a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound
    }
    private func invalidateTrackingTimer() { trackingTimer?.invalidate(); trackingTimer = nil }
    private func removeMouseEventMonitor() { if let m = mouseEventMonitor { NSEvent.removeMonitor(m); mouseEventMonitor = nil } }
    private func resetTrackingVariables() { pendingMouseLocation = nil; snapRects = []; trackedWindow = nil; initialMouseLocation = nil; initialWindowLocation = nil; currentAction = .none; quadrant = nil; windowSize = nil; mouseLocationCoordinateSpace = .appKit }
    func pauseTracking() { isTracking = false }
    func resumeTracking() { if currentAction != .none && trackedWindow != nil { isTracking = true } }
    private func checkForKeyPresses() -> Bool {
        guard let ev = NSApp.currentEvent else { return false }
        if ev.type == .keyDown || ev.type == .keyUp { if (36...126).contains(ev.keyCode) { return true } }
        return false
    }
    private func currentMouseLocation() -> NSPoint {
        if mouseLocationCoordinateSpace == .coreGraphics, let event = CGEvent(source: nil) {
            return event.location
        }
        return NSEvent.mouseLocation
    }
}

/// Lets this app set the mouse cursor while it isn't the frontmost one.
///
/// The Window Server normally ignores `NSCursor.set()` (and `NSCursor.hide()` /
/// `CGDisplayHideCursor`) from a background app — measured on macOS 26: setting
/// `.closedHand` from an inactive process left `NSCursor.currentSystem` on
/// whatever the frontmost app wanted. Tagging our Window Server connection with
/// the undocumented `SetsCursorInBackground` property lifts that restriction,
/// and `currentSystem` then reports the cursor we asked for. This is the
/// long-standing way background utilities drive the cursor; the alternative,
/// activating the app mid-gesture, would pull keyboard focus out of the very
/// window being dragged.
///
/// `CGSMainConnectionID` / `CGSSetConnectionProperty` are undocumented, so they
/// are resolved with `dlsym` rather than linked: on a macOS that drops them the
/// cursor simply stops changing instead of the app failing to launch.
private enum BackgroundCursor {
    private static var didAttemptEnable = false

    static func enable() {
        guard !didAttemptEnable else { return }
        didAttemptEnable = true

        typealias MainConnectionID = @convention(c) () -> UInt32
        typealias SetConnectionProperty = @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32

        guard let handle = dlopen(nil, RTLD_LAZY),
              let connectionSymbol = dlsym(handle, "CGSMainConnectionID"),
              let propertySymbol = dlsym(handle, "CGSSetConnectionProperty") else { return }

        let connectionID = unsafeBitCast(connectionSymbol, to: MainConnectionID.self)()
        let setProperty = unsafeBitCast(propertySymbol, to: SetConnectionProperty.self)
        _ = setProperty(connectionID, connectionID, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

// MARK: - Native drag by the title bar

/// A keyboard move carried out as a native drag of the window's title bar, run by the WindowServer
/// like a drag with the mouse: smooth across displays, the part still on the old display turning
/// translucent, and Stage Manager treating it as the user's own drag. Writing the window position
/// through Accessibility instead lags behind slow apps and stutters across displays, where Stage
/// Manager takes over a window a program moves and re-places it (measured: pauses of up to 300 ms
/// and jumps of over 1,000 pt per crossing, with or without SwiftShift).
///
/// What it takes, each point learned from a failed attempt:
///
/// - A real button press, so one is simulated, but only on a point of the title bar that
///   Accessibility shows is empty (`WindowManager.titleBarGrabPoint`). Pressing where the pointer is
///   instead clicked icons whenever the app did not take the press as a window drag. Without a safe
///   point nothing is pressed and the move falls back to AX writes.
/// - The press happens on the first movement, not when the modifier goes down, so tapping the
///   modifier (a double-tap, say) never clicks anything.
/// - Events are posted at the HID tap carrying the modifiers the user is actually holding: posted
///   there, an event also sets the system's modifier state, and a press "without Control" released
///   the Control key held for the move, which ended it at once. The modifiers are then removed
///   downstream, in the session tap, where they only change what the app sees: a plain click on its
///   title bar, not a Control-click.
/// - The hardware keeps sending plain moves, which say no button is down and are not taken as drags
///   even when rewritten (measured with a real mouse: the window never moved). Each one is dropped
///   and replaced by a real drag at the same spot.
/// - The pressed pointer sits on the title bar, so it is made invisible: hiding the cursor is refused
///   to a background app, but changing its image is allowed. A stand-in hand is drawn where the user
///   took hold of the window and travels with it, and at the end the real pointer is put back under
///   it before its image returns.
private struct TitleBarDrag {
    /// The safe title-bar point the press is made on.
    let grabPoint: CGPoint
    /// Where the user's pointer was when the drag started, inside the window.
    var heldPoint: CGPoint
    var isPressed = false
    /// The window in the WindowServer and its frame there when the move began, to notice a press
    /// that did not start a drag. Nil when it could not be identified.
    let windowNumber: CGWindowID?
    let startFrame: CGRect?
    var moves = 0
    var followConfirmed = false
    /// The first drag after the press, and when it came: the follow check measures from there.
    var firstDrag: (location: CGPoint, time: TimeInterval)?

    /// Where the user holds the window, for a pointer at `pointer`. Both travel together.
    func held(forPointerAt pointer: CGPoint) -> CGPoint {
        CGPoint(x: pointer.x + heldPoint.x - grabPoint.x, y: pointer.y + heldPoint.y - grabPoint.y)
    }
}

extension MouseTracker {
    private static let titleBarDragSubscriber = "titleBarDrag"
    /// Marks the mouse events SwiftShift posts itself. Same value as MouseChordActionManager's
    /// replay marker, so that manager lets them through too.
    private static let syntheticEventMarker: Int64 = 0x5357465453484946

    /// A fully transparent cursor, set while the real pointer waits on the title bar.
    fileprivate static let invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.clear.set()
            rect.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: .zero)
    }()

    /// Prepares a title-bar drag, pressing nothing yet. False when the preference is off or the
    /// window has no safe point to press, in which case the caller falls back to AX writes.
    fileprivate func armTitleBarDrag() -> Bool {
        guard PreferencesManager.loadBool(for: .nativeDrag, defaultValue: true),
              let window = trackedWindow,
              let grab = WindowManager.titleBarGrabPoint(of: window),
              let held = CGEvent(source: nil)?.location else { return false }
        let server = WindowManager.windowServerWindow(matching: window)
        titleBarDrag = TitleBarDrag(grabPoint: grab, heldPoint: held, windowNumber: server?.number, startFrame: server?.frame)
        CGEventSupervisor.shared.subscribe(as: Self.titleBarDragSubscriber,
                                           to: .cgEvents(.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp)) { [weak self] event in
            self?.handleTitleBarDragEvent(event)
        }
        TrackpadDebugLog.write("titlebar: armed grab=\(grab) held=\(held) window=\(server.map { "\($0.number)" } ?? "unidentified")")
        return true
    }

    private func handleTitleBarDragEvent(_ event: CGEvent) {
        let isOurs = event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker
        if isOurs {
            // Posted with the held modifiers so the system's modifier state stays put; the app must
            // see a plain click and drags on its title bar.
            event.flags = []
            return
        }
        guard event.type == .mouseMoved, var drag = titleBarDrag else { return }
        let location = event.location, heldModifiers = event.flags
        event.cancel()
        if !drag.isPressed {
            drag.isPressed = true
            drag.heldPoint = location
            titleBarDrag = drag
            BackgroundCursor.enable()
            pinnedCursor = Self.invisibleCursor
            Self.invisibleCursor.set()
            cursorStandIn.show(cursor(for: .move), atQuartz: location)
            postSyntheticMouse(.leftMouseDown, at: drag.grabPoint, flags: heldModifiers)
            TrackpadDebugLog.write("titlebar: pressed at \(drag.grabPoint), held at \(location)")
            return
        }
        postSyntheticMouse(.leftMouseDragged, at: location, flags: heldModifiers)
        cursorStandIn.show(cursor(for: .move), atQuartz: drag.held(forPointerAt: location))
        checkTheWindowFollows(pointer: location)
    }

    private func postSyntheticMouse(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    /// A press that did not start a window drag leaves the window in place. Once the pointer has
    /// clearly travelled and the WindowServer still shows the window where it started, the button is
    /// released and the rest of the move follows the pointer through AX writes. The WindowServer's
    /// frame is read, not AX's, which lags during a native drag.
    private func checkTheWindowFollows(pointer: CGPoint) {
        guard var drag = titleBarDrag, !drag.followConfirmed else { return }
        drag.moves += 1
        let now = ProcessInfo.processInfo.systemUptime
        if drag.firstDrag == nil { drag.firstDrag = (pointer, now) }
        titleBarDrag = drag
        // Judged from the first drag, once the pointer has really travelled and the WindowServer
        // has had time to start the drag.
        guard let number = drag.windowNumber, let start = drag.startFrame, let first = drag.firstDrag,
              drag.moves % 4 == 0, now - first.time > 0.12,
              hypot(pointer.x - first.location.x, pointer.y - first.location.y) > 40 else { return }
        if let frame = WindowManager.windowServerFrame(of: number),
           abs(frame.minX - start.minX) + abs(frame.minY - start.minY) > 2 {
            titleBarDrag?.followConfirmed = true
            return
        }
        TrackpadDebugLog.write("titlebar: window did not follow, falling back to AX moves")
        // Out of the event tap callback first: cancelling the subscription rebuilds the tap.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.titleBarDrag != nil, self.isTracking else { return }
            _ = self.endTitleBarDrag { [weak self] in
                // Baselined once the pointer is back under the user's hand, or its move back would
                // shift the window.
                guard let self, self.isTracking, self.currentAction == .move, let window = self.trackedWindow else { return }
                self.mouseLocationCoordinateSpace = .appKit
                self.initialMouseLocation = NSEvent.mouseLocation
                self.initialWindowLocation = WindowManager.getPosition(window: window)
                AXWindowWriter.shared.reset(origin: self.initialWindowLocation, size: self.windowSize)
                self.registerMouseEventMonitor(button: .none)
                self.applyCursor()
            }
        }
    }

    /// Ends a title-bar drag: releases the button, puts the real pointer back where the user holds the
    /// window, and only then gives it its image back, or runs `continuation` instead when the move
    /// carries on another way. Returns whether the cursor is handed back later; false when nothing
    /// was pressed, and nothing to undo.
    fileprivate func endTitleBarDrag(continuation: (() -> Void)? = nil) -> Bool {
        guard let drag = titleBarDrag else { return false }
        titleBarDrag = nil
        CGEventSupervisor.shared.cancel(subscriber: Self.titleBarDragSubscriber)
        guard drag.isPressed else {
            continuation?()
            return false
        }
        let pointer = CGEvent(source: nil)?.location ?? drag.grabPoint
        let flags = CGEventSource.flagsState(.hidSystemState)
        postSyntheticMouse(.leftMouseUp, at: pointer, flags: flags)
        // The pointer goes back as a move in the same event stream, so the WindowServer ends the
        // drag before it sees the move and the window stays put. Not `CGWarpMouseCursorPosition`:
        // a warp freezes the hardware pointer for about 250 ms, felt as the mouse not answering
        // after the move.
        postSyntheticMouse(.mouseMoved, at: drag.held(forPointerAt: pointer), flags: flags)
        TrackpadDebugLog.write("titlebar: released after \(drag.moves) moves, followed=\(drag.followConfirmed)")
        // The move lands within a millisecond; the image comes back once it has, so the pointer
        // never shows on the title bar. The hardware pointer answers meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
            guard let self else { return }
            if let continuation { continuation() } else if !self.isTracking { self.resetCursor() }
            // A new drag may already be under way, with its own stand-in.
            if self.titleBarDrag?.isPressed != true { self.cursorStandIn.hide() }
        }
        return true
    }
}

/// A click-through window that draws a cursor image at a given point, standing in for the real
/// cursor while it is invisible.
private final class CursorStandInWindow {
    private let window: NSWindow
    private let imageView: NSImageView

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary, .transient]
        imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleNone
        window.contentView = imageView
    }

    /// Places the image so the cursor's hot spot sits on `point` (Quartz coordinates).
    func show(_ cursor: NSCursor, atQuartz point: CGPoint) {
        let image = cursor.image
        if imageView.image !== image { imageView.image = image }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        // The hot spot is measured from the image's top-left corner; window frames from bottom-left.
        let origin = NSPoint(x: point.x - cursor.hotSpot.x,
                             y: (mainHeight - point.y) - (image.size.height - cursor.hotSpot.y))
        window.setFrame(NSRect(origin: origin, size: image.size), display: window.isVisible)
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        window.orderOut(nil)
    }
}
