import ShortcutRecorder
import CGEventSupervisor
import AppKit

enum ShortcutType: String, CaseIterable {
  case move = "Move"
  case resize = "Resize"
}

enum MouseButton: String, CaseIterable {
  case none = "None"
  case left = "Left"
  case right = "Right"
  case both = "Both"

  static func parse(rawValue: String?) -> MouseButton {
    guard let rawValue = rawValue else { return .none }
    if let value = MouseButton(rawValue: rawValue) {
      return value
    } else {
      return .none
    }
  }
}

extension NSEvent.ModifierFlags {
  static let swiftShiftShortcutMask: NSEvent.ModifierFlags = [.command, .option, .shift, .control, .function]

  var swiftShiftShortcutFlags: NSEvent.ModifierFlags {
    intersection(.swiftShiftShortcutMask)
  }
}

struct KeyboardShortcut: Codable, Equatable {
  var keyCode: UInt16?
  private var modifierFlagsRawValue: UInt
  var characters: String?
  var charactersIgnoringModifiers: String?

  var modifierFlags: NSEvent.ModifierFlags {
    get { NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue).swiftShiftShortcutFlags }
    set { modifierFlagsRawValue = newValue.swiftShiftShortcutFlags.rawValue }
  }

  var isModifierOnly: Bool {
    keyCode == nil
  }

  var usesFunctionModifier: Bool {
    modifierFlags.contains(.function)
  }

  var shortcutRecorderShortcut: Shortcut? {
    guard !usesFunctionModifier else { return nil }
    let rawKeyCode = keyCode ?? UInt16.max
    guard let shortcutKeyCode = KeyCode(rawValue: rawKeyCode) else { return nil }

    return Shortcut(
      code: shortcutKeyCode,
      modifierFlags: modifierFlags,
      characters: characters,
      charactersIgnoringModifiers: keyCode == nil ? nil : charactersIgnoringModifiers
    )
  }

  var displayString: String {
    let flags = modifierFlags
    var parts: [String] = []

    if flags.contains(.function) { parts.append("fn") }
    if flags.contains(.control) { parts.append("⌃") }
    if flags.contains(.option) { parts.append("⌥") }
    if flags.contains(.shift) { parts.append("⇧") }
    if flags.contains(.command) { parts.append("⌘") }

    if let keyCode = keyCode {
      parts.append(Self.displayString(forKeyCode: keyCode, charactersIgnoringModifiers: charactersIgnoringModifiers))
    }

    return parts.isEmpty ? "Record Shortcut" : parts.joined()
  }

  init(keyCode: UInt16?, modifierFlags: NSEvent.ModifierFlags, characters: String? = nil, charactersIgnoringModifiers: String? = nil) {
    self.keyCode = keyCode
    self.modifierFlagsRawValue = modifierFlags.swiftShiftShortcutFlags.rawValue
    self.characters = characters
    self.charactersIgnoringModifiers = charactersIgnoringModifiers
  }

  init(shortcut: Shortcut) {
    let legacyKeyCode = shortcut.keyCode.rawValue
    let isModifierOnly = shortcut.charactersIgnoringModifiers == nil || legacyKeyCode == UInt16.max
    self.init(
      keyCode: isModifierOnly ? nil : legacyKeyCode,
      modifierFlags: shortcut.modifierFlags,
      characters: shortcut.characters,
      charactersIgnoringModifiers: shortcut.charactersIgnoringModifiers
    )
  }

  static func canUseWithoutModifiers(keyCode: UInt16) -> Bool {
    functionKeyCodes.contains(keyCode)
  }

  private static let functionKeyCodes = Set<UInt16>([
    122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
    103, 111, 105, 107, 113, 106, 64, 79, 80, 90
  ])

  private static func displayString(forKeyCode keyCode: UInt16, charactersIgnoringModifiers: String?) -> String {
    if let charactersIgnoringModifiers = charactersIgnoringModifiers, !charactersIgnoringModifiers.isEmpty {
      if charactersIgnoringModifiers == " " {
        return "Space"
      }
      return charactersIgnoringModifiers.uppercased()
    }

    switch keyCode {
    case 36: return "Return"
    case 48: return "Tab"
    case 49: return "Space"
    case 51: return "Delete"
    case 53: return "Esc"
    case 64: return "F17"
    case 79: return "F18"
    case 80: return "F19"
    case 90: return "F20"
    case 96: return "F5"
    case 97: return "F6"
    case 98: return "F7"
    case 99: return "F3"
    case 100: return "F8"
    case 101: return "F9"
    case 103: return "F11"
    case 105: return "F13"
    case 106: return "F16"
    case 107: return "F14"
    case 109: return "F10"
    case 111: return "F12"
    case 113: return "F15"
    case 118: return "F4"
    case 120: return "F2"
    case 122: return "F1"
    case 123: return "Left"
    case 124: return "Right"
    case 125: return "Down"
    case 126: return "Up"
    default: return "<\(keyCode)>"
    }
  }
}

struct UserShortcut {
  var type: ShortcutType
  var shortcut: Shortcut?
  var keyboardShortcut: KeyboardShortcut?
  var mouseButton: MouseButton
  var keyboardEnabled: Bool
  var mouseEnabled: Bool

  init(type: ShortcutType, shortcut: Shortcut? = nil, keyboardShortcut: KeyboardShortcut? = nil, mouseButton: MouseButton, keyboardEnabled: Bool = true, mouseEnabled: Bool = false) {
    self.type = type
    self.shortcut = shortcut
    self.keyboardShortcut = keyboardShortcut ?? shortcut.map { KeyboardShortcut(shortcut: $0) }
    self.mouseButton = mouseButton
    self.keyboardEnabled = keyboardEnabled
    self.mouseEnabled = mouseEnabled
  }
}

extension Notification.Name {
  static let shortcutsDidChange = Notification.Name("shortcutsDidChange")
}

class ShortcutsManager {
  static let shared = ShortcutsManager()
  var globalMonitors: [Any] = []
  private(set) var activeShortcuts: [ShortcutType: Bool] = [:]
  private var mouseSubscriptions: Set<String> = []
  private var workspaceNotificationObserver: Any?
  private var systemEventObservers: [Any] = []
  var hasActiveShortcut: Bool {
    activeShortcuts.values.contains(true)
  }

  private init() {
    for type in ShortcutType.allCases {
      activeShortcuts[type] = false
    }
    registerForWorkspaceNotifications()
    registerForSystemEventNotifications()
    updateGlobalShortcuts()
  }

  deinit {
    unregisterForWorkspaceNotifications()
    unregisterForSystemEventNotifications()
  }

  private func registerForWorkspaceNotifications() {
    let notificationCenter = NSWorkspace.shared.notificationCenter
    workspaceNotificationObserver = notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main) { [weak self] _ in
        self?.handleSpaceChange()
      }
  }

  private func unregisterForWorkspaceNotifications() {
    if let observer = workspaceNotificationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      workspaceNotificationObserver = nil
    }
  }

  /// Register for system events that can silently disable the CGEventTap.
  /// macOS kills event taps on sleep/wake, display changes, and session
  /// transitions without notifying the app. We rebuild all input hooks
  /// when these occur — the same effect as restarting the app.
  private func registerForSystemEventNotifications() {
    let nc = NSWorkspace.shared.notificationCenter

    let wakeObserver = nc.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main) { [weak self] _ in
        self?.rebuildAllInputHooks()
      }
    systemEventObservers.append(wakeObserver)

    let sessionObserver = nc.addObserver(
      forName: NSWorkspace.sessionDidBecomeActiveNotification,
      object: nil,
      queue: .main) { [weak self] _ in
        self?.rebuildAllInputHooks()
      }
    systemEventObservers.append(sessionObserver)

    let screensObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main) { [weak self] _ in
        self?.rebuildAllInputHooks()
      }
    systemEventObservers.append(screensObserver)
  }

  private func unregisterForSystemEventNotifications() {
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    let defaultCenter = NotificationCenter.default
    for observer in systemEventObservers {
      workspaceCenter.removeObserver(observer)
      defaultCenter.removeObserver(observer)
    }
    systemEventObservers = []
  }

  /// Fully tear down and rebuild all input interception infrastructure.
  /// Call this when the CGEventTap may have been disabled by the system
  /// (sleep, display change, session lock, etc.).
  private func rebuildAllInputHooks() {
    // Clear active shortcut state — after a system event we can't
    // trust that modifier keys are still held. Let next key event
    // re-establish tracking naturally.
    for type in ShortcutType.allCases where activeShortcuts[type] == true {
      let action: MouseAction = type == .move ? .move : .resize
      MouseTracker.shared.stopTracking(for: action)
      cleanupMouseSubscriptions(action: action)
      activeShortcuts[type] = false
    }

    CGEventSupervisor.shared.cancelAll()
    updateGlobalShortcuts()
    MouseChordActionManager.shared.forceRebuild()
    DoubleTapActionManager.shared.forceRebuild()
  }

  private func handleSpaceChange() {
    for type in ShortcutType.allCases where activeShortcuts[type] == true {
      let action: MouseAction = type == .move ? .move : .resize
      if let loaded = load(for: type) {
        stopTracking(loaded, action)
      } else {
        MouseTracker.shared.stopTracking(for: action)
        cleanupMouseSubscriptions(action: action)
        activeShortcuts[type] = false
      }
    }
  }

  func cleanupAllShortcuts() {
    for type in ShortcutType.allCases {
      if activeShortcuts[type] == true {
        let action = type == .move ? MouseAction.move : MouseAction.resize
        MouseTracker.shared.stopTracking(for: action)
        cleanupMouseSubscriptions(action: action)
      }
    }
    removeGlobalMonitors()
    removeAllActions()
    for type in ShortcutType.allCases {
      activeShortcuts[type] = false
    }
    unregisterForWorkspaceNotifications()
  }

  func save(_ userShortcut: UserShortcut) {
    if let keyboardShortcut = userShortcut.keyboardShortcut {
      do {
        let data = try JSONEncoder().encode(keyboardShortcut)
        UserDefaults.standard.set(data, forKey: keyboardShortcutKey(for: userShortcut.type))

        if let shortcut = userShortcut.shortcut ?? keyboardShortcut.shortcutRecorderShortcut {
          let data = try NSKeyedArchiver.archivedData(withRootObject: shortcut, requiringSecureCoding: false)
          UserDefaults.standard.set(data, forKey: userShortcut.type.rawValue)
        } else {
          UserDefaults.standard.removeObject(forKey: userShortcut.type.rawValue)
        }
      } catch {
        print("Error: \(error)")
      }
    } else {
      UserDefaults.standard.removeObject(forKey: keyboardShortcutKey(for: userShortcut.type))
      UserDefaults.standard.removeObject(forKey: userShortcut.type.rawValue)
    }

    UserDefaults.standard.set(userShortcut.mouseButton.rawValue, forKey: mouseButtonKey(for: userShortcut.type))
    UserDefaults.standard.set(userShortcut.keyboardEnabled, forKey: keyboardEnabledKey(for: userShortcut.type))
    UserDefaults.standard.set(userShortcut.mouseEnabled, forKey: mouseEnabledKey(for: userShortcut.type))

    updateGlobalShortcuts()
    MouseChordActionManager.shared.updateSubscriptions()
    DoubleTapActionManager.shared.updateSubscriptions()
    NotificationCenter.default.post(name: .shortcutsDidChange, object: userShortcut.type)
  }

  func load(for type: ShortcutType) -> UserShortcut? {
    let mouseButton = MouseButton.parse(rawValue: UserDefaults.standard.string(forKey: mouseButtonKey(for: type)))
    let hasSavedKeyboardTrigger = UserDefaults.standard.object(forKey: keyboardEnabledKey(for: type)) != nil
    let hasSavedMouseTrigger = UserDefaults.standard.object(forKey: mouseEnabledKey(for: type)) != nil
    let keyboardEnabled = loadTriggerBool(forKey: keyboardEnabledKey(for: type), defaultValue: true)
    let mouseEnabled = loadTriggerBool(
      forKey: mouseEnabledKey(for: type),
      defaultValue: !hasSavedKeyboardTrigger && !hasSavedMouseTrigger && PreferencesManager.loadBool(for: .requireMouseClick) && mouseButton != .none
    )

    if let data = UserDefaults.standard.data(forKey: keyboardShortcutKey(for: type)) {
      do {
        let keyboardShortcut = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        let shortcut = loadLegacyShortcut(for: type) ?? keyboardShortcut.shortcutRecorderShortcut
        return UserShortcut(type: type, shortcut: shortcut, keyboardShortcut: keyboardShortcut, mouseButton: mouseButton, keyboardEnabled: keyboardEnabled, mouseEnabled: mouseEnabled)
      } catch {
        print("Error decoding shortcut: \(error.localizedDescription)")
      }
    }

    if let shortcut = loadLegacyShortcut(for: type) {
      let migrated = UserShortcut(type: type, shortcut: shortcut, mouseButton: mouseButton, keyboardEnabled: keyboardEnabled, mouseEnabled: mouseEnabled)

      if let keyboardShortcut = migrated.keyboardShortcut {
        do {
          let data = try JSONEncoder().encode(keyboardShortcut)
          UserDefaults.standard.set(data, forKey: keyboardShortcutKey(for: type))
          UserDefaults.standard.set(mouseButton.rawValue, forKey: mouseButtonKey(for: type))
        } catch {
          print("Error migrating shortcut: \(error.localizedDescription)")
        }
      }

      return migrated
    }

    return UserShortcut(type: type, mouseButton: mouseButton, keyboardEnabled: keyboardEnabled, mouseEnabled: mouseEnabled)
  }

  func delete(for type: ShortcutType) {
    UserDefaults.standard.removeObject(forKey: keyboardShortcutKey(for: type))
    UserDefaults.standard.removeObject(forKey: type.rawValue)
    UserDefaults.standard.removeObject(forKey: mouseButtonKey(for: type))
    UserDefaults.standard.removeObject(forKey: keyboardEnabledKey(for: type))
    UserDefaults.standard.removeObject(forKey: mouseEnabledKey(for: type))
    updateGlobalShortcuts()
    MouseChordActionManager.shared.updateSubscriptions()
    DoubleTapActionManager.shared.updateSubscriptions()
    NotificationCenter.default.post(name: .shortcutsDidChange, object: type)
  }

  func removeClickActionsForAll() {
    for type in ShortcutType.allCases {
      if var userShortcut = load(for: type) {
        userShortcut.mouseButton = .none
        userShortcut.mouseEnabled = false
        self.save(userShortcut)
      }
    }
  }

  private func clearActionsAndMonitors() {
    removeAllActions()
    removeGlobalMonitors()
    cleanupAllMouseSubscriptions()
  }

  private func removeAllActions() {
    AppDelegate.shared.shortcutMonitor?.removeAllActions()
  }

  private func removeGlobalMonitors() {
    for monitor in self.globalMonitors {
      NSEvent.removeMonitor(monitor)
    }
    self.globalMonitors = []
  }

  private func cleanupAllMouseSubscriptions() {
    for subscriptionKey in mouseSubscriptions {
      CGEventSupervisor.shared.cancel(subscriber: subscriptionKey)
    }
    mouseSubscriptions.removeAll()
  }

  private func keyboardShortcutKey(for type: ShortcutType) -> String {
    "\(type.rawValue)_keyboardShortcut"
  }

  private func mouseButtonKey(for type: ShortcutType) -> String {
    "\(type.rawValue)_mouseButton"
  }

  private func keyboardEnabledKey(for type: ShortcutType) -> String {
    "\(type.rawValue)_keyboardEnabled"
  }

  private func mouseEnabledKey(for type: ShortcutType) -> String {
    "\(type.rawValue)_mouseEnabled"
  }

  private func loadTriggerBool(forKey key: String, defaultValue: Bool) -> Bool {
    guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
    return UserDefaults.standard.bool(forKey: key)
  }

  private func loadLegacyShortcut(for type: ShortcutType) -> Shortcut? {
    guard let data = UserDefaults.standard.data(forKey: type.rawValue) else { return nil }
    do {
      return try NSKeyedUnarchiver.unarchivedObject(ofClass: Shortcut.self, from: data)
    } catch {
      print("Error unarchiving data: \(error.localizedDescription)")
      return nil
    }
  }

  // Regular shortcuts (key + modifiers)
  private func addActions(mouseAction: MouseAction, for userShortcut: UserShortcut) {
    guard let shortcut = userShortcut.shortcut else { return }

    let keydownAction = ShortcutAction(shortcut: shortcut) { _ in
      self.activeShortcuts[userShortcut.type] = true
      self.startTracking(userShortcut, mouseAction)
      return true
    }

    let keyupAction = ShortcutAction(shortcut: shortcut) { _ in
      self.stopTracking(userShortcut, mouseAction)
      self.activeShortcuts[userShortcut.type] = false
      return true
    }

    AppDelegate.shared.shortcutMonitor?.addAction(keydownAction, forKeyEvent: .down)
    AppDelegate.shared.shortcutMonitor?.addAction(keyupAction, forKeyEvent: .up)
  }

  // Handle modifier-only shortcuts
  private func addGlobalMonitors(mouseAction: MouseAction, for userShortcut: UserShortcut) {
    guard let shortcut = userShortcut.shortcut else { return }

    let flagsChangedHandler: (NSEvent) -> Void = { [weak self] event in
      guard let self = self else { return }

      let eventFlags = event.modifierFlags.swiftShiftShortcutFlags
      let shortcutFlags = shortcut.modifierFlags.swiftShiftShortcutFlags
      let shortcutType = userShortcut.type
      let isActive = self.activeShortcuts[shortcutType] ?? false
      let keysDown = self.checkForAdditionalKeysDown()

      if eventFlags == shortcutFlags && !isActive && !keysDown {
        self.startTracking(userShortcut, mouseAction)
        self.activeShortcuts[shortcutType] = true
      } else if eventFlags != shortcutFlags && isActive {
        self.stopTracking(userShortcut, mouseAction)
        self.activeShortcuts[shortcutType] = false
      }
    }

    if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: flagsChangedHandler) {
      globalMonitors.append(monitor)
    }

    // Monitor key events to release shortcut when non-modifier keys are pressed
    if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp], handler: { [weak self] event in
      guard let self = self else { return }

      for type in ShortcutType.allCases {
        if self.activeShortcuts[type] == true {
          let action = type == .move ? MouseAction.move : MouseAction.resize
          if let loaded = self.load(for: type) {
            self.stopTracking(loaded, action)
          } else {
            MouseTracker.shared.stopTracking(for: action)
          }
          self.activeShortcuts[type] = false
        }
      }
    }) {
      globalMonitors.append(monitor)
    }

    if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { event in
      flagsChangedHandler(event)
      return event
    }) {
      globalMonitors.append(monitor)
    }
  }

  private func addEventMonitors(mouseAction: MouseAction, for userShortcut: UserShortcut) {
    guard userShortcut.keyboardShortcut != nil else { return }

    let eventHandler: (NSEvent) -> Void = { [weak self] event in
      self?.handleShortcutEvent(event, mouseAction: mouseAction, for: userShortcut)
    }

    if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp], handler: eventHandler) {
      globalMonitors.append(monitor)
    }

    if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp], handler: { event in
      eventHandler(event)
      return event
    }) {
      globalMonitors.append(monitor)
    }
  }

  private func handleShortcutEvent(_ event: NSEvent, mouseAction: MouseAction, for userShortcut: UserShortcut) {
    guard let keyboardShortcut = userShortcut.keyboardShortcut else { return }

    let shortcutType = userShortcut.type
    let isActive = activeShortcuts[shortcutType] ?? false

    switch event.type {
    case .flagsChanged:
      if keyboardShortcut.isModifierOnly {
        let isMatching = event.modifierFlags.swiftShiftShortcutFlags == keyboardShortcut.modifierFlags
        if isMatching && !isActive {
          startTracking(userShortcut, mouseAction)
          activeShortcuts[shortcutType] = true
        } else if !isMatching && isActive {
          stopTracking(userShortcut, mouseAction)
        }
      } else if isActive && event.modifierFlags.swiftShiftShortcutFlags != keyboardShortcut.modifierFlags {
        stopTracking(userShortcut, mouseAction)
      }
    case .keyDown:
      guard !event.isARepeat else { return }

      if keyboardShortcut.isModifierOnly {
        if isActive {
          stopTracking(userShortcut, mouseAction)
        }
      } else if matches(event, keyboardShortcut) {
        if !isActive {
          activeShortcuts[shortcutType] = true
          startTracking(userShortcut, mouseAction)
        }
      } else if isActive {
        stopTracking(userShortcut, mouseAction)
      }
    case .keyUp:
      if keyboardShortcut.isModifierOnly {
        if isActive {
          stopTracking(userShortcut, mouseAction)
        }
      } else if event.keyCode == keyboardShortcut.keyCode && isActive {
        stopTracking(userShortcut, mouseAction)
      }
    default:
      break
    }
  }

  private func matches(_ event: NSEvent, _ shortcut: KeyboardShortcut) -> Bool {
    guard let keyCode = shortcut.keyCode else { return false }
    return event.keyCode == keyCode && event.modifierFlags.swiftShiftShortcutFlags == shortcut.modifierFlags
  }

  private func checkForAdditionalKeysDown() -> Bool {
    guard let currentEvent = NSApp.currentEvent else { return false }
    switch currentEvent.type {
    case .keyDown, .keyUp:
      let nonModifierKeyCodes = Set<UInt16>(36...126)
      if nonModifierKeyCodes.contains(currentEvent.keyCode) {
        return true
      }
    default:
      break
    }
    return false
  }

  private func updateGlobalShortcuts() {
    clearActionsAndMonitors()

    for type in ShortcutType.allCases {
      if let userShortcut = load(for: type), userShortcut.keyboardEnabled, let keyboardShortcut = userShortcut.keyboardShortcut {
        let mouseAction = type == .move ? MouseAction.move : MouseAction.resize

        if keyboardShortcut.usesFunctionModifier || userShortcut.shortcut == nil {
          addEventMonitors(mouseAction: mouseAction, for: userShortcut)
        } else if let shortcut = userShortcut.shortcut {
          let isModifierOnlyShortcut = keyboardShortcut.isModifierOnly || shortcut.charactersIgnoringModifiers == nil

          if isModifierOnlyShortcut {
            addGlobalMonitors(mouseAction: mouseAction, for: userShortcut)
          } else {
            addActions(mouseAction: mouseAction, for: userShortcut)
          }
        } else {
          addEventMonitors(mouseAction: mouseAction, for: userShortcut)
        }
      }
    }
  }

  private func startTracking(_ userShortcut: UserShortcut, _ action: MouseAction) {
    if !userShortcut.mouseEnabled || userShortcut.mouseButton == .none {
      MouseTracker.shared.startTracking(for: action, button: .none)
      return
    }

    if userShortcut.mouseButton == .both {
      startTrackingWithBothMouseButtons(userShortcut, action)
      return
    }

    let downEvent: CGEventType = userShortcut.mouseButton == .left ? .leftMouseDown : .rightMouseDown
    let upEvent: CGEventType = userShortcut.mouseButton == .left ? .leftMouseUp : .rightMouseUp
    let downKey = "\(action.rawValue)_mouseDown"
    let upKey = "\(action.rawValue)_mouseUp"

    // Be defensive: shortcut events can arrive repeatedly or cleanup can be skipped
    // by system state changes. Ensure we never accumulate duplicate event taps.
    cleanupMouseSubscriptions(action: action)

    CGEventSupervisor.shared.subscribe(
      as: downKey,
      to: .cgEvents(downEvent),
      using: { [weak self] event in
        guard let self = self, self.activeShortcuts[userShortcut.type] == true else { return }
        guard self.isShortcutStillPressed(userShortcut) else {
          self.stopTracking(userShortcut, action)
          return
        }
        event.cancel()
        MouseTracker.shared.startTracking(for: action, button: userShortcut.mouseButton)
      })

    CGEventSupervisor.shared.subscribe(
      as: upKey,
      to: .cgEvents(upEvent),
      using: { [weak self] event in
        guard let self = self, self.activeShortcuts[userShortcut.type] == true else { return }
        guard self.isShortcutStillPressed(userShortcut) else {
          self.stopTracking(userShortcut, action)
          return
        }
        event.cancel()
        MouseTracker.shared.stopTracking(for: action)
      })

    mouseSubscriptions.insert(downKey)
    mouseSubscriptions.insert(upKey)
  }

  private func startTrackingWithBothMouseButtons(_ userShortcut: UserShortcut, _ action: MouseAction) {
    let downKey = "\(action.rawValue)_mouseDown"
    let upKey = "\(action.rawValue)_mouseUp"
    var leftButtonIsDown = false
    var rightButtonIsDown = false
    var isMouseTracking = false

    cleanupMouseSubscriptions(action: action)

    CGEventSupervisor.shared.subscribe(
      as: downKey,
      to: .cgEvents(.leftMouseDown, .rightMouseDown),
      using: { [weak self] event in
        guard let self = self, self.activeShortcuts[userShortcut.type] == true else { return }
        guard self.isShortcutStillPressed(userShortcut) else {
          self.stopTracking(userShortcut, action)
          return
        }

        if event.type == .leftMouseDown {
          leftButtonIsDown = true
        } else if event.type == .rightMouseDown {
          rightButtonIsDown = true
        }

        event.cancel()

        if leftButtonIsDown && rightButtonIsDown && !isMouseTracking {
          isMouseTracking = true
          MouseTracker.shared.startTracking(for: action, button: .both)
        }
      })

    CGEventSupervisor.shared.subscribe(
      as: upKey,
      to: .cgEvents(.leftMouseUp, .rightMouseUp),
      using: { [weak self] event in
        guard let self = self, self.activeShortcuts[userShortcut.type] == true else { return }
        guard self.isShortcutStillPressed(userShortcut) else {
          self.stopTracking(userShortcut, action)
          return
        }

        if event.type == .leftMouseUp {
          leftButtonIsDown = false
        } else if event.type == .rightMouseUp {
          rightButtonIsDown = false
        }

        event.cancel()

        if isMouseTracking {
          MouseTracker.shared.stopTracking(for: action)
          isMouseTracking = false
        }
      })

    mouseSubscriptions.insert(downKey)
    mouseSubscriptions.insert(upKey)
  }

  private func stopTracking(_ userShortcut: UserShortcut, _ action: MouseAction) {
    MouseTracker.shared.stopTracking(for: action)
    cleanupMouseSubscriptions(action: action)
    activeShortcuts[userShortcut.type] = false
  }

  private func isShortcutStillPressed(_ userShortcut: UserShortcut) -> Bool {
    guard let keyboardShortcut = userShortcut.keyboardShortcut else { return false }
    return NSEvent.modifierFlags.swiftShiftShortcutFlags == keyboardShortcut.modifierFlags
  }

  private func cleanupMouseSubscriptions(action: MouseAction) {
    let downKey = "\(action.rawValue)_mouseDown"
    let upKey = "\(action.rawValue)_mouseUp"

    CGEventSupervisor.shared.cancel(subscriber: downKey)
    CGEventSupervisor.shared.cancel(subscriber: upKey)

    mouseSubscriptions.remove(downKey)
    mouseSubscriptions.remove(upKey)
  }
}

class MouseChordActionManager {
  static let shared = MouseChordActionManager()

  private struct PendingMouseDown {
    let event: CGEvent
  }

  private let subscriberKey = "mouseOnlyBothButtonsChord"
  private let replayedMouseEventMarker: Int64 = 0x5357465453484946
  private var isSubscribed = false
  private var activeAction: MouseAction?
  private var cachedMouseOnlyAction: MouseAction?
  private var isChordSuppressed = false
  private var isPassingThroughMouseGesture = false
  private var pendingInitialMouseDown: PendingMouseDown?
  private var leftButtonIsDown = false
  private var rightButtonIsDown = false
  private var workspaceNotificationObserver: Any?
  private var healthCheckTimer: Timer?

  private init() {
    registerForWorkspaceNotifications()
    startHealthCheckTimer()
  }

  deinit {
    cleanup()
  }

  func updateSubscriptions() {
    cachedMouseOnlyAction = configuredMouseOnlyAction()

    if cachedMouseOnlyAction != nil {
      subscribeIfNeeded()
    } else {
      stopChordAction(resetButtons: true)
      unsubscribe()
    }
  }

  /// Force teardown and rebuild of mouse-only chord subscriptions.
  /// Use after system events (sleep, display change, session lock)
  /// that may have disabled the CGEventTap without our knowledge.
  func forceRebuild() {
    stopChordAction(resetButtons: true)
    unsubscribe()
    cachedMouseOnlyAction = nil
    updateSubscriptions()
  }

  /// Periodic health check for the CGEventTap. macOS can silently disable
  /// taps during Secure Input sessions (password prompts, sudo in Terminal)
  /// with no notification. This timer ensures we recover within 60 seconds.
  private func startHealthCheckTimer() {
    healthCheckTimer?.invalidate()
    healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      guard let self = self, self.isSubscribed else { return }
      // Don't rebuild mid-gesture — would drop pending mouse events
      // activeAction is set during an active chord drag;
      // pendingInitialMouseDown is set between the first and second button press
      guard self.activeAction == nil, self.pendingInitialMouseDown == nil else { return }
      self.forceRebuild()
    }
  }

  func cleanup() {
    healthCheckTimer?.invalidate()
    healthCheckTimer = nil
    stopChordAction(resetButtons: true)
    unsubscribe()
    unregisterForWorkspaceNotifications()
  }

  private func registerForWorkspaceNotifications() {
    let notificationCenter = NSWorkspace.shared.notificationCenter
    workspaceNotificationObserver = notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main) { [weak self] _ in
        self?.stopChordAction(resetButtons: true)
      }
  }

  private func unregisterForWorkspaceNotifications() {
    if let observer = workspaceNotificationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      workspaceNotificationObserver = nil
    }
  }

  private func subscribeIfNeeded() {
    guard !isSubscribed else {
      return
    }

    CGEventSupervisor.shared.subscribe(
      as: subscriberKey,
      to: .cgEvents(.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .leftMouseDragged, .rightMouseDragged),
      using: { [weak self] event in
        self?.handle(event)
      })

    isSubscribed = true
  }

  private func unsubscribe() {
    guard isSubscribed else {
      return
    }
    CGEventSupervisor.shared.cancel(subscriber: subscriberKey)
    isSubscribed = false
  }

  private func handle(_ event: CGEvent) {
    guard !isReplayedMouseEvent(event) else {
      return
    }

    syncButtonStateFromSystem()

    guard cachedMouseOnlyAction != nil else {
      stopChordAction(resetButtons: true)
      unsubscribe()
      return
    }

    switch event.type {
    case .leftMouseDown:
      leftButtonIsDown = true
      handleButtonDown(event)
    case .rightMouseDown:
      rightButtonIsDown = true
      handleButtonDown(event)
    case .leftMouseUp:
      leftButtonIsDown = false
      handleButtonUp(event)
    case .rightMouseUp:
      rightButtonIsDown = false
      handleButtonUp(event)
    case .leftMouseDragged, .rightMouseDragged:
      handleDrag(event)
    default:
      break
    }

    recoverIfGestureEnded()
  }

  private func handleButtonDown(_ event: CGEvent) {
    if activeAction != nil || isChordSuppressed {
      event.cancel()
      return
    }

    if isPassingThroughMouseGesture {
      return
    }

    guard pendingInitialMouseDown != nil else {
      if capturePendingInitialMouseDown(event) {
        event.cancel()
      }
      return
    }

    if startChordActionIfReady(eventToCancelOnSuccess: event) {
      pendingInitialMouseDown = nil
      return
    }

    replayPendingInitialMouseDown()
    isPassingThroughMouseGesture = true
  }

  private func handleButtonUp(_ event: CGEvent) {
    if activeAction != nil || isChordSuppressed {
      event.cancel()
      stopActiveChordAction()
      clearSuppressionIfChordEnded()
      return
    }

    if pendingInitialMouseDown != nil {
      replayPendingInitialMouseDown()
      replayMouseEvent(event)
      event.cancel()
      clearPassThroughIfGestureEnded()
      return
    }

    if isPassingThroughMouseGesture {
      clearPassThroughIfGestureEnded()
    }
  }

  private func handleDrag(_ event: CGEvent) {
    if activeAction != nil || isChordSuppressed {
      if leftButtonIsDown && rightButtonIsDown && !ShortcutsManager.shared.hasActiveShortcut, activeAction != nil {
        MouseTracker.shared.queueExternalMouseUpdate(withMouseLocation: event.location, timestamp: ProcessInfo.processInfo.systemUptime)
      } else {
        stopActiveChordAction()
        clearSuppressionIfChordEnded()
      }

      event.cancel()
      return
    }

    if isPassingThroughMouseGesture {
      return
    }

    if pendingInitialMouseDown != nil {
      if startChordActionIfReady(eventToCancelOnSuccess: event) {
        pendingInitialMouseDown = nil
        return
      }

      replayPendingInitialMouseDown()
      replayMouseEvent(event)
      event.cancel()
      isPassingThroughMouseGesture = true
      return
    }

    _ = startChordActionIfReady(eventToCancelOnSuccess: event)
  }

  @discardableResult
  private func startChordActionIfReady(eventToCancelOnSuccess event: CGEvent) -> Bool {
    guard leftButtonIsDown && rightButtonIsDown else {
      return false
    }

    guard !ShortcutsManager.shared.hasActiveShortcut, let action = cachedMouseOnlyAction else {
      return false
    }

    let initialMouseLocation = pendingInitialMouseDown?.event.location ?? event.location

    if MouseTracker.shared.startTrackingForExternalMouseUpdates(for: action, initialMouseLocation: initialMouseLocation) {
      activeAction = action
      isChordSuppressed = true
      event.cancel()
      return true
    }

    return false
  }

  private func capturePendingInitialMouseDown(_ event: CGEvent) -> Bool {
    guard let copiedEvent = event.copy() else {
      return false
    }

    pendingInitialMouseDown = PendingMouseDown(event: copiedEvent)
    return true
  }

  private func replayPendingInitialMouseDown() {
    guard let pendingInitialMouseDown else {
      return
    }

    replayMouseEvent(pendingInitialMouseDown.event)
    self.pendingInitialMouseDown = nil
  }

  private func replayMouseEvent(_ event: CGEvent) {
    guard let copiedEvent = event.copy() else {
      return
    }

    copiedEvent.setIntegerValueField(.eventSourceUserData, value: replayedMouseEventMarker)
    copiedEvent.post(tap: .cghidEventTap)
  }

  private func isReplayedMouseEvent(_ event: CGEvent) -> Bool {
    event.getIntegerValueField(.eventSourceUserData) == replayedMouseEventMarker
  }

  private func stopChordAction(resetButtons: Bool) {
    stopActiveChordAction()
    pendingInitialMouseDown = nil
    isPassingThroughMouseGesture = false

    if resetButtons {
      leftButtonIsDown = false
      rightButtonIsDown = false
      isChordSuppressed = false
    } else {
      clearSuppressionIfChordEnded()
    }
  }

  private func stopActiveChordAction() {
    if let activeAction {
      MouseTracker.shared.stopTracking(for: activeAction)
      self.activeAction = nil
    }
  }

  private func clearSuppressionIfChordEnded() {
    if !leftButtonIsDown && !rightButtonIsDown {
      isChordSuppressed = false
    }
  }

  private func clearPassThroughIfGestureEnded() {
    if !leftButtonIsDown && !rightButtonIsDown {
      isPassingThroughMouseGesture = false
    }
  }

  private func syncButtonStateFromSystem() {
    let leftIsPressed = CGEventSource.buttonState(.hidSystemState, button: .left)
    let rightIsPressed = CGEventSource.buttonState(.hidSystemState, button: .right)
    leftButtonIsDown = leftIsPressed
    rightButtonIsDown = rightIsPressed
  }

  private func recoverIfGestureEnded() {
    syncButtonStateFromSystem()

    if !leftButtonIsDown && !rightButtonIsDown {
      stopChordAction(resetButtons: true)
    }
  }

  private func configuredMouseOnlyAction() -> MouseAction? {
    for type in ShortcutType.allCases {
      guard let shortcut = ShortcutsManager.shared.load(for: type), !shortcut.keyboardEnabled, shortcut.mouseEnabled else {
        continue
      }
      return type == .move ? .move : .resize
    }

    return nil
  }
}

// MARK: - Double-tap modifier actions

enum WindowSnapAction {
  /// Fill the screen; a second trigger on an already-maximized window restores it.
  case toggleMaximize
  /// Minimize the window to the Dock.
  case minimize
}

/// Applies `WindowSnapAction`s to the window under the cursor (falling back to the
/// focused window). Keeps a small history of pre-maximize frames so the maximize
/// action can toggle back to where the window was.
final class WindowSnapActionRunner {
  static let shared = WindowSnapActionRunner()
  private init() {}

  private struct MaximizedRecord {
    let window: AXUIElement
    let restoreFrame: CGRect
  }

  private var maximizedRecords: [MaximizedRecord] = []
  private let maxRecords = 12
  /// Frames within this many points of the screen's visible frame count as "maximized".
  private let frameTolerance: CGFloat = 4
  /// How long the maximize / restore glide takes.
  private let animationDuration: TimeInterval = 0.18
  private var animator: WindowFrameAnimator?

  func perform(_ action: WindowSnapAction) {
    guard let window = targetWindow() else {
      NSSound.beep()
      return
    }

    switch action {
    case .toggleMaximize:
      toggleMaximize(window)
    case .minimize:
      WindowManager.setMinimized(window: window, true)
    }
  }

  private func targetWindow() -> AXUIElement? {
    if let underCursor = WindowManager.getCurrentWindow(), !isIgnored(underCursor) {
      return underCursor
    }
    return WindowManager.getFocusedWindow()
  }

  private func isIgnored(_ window: AXUIElement) -> Bool {
    guard let app = WindowManager.getNSApplication(from: window), let bundleId = app.bundleIdentifier else { return false }
    return PreferencesManager.isAppIgnored(bundleId)
  }

  private func toggleMaximize(_ window: AXUIElement) {
    guard let liveFrame = WindowManager.getFrame(window: window),
          let visibleFrame = WindowManager.screenAXVisibleFrame(containing: liveFrame) else { return }

    // Leave the same edge gap macOS uses when its "Tiled windows have margins"
    // setting is on; go fully edge-to-edge otherwise.
    let margin = WindowManager.tiledWindowMarginInset()
    let maximizeTarget = margin > 0 ? visibleFrame.insetBy(dx: margin, dy: margin) : visibleFrame

    // If a glide for this window is still running, reason about its destination
    // rather than the half-way frame the window is currently at.
    let current = (animator.flatMap { CFEqual($0.window, window) ? $0.targetFrame : nil }) ?? liveFrame

    maximizedRecords.removeAll { !WindowManager.isAlive(window: $0.window) }
    let recordIndex = maximizedRecords.firstIndex { CFEqual($0.window, window) }
    let isMaximized = rectsApproximatelyEqual(current, maximizeTarget, tolerance: frameTolerance)

    if isMaximized, let recordIndex {
      let restoreFrame = maximizedRecords.remove(at: recordIndex).restoreFrame
      animate(window, from: liveFrame, to: restoreFrame)
    } else if isMaximized {
      // Maximized by some other means and we have nothing to restore to —
      // fall back to a centered window at 60% of the visible frame.
      let size = CGSize(width: visibleFrame.width * 0.6, height: visibleFrame.height * 0.6)
      let origin = CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2)
      animate(window, from: liveFrame, to: CGRect(origin: origin, size: size))
    } else {
      if let recordIndex { maximizedRecords.remove(at: recordIndex) }
      maximizedRecords.append(MaximizedRecord(window: window, restoreFrame: current))
      if maximizedRecords.count > maxRecords {
        maximizedRecords.removeFirst(maximizedRecords.count - maxRecords)
      }
      animate(window, from: liveFrame, to: maximizeTarget)
    }
  }

  private func animate(_ window: AXUIElement, from start: CGRect, to target: CGRect) {
    animator?.cancel()

    guard !rectsApproximatelyEqual(start, target, tolerance: 1) else {
      WindowManager.setFrame(window: window, to: target)
      animator = nil
      return
    }

    let animator = WindowFrameAnimator(window: window, from: start, to: target, duration: animationDuration)
    self.animator = animator
    animator.start { [weak self] in
      if self?.animator === animator { self?.animator = nil }
    }
  }

  private func rectsApproximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
    abs(a.origin.x - b.origin.x) <= tolerance &&
    abs(a.origin.y - b.origin.y) <= tolerance &&
    abs(a.width - b.width) <= tolerance &&
    abs(a.height - b.height) <= tolerance
  }
}

/// Glides a window from one frame to another over `duration` with an ease-out curve.
/// AppKit has no API to animate another app's window, so this interpolates frame by
/// frame and pushes each step through `AXWindowWriter` (background serial queue,
/// latest-wins), which keeps the main thread from blocking on slow AX IPC.
final class WindowFrameAnimator {
  let window: AXUIElement
  let targetFrame: CGRect

  private let startFrame: CGRect
  private let duration: TimeInterval
  private var startedAt: TimeInterval = 0
  private var timer: Timer?
  private var onFinish: (() -> Void)?
  private var enhancedUIApp: AXUIElement?
  private var enhancedUIWasEnabled = false

  init(window: AXUIElement, from: CGRect, to: CGRect, duration: TimeInterval) {
    self.window = window
    self.startFrame = from
    self.targetFrame = to
    self.duration = duration
  }

  func start(onFinish: @escaping () -> Void) {
    self.onFinish = onFinish

    if let state = WindowManager.enhancedUIState(forAppOf: window) {
      enhancedUIApp = state.app
      enhancedUIWasEnabled = state.wasEnabled
      if state.wasEnabled { WindowManager.setEnhancedUI(false, forApp: state.app) }
    }

    AXWindowWriter.shared.beginGesture(window: window, origin: startFrame.origin, size: startFrame.size)
    startedAt = ProcessInfo.processInfo.systemUptime

    let timer = Timer(timeInterval: 1.0 / 90.0, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    tick()
  }

  /// Stops the glide immediately, leaving the window wherever it currently is.
  func cancel() {
    guard timer != nil else { return }
    timer?.invalidate()
    timer = nil
    AXWindowWriter.shared.endGesture()
    restoreEnhancedUI()
    onFinish = nil
  }

  private func tick() {
    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
    let t = duration > 0 ? min(1, max(0, elapsed / duration)) : 1
    let eased = CGFloat(1 - pow(1 - t, 3)) // ease-out cubic

    let frame = CGRect(
      x: startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * eased,
      y: startFrame.origin.y + (targetFrame.origin.y - startFrame.origin.y) * eased,
      width: startFrame.width + (targetFrame.width - startFrame.width) * eased,
      height: startFrame.height + (targetFrame.height - startFrame.height) * eased
    )
    AXWindowWriter.shared.requestResize(origin: frame.origin, size: frame.size)

    if t >= 1 { finish() }
  }

  private func finish() {
    guard timer != nil else { return }
    timer?.invalidate()
    timer = nil
    AXWindowWriter.shared.requestResize(origin: targetFrame.origin, size: targetFrame.size)
    AXWindowWriter.shared.endGesture()
    restoreEnhancedUI()
    let callback = onFinish
    onFinish = nil
    callback?()
  }

  private func restoreEnhancedUI() {
    if let app = enhancedUIApp, enhancedUIWasEnabled {
      WindowManager.setEnhancedUI(true, forApp: app)
    }
    enhancedUIApp = nil
    enhancedUIWasEnabled = false
  }
}

/// Detects a quick double-tap of a modifier-only Move/Resize shortcut and runs the
/// matching `WindowSnapAction`. A single press-hold (the normal drag gesture) never
/// looks like a double-tap: both taps must be short (< `maxTapDuration`) and close
/// together (< `maxGapBetweenTaps`), with no other key pressed, no mouse button
/// held, and the pointer barely moving between them.
final class DoubleTapActionManager {
  static let shared = DoubleTapActionManager()
  private init() {}

  private struct Config {
    let type: ShortcutType
    let flags: NSEvent.ModifierFlags
    let action: WindowSnapAction
  }

  private struct TapState {
    var firstPressAt: TimeInterval?
    var firstPressLocation: NSPoint?
    var firstReleaseAt: TimeInterval?
    var secondPressAt: TimeInterval?
  }

  private var monitors: [Any] = []
  private var configs: [Config] = []
  private var tapStates: [ShortcutType: TapState] = [:]
  private var lastMatched: [ShortcutType: Bool] = [:]

  /// Each tap must be shorter than this, and the gap between them smaller still —
  /// values a deliberate double-tap clears easily but a hold never does.
  private let maxTapDuration: TimeInterval = 0.30
  private let maxGapBetweenTaps: TimeInterval = 0.40
  /// If the pointer travels more than this between the first tap and the trigger,
  /// treat it as a move/resize drag (keyboard-only mode moves on mouse motion) and
  /// not a double-tap.
  private let maxPointerDrift: CGFloat = 12

  func updateSubscriptions() {
    teardown()

    guard PreferencesManager.loadBool(for: .doubleTapModifierActions) else { return }
    configs = Self.loadConfigs()
    guard !configs.isEmpty else { return }

    let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
    let handler: (NSEvent) -> Void = { [weak self] event in self?.handle(event) }

    if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
      monitors.append(monitor)
    }
    if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
      handler(event)
      return event
    }) {
      monitors.append(monitor)
    }
  }

  /// Full teardown + rebuild, for use after system events that can kill input hooks.
  func forceRebuild() {
    updateSubscriptions()
  }

  func cleanup() {
    teardown()
  }

  private func teardown() {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors.removeAll()
    tapStates.removeAll()
    lastMatched.removeAll()
    configs.removeAll()
  }

  private static func loadConfigs() -> [Config] {
    // By default the Resize modifier maximizes and the Move modifier minimizes;
    // the swap preference flips which modifier does which.
    let maximizeType: ShortcutType = PreferencesManager.loadBool(for: .doubleTapActionsSwapped) ? .move : .resize

    var result: [Config] = []
    for type in ShortcutType.allCases {
      guard let userShortcut = ShortcutsManager.shared.load(for: type),
            userShortcut.keyboardEnabled,
            let keyboardShortcut = userShortcut.keyboardShortcut,
            keyboardShortcut.isModifierOnly else { continue }

      let flags = keyboardShortcut.modifierFlags
      guard !flags.isEmpty else { continue }

      result.append(Config(type: type, flags: flags, action: type == maximizeType ? .toggleMaximize : .minimize))
    }
    return result
  }

  private func handle(_ event: NSEvent) {
    switch event.type {
    case .flagsChanged:
      handleFlagsChanged(event)
    case .keyDown, .leftMouseDown, .rightMouseDown:
      // A real keystroke or click means this isn't a bare double-tap.
      tapStates.removeAll()
    default:
      break
    }
  }

  private func handleFlagsChanged(_ event: NSEvent) {
    let now = event.timestamp
    let currentFlags = event.modifierFlags.swiftShiftShortcutFlags

    for config in configs {
      let matched = currentFlags == config.flags
      let previouslyMatched = lastMatched[config.type] ?? false
      lastMatched[config.type] = matched

      if matched && !previouslyMatched {
        handlePress(config, now: now)
      } else if !matched && previouslyMatched {
        handleRelease(config, now: now)
      }
    }
  }

  private func handlePress(_ config: Config, now: TimeInterval) {
    // A held mouse button means this modifier press is the start of a click-drag
    // gesture, not a tap. (We can't key off ShortcutsManager.hasActiveShortcut here:
    // holding the Move/Resize modifier arms that flag immediately, before any drag.)
    guard NSEvent.pressedMouseButtons == 0 else {
      tapStates[config.type] = nil
      return
    }

    let location = NSEvent.mouseLocation
    let state = tapStates[config.type]
    if let firstPress = state?.firstPressAt,
       let firstRelease = state?.firstReleaseAt,
       let firstLocation = state?.firstPressLocation,
       (firstRelease - firstPress) <= maxTapDuration,
       (now - firstRelease) <= maxGapBetweenTaps,
       distance(firstLocation, location) <= maxPointerDrift {
      var updated = state ?? TapState()
      updated.secondPressAt = now
      tapStates[config.type] = updated
    } else {
      tapStates[config.type] = TapState(firstPressAt: now, firstPressLocation: location, firstReleaseAt: nil, secondPressAt: nil)
    }
  }

  private func handleRelease(_ config: Config, now: TimeInterval) {
    guard var state = tapStates[config.type] else { return }

    if let secondPress = state.secondPressAt {
      tapStates[config.type] = nil
      guard (now - secondPress) <= maxTapDuration, NSEvent.pressedMouseButtons == 0 else { return }
      if let firstLocation = state.firstPressLocation, distance(firstLocation, NSEvent.mouseLocation) > maxPointerDrift { return }
      fire(config.action)
    } else if let firstPress = state.firstPressAt, state.firstReleaseAt == nil {
      if (now - firstPress) <= maxTapDuration {
        state.firstReleaseAt = now
        tapStates[config.type] = state
      } else {
        tapStates[config.type] = nil
      }
    } else {
      tapStates[config.type] = nil
    }
  }

  private func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
  }

  private func fire(_ action: WindowSnapAction) {
    DispatchQueue.main.async {
      WindowSnapActionRunner.shared.perform(action)
    }
  }
}
