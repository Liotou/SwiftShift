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
    private var titleBarDragConverted = 0
    private var titleBarDragStartOrigin: NSPoint?
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
        // A keyboard move is performed as a native title-bar drag whenever a safe grab point exists;
        // otherwise, and for every other gesture, the window follows the pointer through AX writes.
        let byTitleBar = action == .move && button == .none && beginTitleBarDrag()
        if !byTitleBar { registerMouseEventMonitor(button: button) }
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
        if titleBarDrag != nil {
            TrackpadDebugLog.write("titlebar: stopTracking(\(action)) called by \(Thread.callStackSymbols.dropFirst().prefix(3).map { $0.split(separator: " ").dropFirst(3).prefix(1).joined() }.joined(separator: " <- "))")
        }
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
        let cursor = titleBarDrag != nil ? Self.invisibleCursor : cursor(for: currentAction)
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

// MARK: - Moving by the title bar

/// A move carried out as a native drag of the window's title bar.
///
/// Writing the window position through Accessibility makes the window lag behind the pointer
/// whenever the app is slow to answer, and goes wrong when the window changes display: Stage
/// Manager takes over a window that a program moves onto another display and re-places it itself,
/// so the window freezes and jumps (measured: pauses of up to 300 ms and jumps of over 1,000 pt
/// per crossing). A drag by the title bar is run by the WindowServer instead, the same as a drag
/// with the mouse, and crosses displays smoothly (measured: no jump, pauses under 30 ms).
///
/// So the move presses the mouse on a safe point of the title bar, turns the user's plain mouse
/// movements into drags of it, and releases it when the move ends. The pressed pointer has to sit
/// on the title bar, but the user should not lose track of it: the real cursor is hidden, a
/// stand-in is drawn where the user was holding the window and travels with it, and at the end the
/// real cursor is put back under the stand-in before it reappears.
private struct TitleBarDrag {
    /// Where the drag holds the window: a point of its title bar that is safe to press.
    let grabPoint: CGPoint
    /// Where the user's pointer was when the move began, inside the window.
    let heldPoint: CGPoint

    /// From the pressed point to where the user holds the window. Both travel together.
    func held(forPointerAt pointer: CGPoint) -> CGPoint {
        CGPoint(x: pointer.x + heldPoint.x - grabPoint.x, y: pointer.y + heldPoint.y - grabPoint.y)
    }
}

extension MouseTracker {
    private static let titleBarDragSubscriber = "titleBarDrag"
    /// Marks the mouse events SwiftShift posts itself. Same value as MouseChordActionManager's
    /// replay marker, so that manager lets them through too.
    private static let syntheticEventMarker: Int64 = 0x5357465453484946

    /// Starts the move as a title-bar drag. False when the preference is off or the window has no
    /// title-bar point that can be pressed safely, in which case the caller falls back.
    fileprivate func beginTitleBarDrag() -> Bool {
        guard PreferencesManager.loadBool(for: .moveByTitleBar, defaultValue: true),
              let window = trackedWindow,
              let grab = WindowManager.titleBarGrabPoint(of: window),
              let held = CGEvent(source: nil)?.location else { return false }

        let drag = TitleBarDrag(grabPoint: grab, heldPoint: held)
        titleBarDrag = drag
        titleBarDragConverted = 0
        titleBarDragStartOrigin = WindowManager.getPosition(window: window)
        let app = WindowManager.getNSApplication(from: window)?.localizedName ?? "?"
        let start = WindowManager.getFrame(window: window).map { "\($0)" } ?? "?"
        TrackpadDebugLog.write("titlebar: begin app=\(app) frame=\(start) grab=\(grab) held=\(held) focus=\(shouldFocusWindow) hidFlags=\(CGEventSource.flagsState(.hidSystemState).rawValue) sessionFlags=\(CGEventSource.flagsState(.combinedSessionState).rawValue)")

        // Make the real pointer invisible before it jumps to the title bar, and show the stand-in
        // where it was. Hiding the cursor outright is refused to a background app (measured: both
        // cursors stayed on screen), but changing its image is allowed once BackgroundCursor is
        // enabled, so it gets a transparent image, kept in place by the cursor pin.
        BackgroundCursor.enable()
        Self.invisibleCursor.set()
        cursorStandIn.show(cursor(for: .move), atQuartz: held)

        // Always a plain press, which brings the window's app forward even with "Focus on window"
        // off. Pressing with Command would move it without activating the app, but a drag that
        // carries Command is handled differently when it crosses displays: the window leaps by
        // several hundred points as the pointer enters the other display (measured: +434 pt, in
        // two runs out of three; none without Command). macOS's own Control-Command drag anywhere
        // in a window (NSWindowShouldDragOnGesture) leaps the same way, which rules it out too.
        postSyntheticMouse(.leftMouseDown, at: grab, flags: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            TrackpadDebugLog.write("titlebar: after press leftButtonDown(hid)=\(CGEventSource.buttonState(.hidSystemState, button: .left)) leftButtonDown(session)=\(CGEventSource.buttonState(.combinedSessionState, button: .left)) pointer=\(CGEvent(source: nil)?.location ?? .zero)")
        }

        // No button is held during a keyboard move, so the hardware sends plain moves; the drag needs
        // drags. They are rewritten in place, keeping their hardware origin and timing: replacing them
        // with drags made from scratch makes the window leap as the pointer enters another display
        // (measured: +434 pt every time, whether posted at the session tap or, carrying the held
        // modifiers, at the HID tap). A hardware move says no button is pressed, so the rewrite also
        // fills in what a real drag with the button down carries: pressure and click state.
        CGEventSupervisor.shared.subscribe(as: Self.titleBarDragSubscriber, to: .cgEvents(.mouseMoved)) { [weak self] event in
            guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker else { return }
            event.type = .leftMouseDragged
            event.flags = []
            event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setDoubleValueField(.mouseEventPressure, value: 1)
            guard let self, let drag = self.titleBarDrag else { return }
            let location = event.location
            self.titleBarDragConverted += 1
            self.cursorStandIn.show(self.cursor(for: .move), atQuartz: drag.held(forPointerAt: location))
            if self.titleBarDragConverted <= 3 || self.titleBarDragConverted % 40 == 0 {
                let window = self.trackedWindow.flatMap { WindowManager.getPosition(window: $0) }.map { "\($0)" } ?? "?"
                TrackpadDebugLog.write("titlebar: drag #\(self.titleBarDragConverted) at \(location) windowAX=\(window)")
            }
            self.fallBackIfTheWindowDoesNotFollow(pointer: location)
        }
        return true
    }

    /// Some windows ignore a press on their title bar posted by another app. Once the pointer has
    /// clearly travelled and the window still sits where it started, the title bar is released and
    /// the rest of the move follows the pointer through Accessibility, as before, from wherever the
    /// pointer is now. Checked every few moves, so the AX read costs little.
    private func fallBackIfTheWindowDoesNotFollow(pointer: CGPoint) {
        guard let drag = titleBarDrag, let window = trackedWindow, let startOrigin = titleBarDragStartOrigin,
              titleBarDragConverted % 6 == 0 else { return }
        let travel = hypot(pointer.x - drag.grabPoint.x, pointer.y - drag.grabPoint.y)
        guard travel > 60, let origin = WindowManager.getPosition(window: window),
              hypot(origin.x - startOrigin.x, origin.y - startOrigin.y) < 2 else {
            if travel > 60 { titleBarDragStartOrigin = nil } // it follows: stop checking
            return
        }
        TrackpadDebugLog.write("titlebar: window did not follow after \(Int(travel)) pt, falling back to AX moves")
        // Carry on as an ordinary move, baselined once the pointer is back under the user's hand:
        // a baseline taken before that warp would shift the window by the warp itself.
        _ = endTitleBarDrag { [weak self] in
            guard let self, self.isTracking, self.currentAction == .move, let window = self.trackedWindow else { return }
            self.mouseLocationCoordinateSpace = .appKit
            self.initialMouseLocation = NSEvent.mouseLocation
            self.initialWindowLocation = WindowManager.getPosition(window: window) ?? origin
            AXWindowWriter.shared.reset(origin: self.initialWindowLocation, size: self.windowSize)
            self.registerMouseEventMonitor(button: .none)
            self.applyCursor()
        }
    }

    /// Releases the title bar, puts the real pointer back where the user holds the window, and
    /// only then gives it its image back, or runs `continuation` instead when the move carries on
    /// another way. Returns false, doing nothing, when the move was not a title-bar drag.
    fileprivate func endTitleBarDrag(continuation: (() -> Void)? = nil) -> Bool {
        guard let drag = titleBarDrag else { return false }
        titleBarDrag = nil
        CGEventSupervisor.shared.cancel(subscriber: Self.titleBarDragSubscriber)

        let pointer = CGEvent(source: nil)?.location ?? drag.grabPoint
        let end = trackedWindow.flatMap { WindowManager.getFrame(window: $0) }.map { "\($0)" } ?? "?"
        TrackpadDebugLog.write("titlebar: end moves=\(titleBarDragConverted) pointer=\(pointer) frame=\(end)")
        postSyntheticMouse(.leftMouseUp, at: pointer, flags: [])

        // Warp only once the release has been processed: warping while the drag is still live
        // would drag the window along with the pointer.
        let back = drag.held(forPointerAt: pointer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            CGWarpMouseCursorPosition(back)
            // Warping suspends the hardware pointer for a moment; give it back right away.
            CGAssociateMouseAndMouseCursorPosition(1)
            if let continuation { continuation() } else { self?.resetCursor() }
            self?.cursorStandIn.hide()
        }
        return true
    }

    /// A fully transparent cursor, set while the real pointer waits on the title bar.
    fileprivate static let invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.clear.set()
            rect.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: .zero)
    }()

    /// Posted at the session tap by default, not the HID tap: an event posted at the HID tap also
    /// rewrites the system's modifier state, so pressing the title bar "without Control" there
    /// released the Control key the user is holding for the move, which ended the move straight
    /// away (measured). At the session tap the modifier state is left as it is.
    private func postSyntheticMouse(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags, tap: CGEventTapLocation = .cgSessionEventTap) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        event.post(tap: tap)
    }
}

/// A click-through window that draws a cursor image at a given point, standing in for the real
/// cursor while it is hidden.
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
