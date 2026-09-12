import Cocoa
import Accessibility
import os.log
struct WindowBounds {
    let topLeft: NSPoint
    let topRight: NSPoint
    let bottomLeft: NSPoint
    let bottomRight: NSPoint
}
class WindowManager {
    @discardableResult
    static func move(window: AXUIElement, to point: NSPoint) -> AXError {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else {
            os_log("WindowManager: AXValueCreate failed for cgPoint", log: .default, type: .error)
            return .cannotComplete
        }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
    }
    @discardableResult
    static func resize(window: AXUIElement, to s: CGSize, from o: NSPoint, shouldMoveOrigin: Bool = true) -> Bool {
        let moveResult = shouldMoveOrigin ? move(window: window, to: o) : .success
        var sz = s
        guard let v = AXValueCreate(.cgSize, &sz) else {
            os_log("WindowManager: AXValueCreate failed for cgSize", log: .default, type: .error)
            return false
        }
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
        return moveResult == .success && sizeResult == .success
    }
    static func getSize(window: AXUIElement) -> NSSize? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &r) == .success,
              let r = r, CFGetTypeID(r) == AXValueGetTypeID() else {
            os_log("WindowManager: AXValueCopyAttributeValue failed for kAXSizeAttribute", log: .default, type: .error)
            return nil
        }
        var s: CGSize = .zero
        guard AXValueGetValue(r as! AXValue, .cgSize, &s) else {
            os_log("WindowManager: AXValueGetValue failed for cgSize", log: .default, type: .error)
            return nil
        }
        return NSSize(width: s.width, height: s.height)
    }
    static func getVisibleWindowRects(excluding excludedWindow: AXUIElement? = nil) -> [CGRect] {
        let excludedRect: CGRect? = {
            guard let window = excludedWindow, let position = getPosition(window: window), let size = getSize(window: window) else { return nil }
            return CGRect(origin: position, size: size)
        }()
        let windowInfo = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionOnScreenOnly], kCGNullWindowID) as? [[String: AnyObject]] ?? []
        return windowInfo.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != NSRunningApplication.current.processIdentifier,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 1, rect.height > 1 else { return nil }
            guard let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, !PreferencesManager.isAppIgnored(bundleId) else { return nil }
            if let excludedRect = excludedRect, rect.equalTo(excludedRect) { return nil }
            return rect
        }
    }
    static func getCurrentWindow() -> AXUIElement? {
        guard let ev = CGEvent(source: nil) else { return nil }
        return getCurrentWindow(at: ev.location)
    }
    static func getCurrentWindow(at mouseLocation: NSPoint) -> AXUIElement? {
        let currentPID = NSRunningApplication.current.processIdentifier
        let sys = AXUIElementCreateSystemWide(); var el: AXUIElement?
        if AXUIElementCopyElementAtPosition(sys, Float(mouseLocation.x), Float(mouseLocation.y), &el) == .success, let el = el, let w = getWindow(from: el) {
            var pid: pid_t = 0; AXUIElementGetPid(w, &pid)
            if pid != currentPID { return w }
        }
        return getTopWindowAtCursorUsingCGWindowList(mouseLocation: mouseLocation, excludingProcessID: currentPID)
    }
    private static func getTopWindowAtCursorUsingCGWindowList(mouseLocation: NSPoint, excludingProcessID: pid_t? = nil) -> AXUIElement? {
        let list = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionOnScreenOnly], kCGNullWindowID) as? [[String: AnyObject]] ?? []
        for e in list.sorted(by: { ($0[kCGWindowLayer as String] as? Int ?? 0) < ($1[kCGWindowLayer as String] as? Int ?? 0) }) {
            if let bDict = e[kCGWindowBounds as String] as? [String: CGFloat], let b = CGRect(dictionaryRepresentation: bDict as CFDictionary), b.contains(mouseLocation), let pid = e[kCGWindowOwnerPID as String] as? pid_t {
                if pid == excludingProcessID { continue }
                let app = AXUIElementCreateApplication(pid); var val: AnyObject?
                if let nsApp = getNSApplication(from: app), let bid = nsApp.bundleIdentifier, PreferencesManager.isAppIgnored(bid) { continue }
                if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &val) == .success, let wList = val as? [AXUIElement] {
                    for w in wList {
                        if let pos = getPosition(window: w), let size = getSize(window: w) {
                            let winRect = CGRect(origin: pos, size: size)
                            if winRect.contains(mouseLocation) { return w }
                        }
                    }
                    return wList.first
                }
            }
        }
        return nil
    }
    private static func getWindow(from element: AXUIElement) -> AXUIElement? {
        var r: AnyObject?; AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &r)
        if r as? String == kAXWindowRole { return element }
        var p: AnyObject?; AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &p)
        guard let p = p, CFGetTypeID(p as CFTypeRef) == AXUIElementGetTypeID() else {
            os_log("WindowManager: getWindow parent is not an AXUIElement", log: .default, type: .error)
            return nil
        }
        return getWindow(from: p as! AXUIElement)
    }
    static func focus(window: AXUIElement) { AXUIElementPerformAction(window, kAXRaiseAction as CFString); getNSApplication(from: window)?.activate() }
    static func getNSApplication(from element: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0; AXUIElementGetPid(element, &pid); return NSRunningApplication(processIdentifier: pid)
    }
    static func convertYCoordinateBecauseTheAreTwoFuckingCoordinateSystems(point: NSPoint) -> NSPoint {
        return NSPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
    }
    static func getPosition(window: AXUIElement) -> NSPoint? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &r) == .success,
              let r = r, CFGetTypeID(r) == AXValueGetTypeID() else {
            os_log("WindowManager: AXValueCopyAttributeValue failed for kAXPositionAttribute", log: .default, type: .error)
            return nil
        }
        var p: CGPoint = .zero
        guard AXValueGetValue(r as! AXValue, .cgPoint, &p) else {
            os_log("WindowManager: AXValueGetValue failed for cgPoint", log: .default, type: .error)
            return nil
        }
        return NSPoint(x: p.x, y: p.y)
    }
    static func getWindowBounds(windowLocation: NSPoint, windowSize: CGSize) -> WindowBounds {
        let fixed = convertYCoordinateBecauseTheAreTwoFuckingCoordinateSystems(point: windowLocation)
        return WindowBounds(topLeft: fixed, topRight: NSPoint(x: fixed.x + windowSize.width, y: fixed.y), bottomLeft: NSPoint(x: fixed.x, y: fixed.y - windowSize.height), bottomRight: NSPoint(x: fixed.x + windowSize.width, y: fixed.y - windowSize.height))
    }

    // MARK: - Maximize / minimize helpers

    /// Full frame (AX top-left coordinate space) of a window, or nil if either read fails.
    static func getFrame(window: AXUIElement) -> CGRect? {
        guard let position = getPosition(window: window), let size = getSize(window: window) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Move + resize a window to an exact frame. Writes twice because some apps clamp
    /// the position or size on the first pass (windows with size increments, or apps
    /// that toggle `AXEnhancedUserInterface` while an AX client is attached).
    @discardableResult
    static func setFrame(window: AXUIElement, to frame: CGRect) -> Bool {
        move(window: window, to: frame.origin)
        _ = resize(window: window, to: frame.size, from: frame.origin, shouldMoveOrigin: true)
        return resize(window: window, to: frame.size, from: frame.origin, shouldMoveOrigin: true)
    }

    @discardableResult
    static func setMinimized(window: AXUIElement, _ minimized: Bool) -> AXError {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, (minimized ? kCFBooleanTrue : kCFBooleanFalse))
    }

    /// Whether the AX reference still points at a live, responsive window.
    /// Bounds the messaging timeout so a hung (not terminated) owning app can't
    /// stall this for the full multi-second AX default — callers may probe
    /// several stored references in a row. Any error, not just
    /// `.invalidUIElement`, is treated as "not alive": a stored reference that
    /// can't be read is no more useful than a dead one.
    static func isAlive(window: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(window, 0.15)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &value)
        AXUIElementSetMessagingTimeout(window, 0) // restore the global default
        return result == .success
    }

    private static let enhancedUIAttribute = "AXEnhancedUserInterface" as CFString

    /// Reads `AXEnhancedUserInterface` on the app owning `window`. Chromium/Electron
    /// apps turn this on while an AX client is attached, which makes `kAXPosition` /
    /// `kAXSize` writes slow and non-live — turning it off for the duration of an
    /// animated resize keeps the motion smooth. Returns the app element plus whether
    /// the attribute was on, so the caller can restore it afterwards.
    static func enhancedUIState(forAppOf window: AXUIElement) -> (app: AXUIElement, wasEnabled: Bool)? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, enhancedUIAttribute, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return (app, false) }
        return (app, CFBooleanGetValue((value as! CFBoolean)))
    }

    static func setEnhancedUI(_ enabled: Bool, forApp app: AXUIElement) {
        AXUIElementSetAttributeValue(app, enhancedUIAttribute, enabled ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Convert an AppKit global rect (origin bottom-left of the primary screen, y up)
    /// to the AX global rect used by `kAXPosition`/`kAXSize` (origin top-left, y down).
    /// The transform is its own inverse.
    static func axRect(fromAppKit rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let primaryHeight = primary.frame.height
        return CGRect(x: rect.origin.x,
                      y: primaryHeight - rect.origin.y - rect.height,
                      width: rect.width,
                      height: rect.height)
    }

    /// Point inset to leave around a maximized window when macOS's own
    /// "Tiled windows have margins" setting is on (System Settings → Desktop & Dock).
    /// Returns 0 when that setting is off or the OS predates window tiling.
    static func tiledWindowMarginInset() -> CGFloat {
        guard #available(macOS 15.0, *) else { return 0 }
        let enabled = UserDefaults(suiteName: "com.apple.WindowManager")?
            .object(forKey: "EnableTiledWindowMargins") as? Bool ?? true
        return enabled ? tiledWindowMargin : 0
    }

    /// Gap macOS leaves between a tiled window and the screen edges (~8 pt).
    private static let tiledWindowMargin: CGFloat = 8

    /// Visible frame (menu bar and Dock excluded), in AX coordinates, of the screen
    /// that holds the largest part of `axRect`.
    static func screenAXVisibleFrame(containing axRect: CGRect) -> CGRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        var best: (screen: NSScreen, area: CGFloat)?
        for screen in screens {
            let frameAX = self.axRect(fromAppKit: screen.frame)
            let intersection = frameAX.intersection(axRect)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if best == nil || area > best!.area {
                best = (screen, area)
            }
        }

        guard let chosen = best?.screen else { return nil }
        return self.axRect(fromAppKit: chosen.visibleFrame)
    }

    /// The focused window of the frontmost app, used as a fallback when the cursor
    /// is not over a window. Skips our own app and ignored apps.
    static func getFocusedWindow() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()

        var appValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appValue) == .success,
              let appValue, CFGetTypeID(appValue) == AXUIElementGetTypeID() else { return nil }
        let app = appValue as! AXUIElement

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let window = windowValue as! AXUIElement

        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard pid != NSRunningApplication.current.processIdentifier else { return nil }
        if let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           PreferencesManager.isAppIgnored(bundleId) {
            return nil
        }
        return window
    }
}
