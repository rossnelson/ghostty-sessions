import AppKit
import ApplicationServices

/// Ghostty's focused terminal window, as the panel beside it needs it.
struct GhosttyWindow: Equatable {
  /// Cocoa coordinates.
  var frame: CGRect
  /// The window server's number, for ordering the panel directly above it.
  var windowNumber: Int
}

/// Follows Ghostty's focused terminal window through the Accessibility API.
/// Reports `nil` when there is no such window on the current screen and Space.
/// Ghostty has no AppleScript for window bounds, so this is the only way in.
@MainActor
final class GhosttyWindowTracker {
  var onChange: (GhosttyWindow?) -> Void = { _ in }

  private var observer: AXObserver?
  private var appElement: AXUIElement?
  private var observedPID: pid_t?
  private var currentWindow: AXUIElement?

  private static let notifications = [
    kAXFocusedWindowChangedNotification,
    kAXMainWindowChangedNotification,
    kAXWindowMovedNotification,
    kAXWindowResizedNotification,
    kAXWindowMiniaturizedNotification,
    kAXWindowDeminiaturizedNotification,
    kAXWindowCreatedNotification,
    kAXUIElementDestroyedNotification,
  ]

  static func isTrusted(prompt: Bool) -> Bool {
    let key = "AXTrustedCheckOptionPrompt" as CFString
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
  }

  func start() {
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didActivateApplicationNotification,
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.activeSpaceDidChangeNotification,
      NSWorkspace.didHideApplicationNotification,
      NSWorkspace.didUnhideApplicationNotification,
    ] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.update() }
      }
    }
    update()
  }

  /// Re-reads Ghostty's state and reports it.
  func update() {
    guard let ghostty = NSRunningApplication
      .runningApplications(withBundleIdentifier: Ghostty.bundleID).first
    else {
      detach()
      return onChange(nil)
    }
    if observedPID != ghostty.processIdentifier { attach(pid: ghostty.processIdentifier) }

    guard !ghostty.isHidden, let appElement,
      let (window, axFrame, number) = attachableWindow(of: appElement, pid: ghostty.processIdentifier)
    else {
      currentWindow = nil
      return onChange(nil)
    }
    currentWindow = window
    onChange(GhosttyWindow(frame: Self.flip(axFrame), windowNumber: number))
  }

  // MARK: - Moving the window

  /// Moves and resizes the current window. `frame` is in Cocoa coordinates.
  ///
  /// A window can apply Accessibility frame changes one at a time, so change
  /// one value, wait until the window reports it, then change the next. Shrink
  /// before moving and move before growing, so the window never reaches past
  /// the screen (macOS would clamp it).
  func moveCurrentWindow(to frame: CGRect) async {
    guard let window = currentWindow else { return }
    let target = Self.flip(frame)
    for _ in 0..<3 {
      guard let current = frameInAXCoordinates(of: window) else { return }
      if current.isClose(to: target, within: 1) { return }
      if target.width < current.width - 1 || target.height < current.height - 1 {
        await setSize(target.size, of: window)
        await setPosition(target.origin, of: window)
      } else {
        await setPosition(target.origin, of: window)
        await setSize(target.size, of: window)
      }
    }
  }

  private func setPosition(_ point: CGPoint, of window: AXUIElement) async {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else { return }
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    await waitUntil(window) { abs($0.minX - point.x) <= 1 && abs($0.minY - point.y) <= 1 }
  }

  private func setSize(_ size: CGSize, of window: AXUIElement) async {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size) else { return }
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    await waitUntil(window) { abs($0.width - size.width) <= 1 && abs($0.height - size.height) <= 1 }
  }

  /// Polls the window's frame (AX coordinates) for up to 300 ms.
  private func waitUntil(_ window: AXUIElement, _ done: (CGRect) -> Bool) async {
    for _ in 0..<75 {
      if let frame = frameInAXCoordinates(of: window), done(frame) { return }
      try? await Task.sleep(for: .milliseconds(4))
    }
  }

  // MARK: - Observer

  private func attach(pid: pid_t) {
    detach()
    guard Self.isTrusted(prompt: false) else { return }
    var created: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      guard let refcon else { return }
      let tracker = Unmanaged<GhosttyWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
      MainActor.assumeIsolated { tracker.update() }
    }
    guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
    let element = AXUIElementCreateApplication(pid)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for name in Self.notifications {
      AXObserverAddNotification(created, element, name as CFString, refcon)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    observer = created
    appElement = element
    observedPID = pid
  }

  private func detach() {
    if let observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    observer = nil
    appElement = nil
    observedPID = nil
    currentWindow = nil
  }

  // MARK: - Reading windows

  /// The terminal window to sit beside: the focused window, else the main
  /// window, else the frontmost terminal window. A window counts only when it
  /// is a standard window that is on screen at the normal window level, so
  /// the quick terminal, minimized windows and full-screen windows do not.
  private func attachableWindow(of app: AXUIElement, pid: pid_t) -> (AXUIElement, CGRect, Int)? {
    let preferred = [kAXFocusedWindowAttribute, kAXMainWindowAttribute].compactMap {
      copy(app, $0) as AXUIElement?
    }
    let all: [AXUIElement] = copy(app, kAXWindowsAttribute) ?? []
    for window in preferred + all where isAttachable(window) {
      if let frame = frameInAXCoordinates(of: window),
        let number = Self.onScreenWindowNumber(pid: pid, axFrame: frame)
      {
        return (window, frame, number)
      }
    }
    return nil
  }

  private func isAttachable(_ window: AXUIElement) -> Bool {
    (copy(window, kAXSubroleAttribute) as String?) == (kAXStandardWindowSubrole as String)
      && !((copy(window, kAXMinimizedAttribute) as Bool?) ?? false)
      && !((copy(window, "AXFullScreen") as Bool?) ?? false)
  }

  /// Finds the window server's number for a window by owner and bounds. `nil`
  /// when it is not on screen, for example on another Space.
  private static func onScreenWindowNumber(pid: pid_t, axFrame: CGRect) -> Int? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
      return nil
    }
    for info in list {
      guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
        (info[kCGWindowLayer as String] as? Int) == 0,
        let bounds = info[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds),
        rect.isClose(to: axFrame, within: 2)
      else { continue }
      return info[kCGWindowNumber as String] as? Int
    }
    return nil
  }

  private func frameInAXCoordinates(of window: AXUIElement) -> CGRect? {
    guard let position: AXValue = copy(window, kAXPositionAttribute),
      let size: AXValue = copy(window, kAXSizeAttribute)
    else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent)
    else { return nil }
    return CGRect(origin: origin, size: extent)
  }

  private func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else { return nil }
    return value as? T
  }

  /// Converts between AX coordinates (origin at the top left of the primary
  /// display) and Cocoa coordinates (origin at its bottom left). The same
  /// formula goes both ways.
  private static func flip(_ rect: CGRect) -> CGRect {
    let height = NSScreen.screens.first?.frame.maxY ?? 0
    return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
  }
}

extension CGRect {
  func isClose(to other: CGRect, within tolerance: CGFloat) -> Bool {
    abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
      && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
  }
}
