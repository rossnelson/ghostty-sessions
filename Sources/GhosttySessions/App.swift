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

extension Notification.Name {
  static let panelDragEnded = Notification.Name("panelDragEnded")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private let store = SessionStore()
  private var panel: SidebarPanel!
  private var statusItem: NSStatusItem!
  private var hotKeys: [HotKey] = []
  private var cancellable: Any?

  private let width: CGFloat = 310
  private let tracker = GhosttyWindowTracker()
  /// Ghostty's focused window, while the panel sits beside it.
  private var ghosttyWindow: GhosttyWindow?
  /// Hidden with ⌃⌥S or the menu, until shown the same way.
  private var hiddenByUser = false
  /// The frame last asked of Ghostty's window, so a window that settles a few
  /// points off is not moved again.
  private var requestedFrame: CGRect?
  /// While Ghostty's window moves, its events report in-between frames.
  private var moving = false
  private var moveTask: Task<Void, Never>?
  private var clickMonitors: [Any] = []
  private var trustTimer: Timer?
  private var sideItems: [NSMenuItem] = []

  private var edge: PanelEdge {
    get { PanelEdge(rawValue: UserDefaults.standard.string(forKey: "panelEdge") ?? "") ?? .right }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: "panelEdge")
      for item in sideItems { item.state = (item.tag == 0) == (newValue == .left) ? .on : .off }
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    buildPanel()
    buildStatusItem()
    registerHotKeys()
    setUpNotifications()

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
      MainActor.assumeIsolated { self?.chooseSideAfterDrag() }
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.tracker.update() }
    }

    tracker.onChange = { [weak self] window in
      guard let self, !self.moving else { return }
      self.layout(window)
    }
    // The panel follows Ghostty's window through the Accessibility API. Until
    // that permission is on, ask for it and check again every few seconds.
    if !GhosttyWindowTracker.isTrusted(prompt: true) {
      trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
        MainActor.assumeIsolated {
          guard GhosttyWindowTracker.isTrusted(prompt: false) else { return }
          timer.invalidate()
          self?.tracker.update()
        }
      }
    }
    tracker.start()
    keepPanelAboveGhostty()

    store.start()
  }

  private func buildPanel() {
    panel = SidebarPanel(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    // A normal window beside Ghostty's window, kept directly above it. Other
    // apps' windows cover both, as they would cover the terminal alone.
    panel.level = .normal
    panel.collectionBehavior = [.fullScreenNone, .ignoresCycle]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.becomesKeyOnlyIfNeeded = true

    let host = FirstClickHostingView(rootView: SidebarView(store: store))
    host.wantsLayer = true
    host.sizingOptions = []
    panel.contentView = host
  }

  // MARK: - Placement

  private func layout(_ window: GhosttyWindow?) {
    ghosttyWindow = window
    guard let window, !hiddenByUser else { return hide() }

    let screen = NSScreen.screens.first { $0.frame.intersects(window.frame) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? window.frame
    let layout = PanelLayout.compute(window: window.frame, screen: visible, edge: edge, width: width)
    // Correct the window once per move by the person; never chase its settling.
    if let moved = layout.windowFrame, !(requestedFrame?.isClose(to: window.frame, within: 12) ?? false) {
      return moveGhostty(to: moved)
    }

    let wasVisible = panel.isVisible
    panel.setFrame(layout.panel, display: true)
    panel.order(.above, relativeTo: window.windowNumber)
    guard !wasVisible else { return }
    panel.alphaValue = 0
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      panel.animator().alphaValue = 1
    }
  }

  private func hide() {
    panel.orderOut(nil)
  }

  /// Moves Ghostty's window out of the panel's place, ignoring its events
  /// until the move is done, then lays out once from where it ended up.
  private func moveGhostty(to frame: CGRect) {
    requestedFrame = frame
    moving = true
    moveTask?.cancel()
    moveTask = Task { [weak self] in
      guard let self else { return }
      await tracker.moveCurrentWindow(to: frame)
      guard !Task.isCancelled else { return }
      moving = false
      tracker.update()
    }
  }

  /// A click in Ghostty raises its window without an Accessibility event, and
  /// a click in the panel can raise the panel. Put the panel back directly
  /// above Ghostty's window after each click.
  private func keepPanelAboveGhostty() {
    let reorder = { [weak self] in
      guard let self, panel.isVisible, let number = ghosttyWindow?.windowNumber else { return }
      panel.order(.above, relativeTo: number)
    }
    if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { _ in
      MainActor.assumeIsolated { reorder() }
    }) { clickMonitors.append(global) }
    if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp], handler: { event in
      MainActor.assumeIsolated { reorder() }
      return event
    }) { clickMonitors.append(local) }
  }

  // After a drag, the panel goes to the side of Ghostty's window it was dropped on.
  private func chooseSideAfterDrag() {
    if let window = ghosttyWindow {
      edge = panel.frame.midX < window.frame.midX ? .left : .right
    }
    requestedFrame = nil
    layout(ghosttyWindow)
  }

  @objc private func chooseSide(_ sender: NSMenuItem) {
    edge = sender.tag == 0 ? .left : .right
    requestedFrame = nil
    layout(ghosttyWindow)
  }

  private func showPanel() {
    hiddenByUser = false
    requestedFrame = nil
    tracker.update()
  }

  private func hidePanel() {
    hiddenByUser = true
    hide()
  }

  @objc private func togglePanel() {
    hiddenByUser ? showPanel() : hidePanel()
  }

  @objc private func newSession() {
    if hiddenByUser { showPanel() }
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
    menu.addItem(item("New Session…", #selector(newSession), key: "n"))

    let sides = NSMenu()
    for (tag, title) in ["Left of Ghostty", "Right of Ghostty"].enumerated() {
      let entry = item(title, #selector(chooseSide(_:)), key: "")
      entry.tag = tag
      entry.state = (tag == 0) == (edge == .left) ? .on : .off
      sideItems.append(entry)
      sides.addItem(entry)
    }
    let side = NSMenuItem(title: "Panel Side", action: nil, keyEquivalent: "")
    side.submenu = sides
    menu.addItem(side)

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
