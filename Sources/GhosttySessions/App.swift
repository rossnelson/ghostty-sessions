import AppKit
import Carbon
import SwiftUI
import UserNotifications

final class SidebarPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private let store = SessionStore()
  private var panel: SidebarPanel!
  private var statusItem: NSStatusItem!
  private var hotKeys: [HotKey] = []
  private var cancellable: Any?

  private let width: CGFloat = 310
  private let margin: CGFloat = 10

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

    let host = NSHostingView(rootView: SidebarView(store: store))
    host.wantsLayer = true
    panel.contentView = host
  }

  private func targetFrame(visible: Bool) -> NSRect {
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let x = visible ? screen.maxX - width - margin : screen.maxX + margin
    return NSRect(x: x, y: screen.minY + margin, width: width, height: screen.height - margin * 2)
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
    menu.addItem(item("Show or Hide Panel", #selector(togglePanel), key: ""))
    menu.addItem(item("New Session…", #selector(newSession), key: "n"))
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

  init(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
    HotKey.handlers[id] = handler
    HotKey.installHandler()

    let hotKeyID = EventHotKeyID(signature: OSType(0x4753_4553), id: id)
    RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
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
