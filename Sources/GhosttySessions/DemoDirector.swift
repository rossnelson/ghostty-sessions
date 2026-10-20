import AppKit
import SwiftUI

struct DemoScene: Decodable {
  let id: String
  let start: Double
  let duration: Double
}

private struct DemoTimeline: Decodable {
  let scenes: [DemoScene]
}

// Runs the scripted demo. Each scene starts at the time in timeline.json, which
// scripts/demo.sh builds from the length of each narration clip.
@MainActor
final class DemoDirector: DemoHandler {
  private let store: SessionStore
  private let model: DemoModel
  private let theme: Theme
  private let doneURL: URL?
  private var sessions: [Session] = []
  private var origin = Date()
  private var scenes: [String: DemoScene] = [:]

  private static let defaultTimeline = [
    DemoScene(id: "intro", start: 0, duration: 8),
    DemoScene(id: "states", start: 8, duration: 11),
    DemoScene(id: "permission", start: 19, duration: 11),
    DemoScene(id: "jump", start: 30, duration: 8),
    DemoScene(id: "hotkey", start: 38, duration: 7),
    DemoScene(id: "expand", start: 45, duration: 11),
    DemoScene(id: "new", start: 56, duration: 12),
    DemoScene(id: "outro", start: 68, duration: 9),
  ]

  init(store: SessionStore, model: DemoModel, timelineURL: URL?, doneURL: URL?) {
    self.store = store
    self.model = model
    self.theme = Theme.load()
    self.doneURL = doneURL

    let timeline = timelineURL
      .flatMap { try? Data(contentsOf: $0) }
      .flatMap { try? JSONDecoder().decode(DemoTimeline.self, from: $0) }?.scenes ?? Self.defaultTimeline
    scenes = Dictionary(uniqueKeysWithValues: timeline.map { ($0.id, $0) })
  }

  func prepare() {
    sessions = Self.initialSessions()
    model.tabs = sessions.map { DemoTab(id: $0.id, name: $0.title, working: $0.state == .working, lines: Self.lines[$0.id] ?? []) }
    model.selectedTab = "api"
    publish(focused: "api")
  }

  func run() async {
    origin = Date()
    withAnimation(.easeInOut(duration: 0.8)) { model.curtain = false }

    await intro()
    await states()
    await permission()
    await jump()
    await hotkey()
    await expand()
    await newSession()
    await outro()

    if let doneURL { try? Data().write(to: doneURL) }
    try? await Task.sleep(for: .seconds(1))
    NSApp.terminate(nil)
  }

  // MARK: Scenes

  private func intro() async {
    let scene = scenes["intro"]!
    withAnimation(.easeOut(duration: 0.6)) {
      model.titleCard = ("Ghostty Sessions", "Every Claude Code session, one glance away")
    }
    await at(scene, scene.duration * 0.5)
    withAnimation(.easeInOut(duration: 0.7)) { model.titleCard = nil }
    await at(scene, scene.duration * 0.62)
    withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { model.panelVisible = true }
    await end(scene)
  }

  private func states() async {
    let scene = scenes["states"]!
    await at(scene, scene.duration * 0.5)
    update("checkout") { $0.state = .yourTurn; $0.seen = false; $0.since = Date(); $0.attention += 1 }
    setTab("checkout", working: false, append: ["⏺ The test now waits for the cart to load. 50 runs, 0 failures."])
    await end(scene)
  }

  private func permission() async {
    let scene = scenes["permission"]!
    await at(scene, 0.8)
    update("release") {
      $0.state = .needsPermission
      $0.since = Date()
      $0.attention += 1
      $0.detail = "Bash: pnpm publish --tag next"
    }
    setTab("release", working: false, append: ["⏺ Bash(pnpm publish --tag next)", "  Do you want to proceed?  1. Yes  2. No"])
    await at(scene, 1.6)
    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
      model.banner = ("Claude needs permission", "Release", "Bash: pnpm publish --tag next")
    }
    await at(scene, scene.duration - 1.2)
    withAnimation(.easeIn(duration: 0.4)) { model.banner = nil }
    await end(scene)
  }

  private func jump() async {
    let scene = scenes["jump"]!
    withAnimation(.easeOut(duration: 0.3)) { model.cursorVisible = true }
    await at(scene, 0.3)
    await moveCursor(to: "row-checkout", duration: 1.0)
    await at(scene, 1.6)
    click()
    focus(session("checkout"))
    await end(scene)
  }

  private func hotkey() async {
    let scene = scenes["hotkey"]!
    withAnimation(.easeOut(duration: 0.3)) { model.cursorVisible = false }
    await at(scene, 0.6)
    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { model.keycaps = ["⌃", "⌥", "Space"] }
    await at(scene, 1.6)
    store.focusLongestWaiting()
    await at(scene, scene.duration - 1.0)
    withAnimation(.easeIn(duration: 0.3)) { model.keycaps = nil }
    await end(scene)
  }

  private func expand() async {
    let scene = scenes["expand"]!
    withAnimation(.easeOut(duration: 0.3)) { model.cursorVisible = true }
    await at(scene, 0.8)
    await moveCursor(to: "chips-release", duration: 1.0)
    await at(scene, 2.2)
    click()
    withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { store.toggleExpanded("release") }
    await end(scene)
  }

  private func newSession() async {
    let scene = scenes["new"]!
    withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { store.toggleExpanded("release") }
    await at(scene, 0.4)
    await moveCursor(to: "new", duration: 0.9)
    await at(scene, 1.5)
    click()
    store.composerOpen = true

    await at(scene, 2.4)
    for character in "Add dark mode to the settings page" {
      store.composerPrompt.append(character)
      try? await Task.sleep(for: .seconds(0.05))
    }

    await moveCursor(to: "start", duration: 0.7)
    try? await Task.sleep(for: .seconds(0.3))
    click()
    _ = start(prompt: store.composerPrompt)
    store.composerOpen = false
    store.composerPrompt = ""
    await end(scene)
  }

  private func outro() async {
    let scene = scenes["outro"]!
    withAnimation(.easeOut(duration: 0.4)) { model.cursorVisible = false }
    await at(scene, scene.duration * 0.35)
    withAnimation(.easeInOut(duration: 0.8)) {
      model.titleCard = ("Ghostty Sessions", "No fork. Just Ghostty's own scripting.")
    }
    await at(scene, scene.duration - 0.6)
    withAnimation(.easeInOut(duration: 0.6)) { model.curtain = true }
    await end(scene)
  }

  // MARK: DemoHandler

  func focus(_ session: Session) {
    withAnimation(.easeInOut(duration: 0.25)) { model.selectedTab = session.id }
    publish(focused: session.id)

    Task {
      try? await Task.sleep(for: .seconds(1.4))
      guard session.state == .yourTurn else { return }
      update(session.id) { $0.seen = true }
    }
  }

  func start(prompt: String) -> Bool {
    let id = "dark-mode"
    let session = Session(
      id: id, title: "Dark mode for settings", claudeTitle: nil, shellRunning: false, cwd: "~/code",
      repos: [chip("web-app/dark-mode", "feat/dark-mode")], state: .working, since: Date(),
      detail: nil, lastTool: nil, attention: 0, seen: false)
    sessions.append(session)
    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
      model.tabs.append(DemoTab(id: id, name: session.title, working: true, lines: ["> \(prompt)", "⏺ I'll find where the settings page reads its theme."]))
      model.selectedTab = id
    }
    publish(focused: id)
    return true
  }

  // MARK: Helpers

  private func at(_ scene: DemoScene, _ offset: Double) async {
    let delay = origin.addingTimeInterval(scene.start + offset).timeIntervalSinceNow
    guard delay > 0 else { return }
    try? await Task.sleep(for: .seconds(delay))
  }

  private func end(_ scene: DemoScene) async {
    await at(scene, scene.duration)
  }

  private func moveCursor(to key: String, duration: Double) async {
    guard let frame = model.frames[key] else { return }
    let target = CGPoint(x: frame.minX + min(frame.width * 0.35, 120), y: frame.midY)
    withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: duration)) { model.cursor = target }
    try? await Task.sleep(for: .seconds(duration))
  }

  private func click() {
    model.clicks += 1
  }

  private func session(_ id: String) -> Session {
    sessions.first { $0.id == id }!
  }

  private func update(_ id: String, _ change: (inout Session) -> Void) {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
    change(&sessions[index])
    publish(focused: store.focusedID)
  }

  private func setTab(_ id: String, working: Bool, append lines: [String]) {
    guard let index = model.tabs.firstIndex(where: { $0.id == id }) else { return }
    model.tabs[index].working = working
    model.tabs[index].lines += lines
  }

  private func publish(focused: String?) {
    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
      store.show(sessions: sessions, focusedID: focused, theme: theme)
    }
  }

  private func chip(_ label: String, _ branch: String) -> RepoChip {
    RepoChip(label: label, path: "~/code/" + label, branch: branch)
  }

  // MARK: Invented data

  private static func initialSessions() -> [Session] {
    func make(
      _ id: String, _ title: String, _ state: SessionState, minutesAgo: Double, seen: Bool = false,
      repos: [(String, String)], claudeTitle: String? = nil, lastTool: String? = nil
    ) -> Session {
      Session(
        id: id, title: title, claudeTitle: claudeTitle, shellRunning: false, cwd: "~/code",
        repos: repos.map { RepoChip(label: $0.0, path: "~/code/" + $0.0, branch: $0.1) },
        state: state, since: Date().addingTimeInterval(-minutesAgo * 60), detail: nil,
        lastTool: lastTool, attention: 0, seen: seen)
    }

    return [
      make("checkout", "Fix flaky checkout test", .working, minutesAgo: 3,
           repos: [("web-app/checkout-flake", "fix/checkout-flake")], lastTool: "Bash: pnpm test checkout --repeat 50"),
      make("api", "Rate limiter for the public API", .working, minutesAgo: 6,
           repos: [("api/rate-limit", "feat/rate-limit"), ("api/main", "main")], lastTool: "Edit: src/middleware/limit.ts"),
      make("docs", "Getting started guide", .yourTurn, minutesAgo: 4,
           repos: [("docs/getting-started", "docs/getting-started")], lastTool: "Write: content/start.md"),
      make("release", "Release", .working, minutesAgo: 9,
           repos: [("web-app/ts6", "chore/ts6"), ("design-system/ts6", "chore/ts6"), ("cli/main", "main")],
           claudeTitle: "Upgrade to TypeScript 6", lastTool: "Bash: pnpm -r build"),
      make("billing", "Billing webhook retries", .yourTurn, minutesAgo: 140, seen: true,
           repos: [("billing/webhook-retries", "feat/webhook-retries")]),
      make("ci", "Move CI to new runners", .yourTurn, minutesAgo: 1500, seen: true,
           repos: [("infra/ci-runners", "chore/ci-runners")]),
    ]
  }

  private static let lines: [String: [String]] = [
    "checkout": [
      "> The checkout test fails about one run in ten. Find out why.",
      "⏺ I'll run it 50 times and watch for the failure.",
      "  Bash(pnpm test checkout --repeat 50)",
      "  ⎿ 45 passed, 5 failed: cart total was 0",
      "⏺ The test reads the total before the cart loads.",
    ],
    "api": [
      "> Add a rate limiter to the public API, per API key.",
      "⏺ I'll use a token bucket in the middleware.",
      "  Read api/rate-limit/src/middleware/index.ts",
      "  Edit api/rate-limit/src/middleware/limit.ts (+58 −2)",
      "⏺ Now the tests for burst and steady traffic.",
    ],
    "docs": [
      "> Write a getting started guide for new users.",
      "⏺ Done. The guide is in content/start.md, with three steps and a short FAQ.",
      "  Do you want screenshots for each step?",
    ],
    "release": [
      "> Upgrade the web app and the design system to TypeScript 6.",
      "⏺ Both packages build. 3 type errors fixed in the design system.",
      "  Bash(pnpm -r build)",
      "  ⎿ 2 packages built",
    ],
    "billing": [
      "> Retry failed billing webhooks with backoff.",
      "⏺ Done. Retries use exponential backoff up to 6 tries.",
    ],
    "ci": [
      "> Move CI to the new runners.",
      "⏺ Done. All jobs run on the new runners and finish 40% faster.",
    ],
  ]
}
