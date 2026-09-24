import AppKit

// MARK: - Touches

/// One finger on the trackpad.
struct TrackpadTouch {
  /// Stable for as long as the finger stays down.
  let id: NSObject
  /// 0...1 across the trackpad, origin at the bottom left.
  let position: CGPoint
}

// MARK: - Debug log

/// Development aid: appends what the trackpad monitor sees and decides to
/// `~/Library/Logs/SwiftShift/trackpad.log`. Off unless switched on with
/// `defaults write fr.equiriconi.swiftshift trackpadDebugLog -bool true`; when off, each call
/// costs one branch and builds no string.
enum TrackpadDebugLog {
  static var enabled = false

  private static var handle: FileHandle? = {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SwiftShift")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("trackpad.log")
    // A fresh log per launch, so a session's log holds only that session.
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return try? FileHandle(forWritingTo: url)
  }()

  static func write(_ message: @autoclosure () -> String) {
    guard enabled, let handle else { return }
    let line = String(format: "%9.3f  ", ProcessInfo.processInfo.systemUptime) + message() + "\n"
    handle.write(Data(line.utf8))
  }
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

// MARK: - Monitor

/// Listens to the trackpad and runs the gestures on it.
///
/// A listen-only `CGEventTap` on the gesture events macOS emits whenever fingers touch the
/// trackpad gives access to the raw `NSTouch` data. **Swipe down with three fingers** drops the
/// window under the cursor into the Dock (see `WindowMinimizer`).
final class TrackpadGestureMonitor: ObservableObject {

  static let shared = TrackpadGestureMonitor()

  // Published for the settings indicator, and only while `isObserving`.
  @Published private(set) var fingerCount = 0
  @Published private(set) var swipeProgress: Double = 0
  /// False while a gesture is enabled but Accessibility hasn't been granted, so nothing can
  /// listen to the trackpad. Lets the Trackpad tab say so instead of silently doing nothing.
  @Published private(set) var hasAccessibility = true

  /// Set while the Trackpad tab is visible.
  var isObserving = false

  private(set) var isRunning = false

  // MARK: Configuration (cached from the preferences)

  private var swipeEnabled = false
  private var swipeLength = 0.12
  private var actOnBackgroundWindows = true
  private var showDesktopOnFullScreen = true

  // MARK: State

  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var retryTimer: Timer?
  private let swipe = ThreeFingerSwipeRecognizer()

  private var lastPreferencesSnapshot = ""
  private var lastLoggedTouchCount = -1
  private var lastLoggedAt: TimeInterval = 0

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
    TrackpadDebugLog.enabled = UserDefaults.standard.bool(forKey: "trackpadDebugLog")
    swipeEnabled = PreferencesManager.loadBool(for: .swipeDownMinimize, defaultValue: true)
    swipeLength = PreferencesManager.loadDouble(for: .swipeLength, defaultValue: 0.12)
    actOnBackgroundWindows = PreferencesManager.loadBool(for: .swipeActsOnBackgroundWindows, defaultValue: true)
    showDesktopOnFullScreen = PreferencesManager.loadBool(for: .swipeShowsDesktopOnFullScreen, defaultValue: true)

    let snapshot = "prefs swipe=\(swipeEnabled) length=\(swipeLength) running=\(isRunning)"
    if snapshot != lastPreferencesSnapshot {
      lastPreferencesSnapshot = snapshot
      TrackpadDebugLog.write(snapshot)
    }

    if swipeEnabled {
      start()
    } else {
      swipe.reset()
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
      guard self.swipeEnabled else {
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
    guard PermissionsManager.hasAccessibilityPermission() else {
      if hasAccessibility { hasAccessibility = false }
      TrackpadDebugLog.write("tap: Accessibility not granted, will retry")
      return false
    }
    if !hasAccessibility { hasAccessibility = true }

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
    ) else {
      TrackpadDebugLog.write("tap: CGEvent.tapCreate failed")
      return false
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    self.tap = tap
    self.source = source
    isRunning = true
    TrackpadDebugLog.write("tap: installed")
    return true
  }

  // MARK: - Recognition

  private func handle(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return
    }

    guard let nsEvent = NSEvent(cgEvent: event) else {
      TrackpadDebugLog.write("event type=\(type.rawValue): NSEvent(cgEvent:) returned nil")
      return
    }
    let touches = nsEvent.touches(matching: .touching, in: nil).compactMap { touch -> TrackpadTouch? in
      guard let id = touch.identity as? NSObject else { return nil }
      return TrackpadTouch(id: id, position: touch.normalizedPosition)
    }
    logTouches(type: type, touches: touches)

    var progress = 0.0
    if swipeEnabled {
      let update = swipe.update(touches: touches, now: now, threshold: swipeLength)
      progress = update.progress
      if update.triggered {
        TrackpadDebugLog.write("swipe triggered")
        fireSwipe()
      }
    }
    publish(fingers: touches.count, progress: progress)
  }

  /// One line per change of finger count, and otherwise at most every 100 ms.
  private func logTouches(type: CGEventType, touches: [TrackpadTouch]) {
    guard TrackpadDebugLog.enabled else { return }
    let time = now
    guard touches.count != lastLoggedTouchCount || type.rawValue != 29 || time - lastLoggedAt > 0.1 else { return }
    lastLoggedTouchCount = touches.count
    lastLoggedAt = time
    let fingers = touches
      .map { String(format: "%04x:(%.3f,%.3f)", $0.id.hash & 0xffff, $0.position.x, $0.position.y) }
      .joined(separator: " ")
    TrackpadDebugLog.write("event type=\(type.rawValue) touches=\(touches.count) \(fingers)")
  }

  private func fireSwipe() {
    let background = actOnBackgroundWindows
    let desktop = showDesktopOnFullScreen
    DispatchQueue.main.async {
      WindowMinimizer.minimizeWindowUnderCursor(actOnBackgroundWindows: background, showDesktopOnFullScreen: desktop)
    }
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
  }
}
