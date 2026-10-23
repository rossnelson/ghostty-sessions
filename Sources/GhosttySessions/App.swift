import AppKit
import Carbon
import SwiftUI
import UserNotifications

// Without this, the first click on an inactive panel only makes it key and
// SwiftUI never sees it, so a row needs two clicks.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SidebarPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

enum PanelEdge: String {
  case left
  case right
}

extension Notification.Name {
  static let panelDragEnded = Notification.Name("panelDragEnded")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
  private let store = SessionStore()
  private var panel: SidebarPanel!
  private var statusItem: NSStatusItem!
  private var hotKeys: [HotKey] = []

  private static let ghosttyBundleID = "com.mitchellh.ghostty"
  private static let followKey = "followsGhosttyFocus"

  /// Show the panel while Ghostty is frontmost and hide it otherwise. The panel
  /// is only useful next to a terminal, so this is on unless it is turned off.
  private var followsGhostty: Bool {
    get {
      UserDefaults.standard.object(forKey: Self.followKey) as? Bool ?? true
    }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.followKey)
      followItem?.state = newValue ? .on : .off
      if newValue { syncPanelToFrontmostApp() }
    }
  }
  private var followItem: NSMenuItem?
  private var cancellable: Any?

  private let width: CGFloat = 310
  // How far past the screen edge the panel parks while hidden.
  private let slide: CGFloat = 10
  private let displayMenu = NSMenu()

  private var displayName: String? {
    get { UserDefaults.standard.string(forKey: "panelDisplay") }
    set { UserDefaults.standard.set(newValue, forKey: "panelDisplay") }
  }

  private var edge: PanelEdge {
    get { PanelEdge(rawValue: UserDefaults.standard.string(forKey: "panelEdge") ?? "") ?? .right }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "panelEdge") }
  }

  // The saved display, or the main display when the saved one is not connected.
  private var screen: NSScreen {
    NSScreen.screens.first { $0.localizedName == displayName } ?? NSScreen.main ?? NSScreen.screens[0]
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    buildPanel()
    buildStatusItem()
    registerHotKeys()
    setUpNotifications()
    observeAppFocus()

    store.onNeedsYou = { [weak self] session, looking in
      self?.updateBadge()
      guard !looking else { return }
      self?.notify(session)
    }
    cancellable = store.$sessions.sink { [weak self] _ in
      DispatchQueue.main.async { self?.updateBadge() }
    }

    NotificationCenter.default.addObserver(
      forName: .panelDragEnded, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.snapAfterDrag() }
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.settle() }
    }

    store.start()
    showPanel()
  }

  private func buildPanel() {
    panel = SidebarPanel(
      contentRect: targetFrame(visible: true),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false

    panel.becomesKeyOnlyIfNeeded = true

    let host = FirstClickHostingView(rootView: SidebarView(store: store))
    host.wantsLayer = true
    panel.contentView = host
  }

  private func targetFrame(visible: Bool) -> NSRect {
    let area = screen.visibleFrame
    // Visible, the panel is flush against its edge and full height between
    // the menu bar and the Dock. Hidden, it parks just past the edge.
    let x = switch (edge, visible) {
    case (.right, true): area.maxX - width
    case (.right, false): area.maxX + slide
    case (.left, true): area.minX
    case (.left, false): area.minX - width - slide
    }
    return NSRect(x: x, y: area.minY, width: width, height: area.height)
  }

  // After a drag, the panel docks to the nearer edge of the display it was dropped on.
  private func snapAfterDrag() {
    let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    guard let dropped = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return settle() }
    displayName = dropped.localizedName
    edge = center.x < dropped.frame.midX ? .left : .right
    settle()
  }

  private func settle() {
    guard panel.isVisible else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.35
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
      panel.animator().setFrame(targetFrame(visible: true), display: true)
    }
  }

  @objc private func moveToDisplay(_ sender: NSMenuItem) {
    displayName = sender.representedObject as? String
    showPanel()
  }

  @objc private func moveToEdge(_ sender: NSMenuItem) {
    edge = sender.tag == 0 ? .left : .right
    showPanel()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu === displayMenu else { return }
    menu.removeAllItems()

    for display in NSScreen.screens {
      let entry = item(display.localizedName, #selector(moveToDisplay(_:)), key: "")
      entry.representedObject = display.localizedName
      entry.state = display == screen ? .on : .off
      menu.addItem(entry)
    }

    menu.addItem(.separator())
    for (tag, title) in ["Left Edge", "Right Edge"].enumerated() {
      let entry = item(title, #selector(moveToEdge(_:)), key: "")
      entry.tag = tag
      entry.state = (tag == 0) == (edge == .left) ? .on : .off
      menu.addItem(entry)
    }
  }

  private func showPanel() {
    panel.setFrame(targetFrame(visible: false), display: false)
    panel.alphaValue = 0
    panel.orderFrontRegardless()

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.38
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
      panel.animator().setFrame(targetFrame(visible: true), display: true)
      panel.animator().alphaValue = 1
    }
  }

  private func hidePanel() {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().setFrame(targetFrame(visible: false), display: true)
      panel.animator().alphaValue = 0
    } completionHandler: {
      Task { @MainActor in self.panel.orderOut(nil) }
    }
  }

  private func observeAppFocus() {
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      Task { @MainActor in self?.appBecameActive(app?.bundleIdentifier) }
    }
    syncPanelToFrontmostApp()
  }

  private func syncPanelToFrontmostApp() {
    appBecameActive(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
  }

  private func appBecameActive(_ bundleID: String?) {
    guard followsGhostty else { return }
    // Our own activation is not a reason to hide: clicking the panel, the menu
    // bar item, or the new-session form makes this app frontmost, and hiding
    // there would close the panel the moment it is used.
    guard bundleID != Bundle.main.bundleIdentifier else { return }

    let visible = panel.isVisible && panel.alphaValue > 0
    if bundleID == Self.ghosttyBundleID {
      if !visible { showPanel() }
    } else if visible {
      hidePanel()
    }
  }

  @objc private func toggleFollowsGhostty() {
    followsGhostty.toggle()
  }

  @objc private func togglePanel() {
    panel.isVisible && panel.alphaValue > 0 ? hidePanel() : showPanel()
  }

  @objc private func newSession() {
    if !panel.isVisible { showPanel() }
    NSApp.activate()
    panel.makeKey()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  private func buildStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "Sessions")
    statusItem.button?.imagePosition = .imageLeading

    let menu = NSMenu()
    let toggle = item("Show or Hide Panel", #selector(togglePanel), key: "s")
    toggle.keyEquivalentModifierMask = [.control, .option]
    if HotKey.failed.contains(2) {
      toggle.keyEquivalent = ""
      toggle.toolTip = "⌃⌥S is taken by another app, so the global shortcut is off."
    }
    menu.addItem(toggle)
    let follow = item("Show With Ghostty", #selector(toggleFollowsGhostty), key: "")
    follow.state = followsGhostty ? .on : .off
    follow.toolTip = "Show the panel while Ghostty is frontmost, and hide it otherwise."
    followItem = follow
    menu.addItem(follow)
    menu.addItem(item("New Session…", #selector(newSession), key: "n"))
    let displays = NSMenuItem(title: "Move to Display", action: nil, keyEquivalent: "")
    displayMenu.delegate = self
    displays.submenu = displayMenu
    menu.addItem(displays)
    menu.addItem(.separator())
    menu.addItem(item("Quit Ghostty Sessions", #selector(quit), key: "q"))
    statusItem.menu = menu
  }

  private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    return item
  }

  // The menu bar draws template images in one color and ignores contentTintColor,
  // so a waiting state uses a non-template image and a colored title.
  private func updateBadge() {
    guard let button = statusItem.button else { return }
    let symbol = "sparkles.rectangle.stack"
    let waiting = store.waiting
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sessions")

    guard !waiting.isEmpty else {
      image?.isTemplate = true
      button.image = image
      button.attributedTitle = NSAttributedString(string: "")
      return
    }

    let permission = waiting.contains { $0.state == .needsPermission }
    let color = NSColor(permission ? store.theme.permission : store.theme.waiting)
    let tinted = image?.withSymbolConfiguration(.init(paletteColors: [color]))
    tinted?.isTemplate = false
    button.image = tinted
    button.attributedTitle = NSAttributedString(
      string: " \(waiting.count)",
      attributes: [
        .foregroundColor: color,
        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
      ]
    )
  }

  private func registerHotKeys() {
    let modifiers = UInt32(controlKey | optionKey)
    hotKeys = [
      HotKey(id: 1, keyCode: UInt32(kVK_Space), modifiers: modifiers) { [weak self] in
        Task { @MainActor in self?.store.focusLongestWaiting() }
      },
      HotKey(id: 2, keyCode: UInt32(kVK_ANSI_S), modifiers: modifiers) { [weak self] in
        Task { @MainActor in self?.togglePanel() }
      },
    ]
  }

  private func setUpNotifications() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  private func notify(_ session: Session) {
    let content = UNMutableNotificationContent()
    content.title = session.state == .needsPermission ? "Claude needs permission" : "Claude is waiting"
    content.subtitle = session.repos.first.map { $0.branch ?? $0.label } ?? ""
    content.body = session.detail ?? session.title
    content.sound = .default
    content.userInfo = ["terminal": session.id]

    let request = UNNotificationRequest(identifier: session.id, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = response.notification.request.content.userInfo["terminal"] as? String
    if let id {
      DispatchQueue.global().async {
        Ghostty.focus(terminalID: id)
        DispatchQueue.main.async { Ghostty.bringToFront() }
      }
    }
    completionHandler()
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}

final class HotKey {
  private var ref: EventHotKeyRef?
  nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
  nonisolated(unsafe) private static var installed = false
  /// Ids whose RegisterEventHotKey call was refused, so the menu can show it.
  nonisolated(unsafe) static var failed: Set<UInt32> = []

  init(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
    HotKey.handlers[id] = handler
    HotKey.installHandler()

    let hotKeyID = EventHotKeyID(signature: OSType(0x4753_4553), id: id)
    // RegisterEventHotKey fails when another app already owns the combination.
    // Swallowing the status leaves a hotkey that silently never fires, which
    // reads as "the app has no hotkey" rather than "something else took it".
    let status = RegisterEventHotKey(
      keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    if status != noErr {
      HotKey.failed.insert(id)
      FileHandle.standardError.write(
        "hotkey \(id) not registered (OSStatus \(status)) — another app likely owns it\n"
          .data(using: .utf8)!)
    }
  }

  deinit {
    if let ref { UnregisterEventHotKey(ref) }
  }

  private static func installHandler() {
    guard !installed else { return }
    installed = true

    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
      var hotKeyID = EventHotKeyID()
      GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
      HotKey.handlers[hotKeyID.id]?()
      return noErr
    }, 1, &spec, nil, nil)
  }
}
