import AppKit
import ApplicationServices

/// Keeps Ghostty's windows clear of the panel. While the panel shows, each
/// Ghostty window on the panel's display that reaches under the panel is
/// narrowed so that its edge stops just short of the panel. The window keeps
/// its other edge, its top and its height. Ghostty has no AppleScript for
/// window bounds, so this uses the Accessibility API.
@MainActor
final class GhosttyWindows {
  /// The space between a Ghostty window and the panel.
  static let gap: CGFloat = 6
  /// A window is not narrowed below this width.
  static let minimumWidth: CGFloat = 360

  /// The area to keep clear (Cocoa coordinates), the edge it is docked to,
  /// or `nil` while the panel is hidden.
  var reserved: () -> (frame: CGRect, edge: PanelEdge)? = { nil }

  private var observer: AXObserver?
  private var appElement: AXUIElement?
  private var observedPID: pid_t?
  private var animating = false
  private var pending: DispatchWorkItem?

  private static let notifications = [
    kAXWindowMovedNotification,
    kAXWindowResizedNotification,
    kAXWindowCreatedNotification,
    kAXWindowDeminiaturizedNotification,
  ]

  static func isTrusted(prompt: Bool) -> Bool {
    let key = "AXTrustedCheckOptionPrompt" as CFString
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
  }

  func start() {
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.activeSpaceDidChangeNotification,
    ] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleFit() }
      }
    }
    attachIfNeeded()
  }

  /// Fits the windows after the user stops moving or resizing one, so a drag
  /// is not fought while it happens.
  func scheduleFit(after delay: TimeInterval = 0.35) {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.fit() }
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  /// Narrows every Ghostty window that reaches under the panel.
  func fit(animated: Bool = true) {
    guard !animating, let (panel, edge) = reserved(), Self.isTrusted(prompt: false) else { return }
    attachIfNeeded()
    guard let appElement else { return }
    guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(panel) }) else { return }

    var moves: [(AXUIElement, CGRect, CGRect)] = []
    for window in windows(of: appElement) {
      guard let current = frame(of: window) else { continue }
      let cocoa = Self.flip(current)
      // Only windows on the panel's display.
      guard screen.frame.contains(CGPoint(x: cocoa.midX, y: cocoa.midY)) else { continue }

      var target = cocoa
      switch edge {
      case .right:
        let limit = panel.minX - Self.gap
        guard cocoa.maxX > limit, cocoa.minX < limit else { continue }
        target.size.width = limit - cocoa.minX
      case .left:
        let limit = panel.maxX + Self.gap
        guard cocoa.minX < limit, cocoa.maxX > limit else { continue }
        target.origin.x = limit
        target.size.width = cocoa.maxX - limit
      }
      guard target.width >= Self.minimumWidth else { continue }
      moves.append((window, current, Self.flip(target)))
    }
    guard !moves.isEmpty else { return }

    animating = true
    Task { @MainActor in
      await animate(moves, animated: animated)
      animating = false
    }
  }

  // MARK: - Moving windows

  /// Moves one edge of each window to its target over about a quarter of a
  /// second, easing out. Frames are in AX coordinates.
  private func animate(_ moves: [(AXUIElement, CGRect, CGRect)], animated: Bool) async {
    let duration = animated ? 0.26 : 0
    let began = Date()
    var progress = 0.0
    repeat {
      progress = duration > 0 ? min(Date().timeIntervalSince(began) / duration, 1) : 1
      let eased = 1 - pow(1 - progress, 3)
      for (window, start, target) in moves {
        let x = (start.minX + (target.minX - start.minX) * eased).rounded()
        let width = (start.width + (target.width - start.width) * eased).rounded()
        // Narrow first, then move, so the window never reaches past the screen.
        set(size: CGSize(width: width, height: start.height), of: window)
        set(position: CGPoint(x: x, y: start.minY), of: window)
      }
      if progress < 1 { try? await Task.sleep(for: .milliseconds(8)) }
    } while progress < 1
  }

  private func set(position: CGPoint, of window: AXUIElement) {
    var point = position
    guard let value = AXValueCreate(.cgPoint, &point) else { return }
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
  }

  private func set(size: CGSize, of window: AXUIElement) {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size) else { return }
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
  }

  // MARK: - Reading windows

  /// Ghostty's standard windows that are on screen: not minimized, not full screen.
  private func windows(of app: AXUIElement) -> [AXUIElement] {
    let all: [AXUIElement] = copy(app, kAXWindowsAttribute) ?? []
    return all.filter { window in
      (copy(window, kAXSubroleAttribute) as String?) == (kAXStandardWindowSubrole as String)
        && !((copy(window, kAXMinimizedAttribute) as Bool?) ?? false)
        && !((copy(window, "AXFullScreen") as Bool?) ?? false)
    }
  }

  private func frame(of window: AXUIElement) -> CGRect? {
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

  // MARK: - Observer

  private func attachIfNeeded() {
    let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Ghostty.bundleID)
      .first?.processIdentifier
    guard pid != observedPID else { return }
    detach()
    guard let pid, Self.isTrusted(prompt: false) else { return }

    var created: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      guard let refcon else { return }
      let windows = Unmanaged<GhosttyWindows>.fromOpaque(refcon).takeUnretainedValue()
      MainActor.assumeIsolated {
        guard !windows.animating else { return }
        windows.scheduleFit()
      }
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
  }
}
