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
    private var nativeDrag: NativeDrag?
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
        // A keyboard move is carried out as macOS's own window drag when it can be (see
        // `beginNativeDrag`); otherwise, and for every other gesture, the window follows the pointer
        // through AX writes.
        let isNative = action == .move && button == .none && beginNativeDrag()
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
        endNativeDrag()
        // Apply the final pending move/resize while Enhanced UI is still disabled (fast path),
        // then restore the attribute, then run the remaining cleanup.
        flushQueuedExternalMouseUpdate(); flushPendingMouseUpdate()
        AXWindowWriter.shared.endGesture()
        restoreEnhancedUIForTrackedApp()
        invalidateTrackingTimer(); removeMouseEventMonitor(); resetTrackingVariables(); clearQueuedExternalMouseUpdate(); isTracking = false
        resetCursor()
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

// MARK: - Native drag

/// A keyboard move carried out as macOS's own window drag rather than by writing the window's
/// position through Accessibility.
///
/// AX writes make the window lag behind a slow app, and stutter across displays: Stage Manager takes
/// over a window that a program moves onto another display and re-places it itself (measured on a
/// 2x and two 1x displays: pauses of up to 300 ms and jumps of over 1,000 pt per crossing). A window
/// drag run by the WindowServer crosses displays like a drag with the mouse, the part still on the
/// old display turning translucent.
///
/// macOS drags a window from anywhere inside it on Control-Command + click and drag, once
/// `NSWindowShouldDragOnGesture` is on. The move uses exactly that, from where the pointer already
/// is, so the window is held where the user points at it and the pointer never moves:
///
/// - The press is simulated, since a keyboard move has no button down. It is posted at the HID tap
///   with the modifiers the user is actually holding: an event posted there also sets the system's
///   modifier state, so any other flags would press or release keys behind the user's back (a press
///   "without Control" released the Control key held for the move, ending it). Command is added
///   downstream, in the session tap, where it changes only what the app sees.
/// - The hardware keeps sending plain moves, which say no button is down and are not taken as drags
///   (measured with a real mouse: rewritten in place, the window never moved). Each one is dropped
///   and replaced by a real drag, posted at the HID tap with the held modifiers. Drags made any other
///   way made the window leap by 250 to 430 pt at each display crossing; these did not (measured: no
///   jump, window within 1 pt of its target, pointer still where the window was grabbed).
private struct NativeDrag {
    /// Where the pointer was, and the press was made, when the move began.
    let pressPoint: CGPoint
    /// The window in the WindowServer and its frame there when the move began, to notice a window
    /// that does not follow. Nil when it could not be identified.
    let windowNumber: CGWindowID?
    let startFrame: CGRect?
    var moves = 0
    var followConfirmed = false
}

extension MouseTracker {
    private static let nativeDragSubscriber = "nativeDrag"
    /// Marks the mouse events SwiftShift posts itself. Same value as MouseChordActionManager's
    /// replay marker, so that manager lets them through too.
    private static let syntheticEventMarker: Int64 = 0x5357465453484946

    /// Starts the move as a native drag. False when the preference or macOS's gesture is off, in
    /// which case the caller falls back to AX writes.
    fileprivate func beginNativeDrag() -> Bool {
        guard PreferencesManager.loadBool(for: .nativeDrag, defaultValue: true),
              WindowManager.isNativeDragGestureEnabled(),
              let window = trackedWindow,
              let press = CGEvent(source: nil)?.location else { return false }

        let server = WindowManager.windowServerWindow(matching: window)
        nativeDrag = NativeDrag(pressPoint: press, windowNumber: server?.number, startFrame: server?.frame)
        if shouldFocusWindow { WindowManager.focus(window: window); trackedWindowIsFocused = true }

        CGEventSupervisor.shared.subscribe(as: Self.nativeDragSubscriber, to: .cgEvents(.leftMouseDown, .mouseMoved)) { [weak self] event in
            self?.handleNativeDragEvent(event)
        }
        postNativeDragMouse(.leftMouseDown, at: press)
        TrackpadDebugLog.write("native drag: begin at \(press) window=\(server.map { "\($0.number) \($0.frame)" } ?? "unidentified")")
        return true
    }

    /// Releases the simulated button. Does nothing when the move was not a native drag.
    fileprivate func endNativeDrag() {
        guard let drag = nativeDrag else { return }
        nativeDrag = nil
        CGEventSupervisor.shared.cancel(subscriber: Self.nativeDragSubscriber)
        let pointer = CGEvent(source: nil)?.location ?? drag.pressPoint
        postNativeDragMouse(.leftMouseUp, at: pointer)
        TrackpadDebugLog.write("native drag: end after \(drag.moves) moves at \(pointer)")
    }

    private func handleNativeDragEvent(_ event: CGEvent) {
        let isOurs = event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker
        switch event.type {
        case .leftMouseDown where isOurs:
            // Turns our press into macOS's drag-from-anywhere gesture for the app receiving it.
            event.flags = event.flags.union([.maskControl, .maskCommand])
        case .mouseMoved where !isOurs:
            event.cancel()
            postNativeDragMouse(.leftMouseDragged, at: event.location, flags: event.flags)
            checkTheWindowFollows(pointer: event.location)
        default:
            break
        }
    }

    /// Posted at the HID tap, carrying the modifiers the user is holding unless told otherwise, so
    /// the system's modifier state stays as it is.
    private func postNativeDragMouse(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags? = nil) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.flags = flags ?? CGEventSource.flagsState(.hidSystemState)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    /// An app that does not handle macOS's gesture (or was opened before it was turned on) leaves its
    /// window in place. Once the pointer has clearly travelled and the WindowServer still shows the
    /// window where it started, the simulated button is released and the rest of the move follows the
    /// pointer through AX writes, as before. The WindowServer's frame is read, not AX's, which lags
    /// during a native drag.
    private func checkTheWindowFollows(pointer: CGPoint) {
        guard var drag = nativeDrag, !drag.followConfirmed else { return }
        drag.moves += 1
        nativeDrag = drag
        guard let number = drag.windowNumber, let start = drag.startFrame, drag.moves % 4 == 0,
              hypot(pointer.x - drag.pressPoint.x, pointer.y - drag.pressPoint.y) > 40 else { return }
        if let frame = WindowManager.windowServerFrame(of: number),
           abs(frame.minX - start.minX) + abs(frame.minY - start.minY) > 2 {
            nativeDrag?.followConfirmed = true
            return
        }
        TrackpadDebugLog.write("native drag: window did not follow, falling back to AX moves")
        // Out of the event tap callback first: cancelling the subscription rebuilds the tap.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.nativeDrag != nil, self.isTracking, let window = self.trackedWindow else { return }
            self.endNativeDrag()
            self.mouseLocationCoordinateSpace = .appKit
            self.initialMouseLocation = NSEvent.mouseLocation
            self.initialWindowLocation = WindowManager.getPosition(window: window)
            AXWindowWriter.shared.reset(origin: self.initialWindowLocation, size: self.windowSize)
            self.registerMouseEventMonitor(button: .none)
        }
    }
}
