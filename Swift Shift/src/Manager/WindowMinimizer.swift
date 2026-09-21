import AppKit
import ApplicationServices

/// Drops the window under the cursor into the Dock.
///
/// A full-screen window has no minimize button, so there is nothing to minimize. Depending on
/// the preference, the gesture then shows the desktop instead — the full-screen window is left
/// full screen, untouched, in its own Space — or does nothing. The Dock is shared with Stage
/// Manager, so the same gesture works whether or not it is on.
///
/// Ported from the standalone Stash app (Liotou/Stash 1.2.0).
enum WindowMinimizer {

  enum Result {
    case done
    case noWindow
    /// The window can't be minimized (palette, system window…), or the gesture is disabled for it.
    case refused
  }

  @discardableResult
  static func minimizeWindowUnderCursor(actOnBackgroundWindows: Bool, showDesktopOnFullScreen: Bool) -> Result {
    guard PermissionsManager.hasAccessibilityPermission() else { return .refused }
    guard let window = windowUnderCursor() else { return .noWindow }

    var pid: pid_t = 0
    guard AXUIElementGetPid(window, &pid) == .success else { return .noWindow }

    // Never minimize ourselves, the Dock, or anything the user told SwiftShift to ignore.
    guard pid != ProcessInfo.processInfo.processIdentifier else { return .noWindow }
    let app = NSRunningApplication(processIdentifier: pid)
    if app?.bundleIdentifier == "com.apple.dock" { return .noWindow }
    if let bundleId = app?.bundleIdentifier, PreferencesManager.isAppIgnored(bundleId) { return .noWindow }

    if !actOnBackgroundWindows, app?.isActive != true { return .noWindow }

    if isFullScreen(window) {
      guard showDesktopOnFullScreen else { return .refused }
      showDesktop()
      return .done
    }
    return minimize(window)
  }

  // MARK: - Window under the cursor

  /// Cursor position in global Quartz coordinates (origin top-left), which is what the
  /// accessibility API expects.
  private static func cursorPosition() -> CGPoint {
    if let point = CGEvent(source: nil)?.location { return point }
    let cocoa = NSEvent.mouseLocation
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: cocoa.x, y: mainHeight - cocoa.y)
  }

  /// Strict hit test: the window that really contains the cursor, or nil. Unlike
  /// `WindowManager.getCurrentWindow(at:)` there is no fall-back to "some window of the app
  /// under the cursor", which is the wrong thing to minimize.
  private static func windowUnderCursor() -> AXUIElement? {
    let point = cursorPosition()
    var element: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
          let element, let window = WindowManager.getWindow(from: element) else { return nil }
    return isUserWindow(window) ? window : nil
  }

  /// Rules out the Finder's desktop, system windows and other surfaces that can't be minimized.
  private static func isUserWindow(_ window: AXUIElement) -> Bool {
    if let subrole = string(window, attribute: kAXSubroleAttribute) {
      let accepted: Set<String> = [
        kAXStandardWindowSubrole as String,
        kAXDialogSubrole as String,
        kAXFloatingWindowSubrole as String
      ]
      return accepted.contains(subrole)
    }
    // No subrole announced: accept the window if it exposes a minimize button.
    var button: CFTypeRef?
    return AXUIElementCopyAttributeValue(window, kAXMinimizeButtonAttribute as CFString, &button) == .success
  }

  // MARK: - Actions

  private static func isFullScreen(_ window: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success,
          let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
    return CFBooleanGetValue((value as! CFBoolean))
  }

  private static func minimize(_ window: AXUIElement) -> Result {
    var settable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable)
    guard settable.boolValue else { return .refused }
    return WindowManager.setMinimized(window: window, true) == .success ? .done : .refused
  }

  /// Switches to the desktop Space by activating the Finder — what a click on its Dock icon
  /// does, so macOS plays its usual transition and the full-screen window is never touched.
  ///
  /// Two other routes were tried in Stash and dropped: writing the Space through the private
  /// `CGSManagedDisplaySetCurrentSpace` updates the WindowServer's bookkeeping without
  /// redrawing (desktop windows end up painted over the full-screen one), and posting the
  /// Mission Control "move one Space left" shortcut has no effect when sent programmatically.
  private static func showDesktop() {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(
      at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
      configuration: configuration,
      completionHandler: nil
    )
  }

  private static func string(_ element: AXUIElement, attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
    return (value as! CFString) as String
  }
}
