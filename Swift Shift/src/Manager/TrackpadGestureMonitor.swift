import AppKit
import CGEventSupervisor

// MARK: - Touches

/// One finger on the trackpad.
struct TrackpadTouch {
  /// Stable for as long as the finger stays down.
  let id: NSObject
  /// 0...1 across the trackpad, origin at the bottom left.
  let position: CGPoint
}

// MARK: - Three-finger swipe down

/// Recognizes three fingers travelling down the trackpad. Ported from the standalone Stash app
/// (Liotou/Stash 1.2.0), which tracks the fingers itself instead of relying on the gestures
/// macOS presets.
final class ThreeFingerSwipeRecognizer {

  struct Update: Equatable {
    var fingers: Int
    /// 0...1 towards the threshold, for the settings indicator.
    var progress: Double
    var triggered: Bool
  }

  private var startPositions: [NSObject: CGPoint] = [:]
  private var hasFired = false
  private var lastFire: TimeInterval = -.infinity

  /// - Parameter threshold: vertical travel needed, as a fraction of the trackpad height.
  func update(touches: [TrackpadTouch], now: TimeInterval, threshold: Double) -> Update {
    guard touches.count == 3 else {
      reset()
      return Update(fingers: touches.count, progress: 0, triggered: false)
    }

    // The gesture already acted: wait for the fingers to lift.
    guard !hasFired else { return Update(fingers: 3, progress: 1, triggered: false) }

    var sumX: CGFloat = 0
    var sumY: CGFloat = 0
    var tracked = 0

    for touch in touches {
      if let origin = startPositions[touch.id] {
        sumX += touch.position.x - origin.x
        sumY += touch.position.y - origin.y
        tracked += 1
      } else {
        startPositions[touch.id] = touch.position
      }
    }

    // A finger just joined the others: start over from this configuration.
    guard tracked == 3, startPositions.count == 3 else {
      if startPositions.count > 3 { startPositions.removeAll() }
      return Update(fingers: 3, progress: 0, triggered: false)
    }

    let dy = sumY / 3 // negative = downwards
    let dx = sumX / 3
    let limit = CGFloat(max(0.02, threshold))
    let progress = min(1, Double(max(0, -dy) / limit))

    // Far enough down, and clearly more vertical than horizontal.
    guard -dy >= limit, -dy > 1.6 * abs(dx) else {
      return Update(fingers: 3, progress: progress, triggered: false)
    }
    guard now - lastFire > 0.4 else { return Update(fingers: 3, progress: progress, triggered: false) }

    lastFire = now
    hasFired = true
    return Update(fingers: 3, progress: 1, triggered: true)
  }

  func reset() {
    startPositions.removeAll()
    hasFired = false
  }
}

// MARK: - Two-finger hold, then drag

/// Recognizes two fingers that rest on the trackpad for a moment and are then dragged.
///
/// Two fingers moving straight away is an ordinary scroll, so the hold is what tells the two
/// apart: if the fingers travel before the hold has elapsed the whole touch is written off as a
/// scroll (or pinch) and can never turn into a grab, however long they linger afterwards. Only
/// touches that begin still can become one.
final class TwoFingerHoldRecognizer {

  enum Phase: Equatable {
    case idle
    /// Two fingers down and still, counting towards the hold time.
    case resting
    case grabbing
    /// Moved too early (a scroll), or the grab could not start: ignored until the fingers lift.
    case rejected
  }

  enum Event: Equatable {
    case began
    /// Movement of the fingers' midpoint since the grab began, as a fraction of the trackpad
    /// (y points up, like the trackpad's own coordinates).
    case moved(dx: CGFloat, dy: CGFloat)
    case ended
  }

  /// How far the fingers may wander during the hold — hand tremor, not intent — as a fraction
  /// of the trackpad.
  static let restTolerance: CGFloat = 0.02

  private(set) var phase: Phase = .idle
  private(set) var restStart: TimeInterval = 0

  private var restPositions: [NSObject: CGPoint] = [:]
  private var midpoint: CGPoint = .zero
  private var anchor: CGPoint = .zero

  func update(touches: [TrackpadTouch], now: TimeInterval, holdDuration: TimeInterval) -> [Event] {
    guard touches.count == 2 else { return reset() }

    let previousMidpoint = midpoint
    midpoint = Self.midpoint(of: touches)
    var events: [Event] = []

    switch phase {
    case .idle:
      beginRest(touches, now: now)

    case .resting:
      if Set(touches.map(\.id)) != Set(restPositions.keys) {
        // A finger was swapped for another: the hold starts over.
        beginRest(touches, now: now)
      } else if now - restStart >= holdDuration {
        // Still for the whole hold, and this is the first event after it — the first movement.
        // Grab from where the fingers were resting, so nothing jumps.
        anchor = previousMidpoint
        phase = .grabbing
        events.append(.began)
        events.append(moved())
      } else if hasDrifted(touches) {
        phase = .rejected
      }

    case .grabbing:
      events.append(moved())

    case .rejected:
      break
    }
    return events
  }

  /// Notices a hold that ends with the fingers perfectly still, when no touch event arrives to
  /// say so. Call it once the hold time has passed.
  func tick(now: TimeInterval, holdDuration: TimeInterval) -> [Event] {
    guard phase == .resting, now - restStart >= holdDuration else { return [] }
    anchor = midpoint
    phase = .grabbing
    return [.began]
  }

  /// The grab couldn't start (no window under the cursor…): ignore this touch until it lifts.
  func reject() {
    phase = .rejected
  }

  @discardableResult
  func reset() -> [Event] {
    let wasGrabbing = phase == .grabbing
    phase = .idle
    restPositions.removeAll()
    return wasGrabbing ? [.ended] : []
  }

  private func beginRest(_ touches: [TrackpadTouch], now: TimeInterval) {
    phase = .resting
    restStart = now
    restPositions.removeAll()
    for touch in touches { restPositions[touch.id] = touch.position }
  }

  private func hasDrifted(_ touches: [TrackpadTouch]) -> Bool {
    touches.contains { touch in
      guard let origin = restPositions[touch.id] else { return true }
      return hypot(touch.position.x - origin.x, touch.position.y - origin.y) > Self.restTolerance
    }
  }

  private func moved() -> Event {
    .moved(dx: midpoint.x - anchor.x, dy: midpoint.y - anchor.y)
  }

  private static func midpoint(of touches: [TrackpadTouch]) -> CGPoint {
    let count = CGFloat(touches.count)
    return CGPoint(
      x: touches.reduce(0) { $0 + $1.position.x } / count,
      y: touches.reduce(0) { $0 + $1.position.y } / count
    )
  }
}

// MARK: - Monitor

/// Listens to the trackpad and runs the gestures on it.
///
/// A listen-only `CGEventTap` on the gesture events macOS emits whenever fingers touch the
/// trackpad gives access to the raw `NSTouch` data. Two gestures are built on it:
///
/// - **Swipe down with three fingers** drops the window under the cursor into the Dock
///   (see `WindowMinimizer`).
/// - **Hold two fingers, then drag** moves the window under the cursor. It rides on
///   `MouseTracker`'s external-update path — the one the left+right click chord uses — so it gets
///   snapping, focus-on-window, the gesture cursor and the background AX writer for free.
final class TrackpadGestureMonitor: ObservableObject {

  static let shared = TrackpadGestureMonitor()

  enum HoldIndicator: Equatable {
    case idle
    case holding
    case grabbed
  }

  // Published for the settings indicator, and only while `isObserving`.
  @Published private(set) var fingerCount = 0
  @Published private(set) var swipeProgress: Double = 0
  @Published private(set) var holdIndicator: HoldIndicator = .idle

  /// Set while the Trackpad tab is visible.
  var isObserving = false

  private(set) var isRunning = false

  // MARK: Configuration (cached from the preferences)

  private var swipeEnabled = false
  private var holdEnabled = false
  private var swipeLength = 0.12
  private var actOnBackgroundWindows = true
  private var showDesktopOnFullScreen = true
  private var holdDuration = 0.45
  private var holdSpeed = 1.2

  // MARK: State

  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var retryTimer: Timer?
  private let swipe = ThreeFingerSwipeRecognizer()
  private let hold = TwoFingerHoldRecognizer()
  private var deviceSize = CGSize.zero
  private var holdTimerRestStart: TimeInterval?

  private var isGrabbing = false
  private var grabOrigin = CGPoint.zero
  private var referenceWidth: CGFloat = 1440

  private static let scrollSubscriber = "trackpadHoldScrollFilter"
  private var isFilteringScroll = false
  private var dropAllScrollUntil: TimeInterval = 0
  private var dropMomentumScrollUntil: TimeInterval = 0

  /// NSEvent types 19 = beginGesture, 20 = endGesture, 29 = gesture.
  private static let eventMask: CGEventMask = (1 << 19) | (1 << 20) | (1 << 29)

  private init() {
    NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.applyPreferences()
    }
  }

  private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  // MARK: - Lifecycle

  /// Re-reads the preferences and starts or stops listening accordingly. Cheap and idempotent:
  /// it runs on every change to the user defaults.
  func applyPreferences() {
    swipeEnabled = PreferencesManager.loadBool(for: .swipeDownMinimize, defaultValue: true)
    holdEnabled = PreferencesManager.loadBool(for: .twoFingerHoldMove)
    swipeLength = PreferencesManager.loadDouble(for: .swipeLength, defaultValue: 0.12)
    actOnBackgroundWindows = PreferencesManager.loadBool(for: .swipeActsOnBackgroundWindows, defaultValue: true)
    showDesktopOnFullScreen = PreferencesManager.loadBool(for: .swipeShowsDesktopOnFullScreen, defaultValue: true)
    holdDuration = PreferencesManager.loadDouble(for: .twoFingerHoldDuration, defaultValue: 0.45)
    holdSpeed = PreferencesManager.loadDouble(for: .twoFingerHoldSpeed, defaultValue: 1.2)

    if !swipeEnabled { swipe.reset() }
    if !holdEnabled { apply(hold.reset()) }

    if swipeEnabled || holdEnabled {
      start()
    } else {
      stop()
    }
  }

  /// Full teardown and rebuild, for after system events that can kill an event tap
  /// (sleep/wake, display changes, session switches).
  func forceRebuild() {
    stop()
    applyPreferences()
  }

  func stop() {
    retryTimer?.invalidate()
    retryTimer = nil
    apply(hold.reset())
    swipe.reset()
    guard isRunning, let tap, let source else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    CFMachPortInvalidate(tap)
    self.tap = nil
    self.source = nil
    isRunning = false
  }

  private func start() {
    guard !isRunning else { return }
    if !installTap() { scheduleRetry() }
  }

  /// The tap can't be created until Accessibility is granted, which may happen long after
  /// launch, so keep trying until it is.
  private func scheduleRetry() {
    guard retryTimer == nil else { return }
    retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
      guard let self else { timer.invalidate(); return }
      guard self.swipeEnabled || self.holdEnabled else {
        timer.invalidate()
        self.retryTimer = nil
        return
      }
      if self.installTap() {
        timer.invalidate()
        self.retryTimer = nil
      }
    }
  }

  @discardableResult
  private func installTap() -> Bool {
    guard PermissionsManager.hasAccessibilityPermission() else { return false }

    let pointer = Unmanaged.passUnretained(self).toOpaque()
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .listenOnly,
      eventsOfInterest: Self.eventMask,
      callback: { _, type, event, refcon in
        if let refcon {
          Unmanaged<TrackpadGestureMonitor>.fromOpaque(refcon)
            .takeUnretainedValue()
            .handle(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
      },
      userInfo: pointer
    ) else { return false }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    self.tap = tap
    self.source = source
    isRunning = true
    return true
  }

  // MARK: - Recognition

  private func handle(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return
    }

    guard let nsEvent = NSEvent(cgEvent: event) else { return }
    let raw = nsEvent.touches(matching: .touching, in: nil)
    if let size = raw.first?.deviceSize, size.width > 0 { deviceSize = size }

    let touches = raw.compactMap { touch -> TrackpadTouch? in
      guard let id = touch.identity as? NSObject else { return nil }
      return TrackpadTouch(id: id, position: touch.normalizedPosition)
    }
    process(touches: touches, at: now)
  }

  private func process(touches: [TrackpadTouch], at time: TimeInterval) {
    var progress = 0.0

    if swipeEnabled {
      let update = swipe.update(touches: touches, now: time, threshold: swipeLength)
      progress = update.progress
      if update.triggered { fireSwipe() }
    }

    if holdEnabled {
      apply(hold.update(touches: touches, now: time, holdDuration: holdDuration))
      scheduleHoldTimerIfNeeded()
    }

    publish(fingers: touches.count, progress: progress)
  }

  private func fireSwipe() {
    let background = actOnBackgroundWindows
    let desktop = showDesktopOnFullScreen
    DispatchQueue.main.async {
      WindowMinimizer.minimizeWindowUnderCursor(actOnBackgroundWindows: background, showDesktopOnFullScreen: desktop)
    }
  }

  /// A hold that ends with the fingers perfectly still produces no touch events, so nothing
  /// would notice the hold time running out. A timer does.
  private func scheduleHoldTimerIfNeeded() {
    guard hold.phase == .resting, holdTimerRestStart != hold.restStart else { return }
    let restStart = hold.restStart
    holdTimerRestStart = restStart

    DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration + 0.01) { [weak self] in
      guard let self, self.holdEnabled, self.hold.phase == .resting, self.hold.restStart == restStart else { return }
      self.apply(self.hold.tick(now: self.now, holdDuration: self.holdDuration))
      self.publishHoldIndicator()
    }
  }

  // MARK: - Grabbing a window

  private func apply(_ events: [TwoFingerHoldRecognizer.Event]) {
    for event in events {
      switch event {
      case .began: beginGrab()
      case .moved(let dx, let dy): moveGrab(dx: dx, dy: dy)
      case .ended: endGrab()
      }
    }
  }

  private func beginGrab() {
    // Not while a keyboard-driven move/resize is armed: the two would fight over the window.
    guard !ShortcutsManager.shared.hasActiveShortcut,
          let origin = CGEvent(source: nil)?.location,
          MouseTracker.shared.startTrackingForExternalMouseUpdates(for: .move, initialMouseLocation: origin)
    else {
      hold.reject()
      return
    }

    isGrabbing = true
    grabOrigin = origin
    referenceWidth = Self.screenWidth(atQuartzPoint: origin)
    beginScrollSuppression()
    // A click under the fingers, so the grab is felt before the fingers start to move.
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
  }

  /// The fingers' movement drives a virtual cursor, which `MouseTracker` turns into window
  /// movement exactly as it does for a real one. Distances are scaled by the trackpad's real
  /// aspect ratio so a diagonal swipe on the trackpad is a diagonal move on screen.
  private func moveGrab(dx: CGFloat, dy: CGFloat) {
    guard isGrabbing else { return }
    let aspect = deviceSize.width > 0 ? deviceSize.height / deviceSize.width : 0.625
    let gain = referenceWidth * CGFloat(holdSpeed)
    // The trackpad's y points up; Quartz's points down.
    let location = CGPoint(x: grabOrigin.x + dx * gain, y: grabOrigin.y - dy * gain * aspect)
    MouseTracker.shared.queueExternalMouseUpdate(withMouseLocation: location, timestamp: now)
  }

  private func endGrab() {
    guard isGrabbing else { return }
    isGrabbing = false
    MouseTracker.shared.stopTracking(for: .move)
    endScrollSuppression()
  }

  private static func screenWidth(atQuartzPoint point: CGPoint) -> CGFloat {
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    let cocoa = CGPoint(x: point.x, y: mainHeight - point.y)
    let screen = NSScreen.screens.first { $0.frame.contains(cocoa) } ?? NSScreen.main
    return screen?.frame.width ?? 1440
  }

  // MARK: - Keeping the page from scrolling

  // Two fingers moving on the trackpad also scroll whatever is under the cursor, so while a
  // window is grabbed the scroll events are swallowed. The filter only exists around a grab —
  // a permanent active tap on scrolling would put every scroll in every app behind this
  // process — and outlives it briefly: lifting the fingers starts momentum scrolling, which
  // would otherwise leak through and scroll the page after the window has been dropped.

  private func beginScrollSuppression() {
    dropAllScrollUntil = .infinity
    dropMomentumScrollUntil = .infinity
    guard !isFilteringScroll else { return }
    isFilteringScroll = true
    CGEventSupervisor.shared.subscribe(as: Self.scrollSubscriber, to: .cgEvents(.scrollWheel)) { [weak self] event in
      self?.filterScroll(event)
    }
  }

  private func endScrollSuppression() {
    dropAllScrollUntil = now + 0.15
    dropMomentumScrollUntil = now + 1.5
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
      self?.releaseScrollFilterIfIdle()
    }
  }

  private func releaseScrollFilterIfIdle() {
    guard isFilteringScroll, !isGrabbing, now >= dropMomentumScrollUntil else { return }
    isFilteringScroll = false
    CGEventSupervisor.shared.cancel(subscriber: Self.scrollSubscriber)
  }

  private func filterScroll(_ event: CGEvent) {
    let time = now
    if isGrabbing || time < dropAllScrollUntil {
      event.cancel()
      return
    }
    guard time < dropMomentumScrollUntil else { return }
    let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    guard momentumPhase != 0 else { return }
    event.cancel()
    if momentumPhase == 3 { dropMomentumScrollUntil = 0 } // momentum ended
  }

  // MARK: - Settings indicator

  private func publish(fingers: Int, progress: Double) {
    guard isObserving else { return }
    if fingerCount != fingers { fingerCount = fingers }
    if progress == 0 {
      if swipeProgress != 0 { swipeProgress = 0 }
    } else if abs(swipeProgress - progress) > 0.01 {
      swipeProgress = progress
    }
    publishHoldIndicator()
  }

  private func publishHoldIndicator() {
    guard isObserving else { return }
    let indicator: HoldIndicator
    switch hold.phase {
    case .resting: indicator = .holding
    case .grabbing: indicator = .grabbed
    case .idle, .rejected: indicator = .idle
    }
    if holdIndicator != indicator { holdIndicator = indicator }
  }
}
