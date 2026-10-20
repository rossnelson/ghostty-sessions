import AppKit
import SwiftUI

// `--demo <dir>` shows the stage, writes <dir>/stage-rect.txt for screencapture,
// waits for <dir>/go, runs the scenes from <dir>/timeline.json and then writes <dir>/done.
@MainActor
final class DemoAppDelegate: NSObject, NSApplicationDelegate {
  private let directory: URL
  private var window: NSWindow!
  private var director: DemoDirector!

  init(directory: URL) {
    self.directory = directory
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let store = SessionStore()
    let model = DemoModel()
    director = DemoDirector(
      store: store, model: model,
      timelineURL: directory.appendingPathComponent("timeline.json"),
      doneURL: directory.appendingPathComponent("done"))
    store.demo = director
    director.prepare()

    let screen = NSScreen.screens.first { $0.frame.width >= 1920 && $0.frame.height >= 1080 && $0.frame.width > $0.frame.height }
      ?? NSScreen.main!
    let frame = NSRect(
      x: screen.frame.midX - 960, y: screen.frame.midY - 540, width: 1920, height: 1080)

    window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.level = .screenSaver
    window.isOpaque = true
    window.backgroundColor = .black
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.contentView = NSHostingView(rootView: DemoStage(store: store, model: model))
    window.setFrame(frame, display: true)
    window.orderFrontRegardless()

    writeRect(frame)
    waitForGo()
  }

  // screencapture -R takes points from the top-left of the primary display.
  private func writeRect(_ frame: NSRect) {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let top = primaryHeight - frame.maxY
    let rect = "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
    try? rect.write(to: directory.appendingPathComponent("stage-rect.txt"), atomically: true, encoding: .utf8)
  }

  private func waitForGo() {
    let go = directory.appendingPathComponent("go")
    Task {
      while !FileManager.default.fileExists(atPath: go.path) {
        try? await Task.sleep(for: .milliseconds(100))
      }
      try? await Task.sleep(for: .seconds(1))
      await director.run()
    }
  }
}
