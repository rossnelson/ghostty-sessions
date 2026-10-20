import Foundation
import SwiftUI

enum SessionState: Int, Comparable {
  case needsPermission
  case yourTurn
  case working

  var needsYou: Bool { self != .working }

  static func < (lhs: SessionState, rhs: SessionState) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct RepoChip: Hashable {
  let label: String
  let path: String
  let branch: String?
}

struct Session: Identifiable, Equatable {
  let id: String
  var title: String
  var claudeTitle: String?
  var shellRunning: Bool
  var cwd: String
  var repos: [RepoChip]
  var state: SessionState
  var since: Date
  var detail: String?
  var lastTool: String?
  var attention: Int
  var seen: Bool

  var needsYou: Bool { state == .needsPermission || (state == .yourTurn && !seen) }
  var idle: Bool { state == .yourTurn && seen }
}

@MainActor
final class SessionStore: ObservableObject {
  @Published private(set) var sessions: [Session] = []
  @Published private(set) var focusedID: String?
  @Published private(set) var ghosttyRunning = true
  @Published private(set) var theme = Theme()
  @Published private(set) var folders: [String] = []

  var onNeedsYou: ((Session, Bool) -> Void)?

  private var history: [String: (state: SessionState, since: Date, attention: Int, seen: Bool)] = [:]
  private var launched: [String: String] = [:]
  private let reader = TranscriptCache()
  private let queue = DispatchQueue(label: "ghostty-sessions.poll", qos: .userInitiated)
  private var polling = false
  private var timer: Timer?

  // Claude Code puts its state in the title: ✳ when idle, a turning half circle while it works.
  private static let idleGlyphs: Set<Character> = ["✳"]
  private static let workingGlyphs: Set<Character> = ["◐", "◓", "◑", "◒", "·", "✢", "✶", "✻", "✽"]
  private static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("code").path

  init() {
    let saved = UserDefaults.standard.stringArray(forKey: "folders") ?? []
    folders = saved.isEmpty ? [Self.defaultFolder] : saved
  }

  var waiting: [Session] { sessions.filter(\.needsYou) }
  var working: [Session] { sessions.filter { $0.state == .working } }
  var idle: [Session] { sessions.filter(\.idle) }

  func start() {
    queue.async {
      let theme = Theme.load()
      DispatchQueue.main.async { self.theme = theme }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.poll() }
    }
    poll()
  }

  func focus(_ session: Session) {
    queue.async { Ghostty.focus(terminalID: session.id) }
  }

  func focusLongestWaiting() {
    guard let session = waiting.min(by: { $0.since < $1.since }) else { return }
    focus(session)
  }

  func addFolder(_ path: String) {
    folders = [path] + folders.filter { $0 != path }
    folders = Array(folders.prefix(8))
    UserDefaults.standard.set(folders, forKey: "folders")
  }

  func startSession(in folder: String, name: String, prompt: String) async -> Bool {
    addFolder(folder)

    let sessionID = UUID().uuidString.lowercased()
    var command = "claude --session-id \(sessionID)"
    if !name.isEmpty { command += " -n \(Self.quote(name))" }
    if !prompt.isEmpty { command += " \(Self.quote(prompt))" }

    let terminalID = await Task.detached {
      Ghostty.newTab(cwd: folder, input: command, environment: [])
    }.value

    guard let terminalID else { return false }
    launched[sessionID] = terminalID
    poll()
    return true
  }

  private static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func poll() {
    guard !polling else { return }
    polling = true
    let reader = self.reader
    let folders = self.folders

    queue.async {
      let snapshot = Ghostty.snapshot()
      let processes = Claude.processes()
      let transcripts = Dictionary(
        processes.map { ($0.sessionID, reader.info(for: $0, root: Self.root(for: $0.cwd, folders: folders))) },
        uniquingKeysWith: { first, _ in first }
      )

      DispatchQueue.main.async {
        self.apply(snapshot: snapshot, processes: processes, transcripts: transcripts)
        self.polling = false
      }
    }
  }

  private func apply(snapshot: GhosttySnapshot?, processes: [ClaudeProcess], transcripts: [String: TranscriptInfo]) {
    ghosttyRunning = snapshot != nil
    guard let snapshot else {
      sessions = []
      return
    }

    let now = Date()
    var unmatched = processes

    let next: [Session] = snapshot.terminals.compactMap { terminal in
      guard let glyph = terminal.title.first,
        Self.idleGlyphs.contains(glyph) || Self.workingGlyphs.contains(glyph)
      else { return nil }

      let title = String(terminal.title.dropFirst()).trimmingCharacters(in: .whitespaces)
      let process = match(terminal: terminal, title: title, in: &unmatched, transcripts: transcripts)
      let info = process.flatMap { transcripts[$0.sessionID] }

      let state = state(for: process, glyph: glyph)
      let previous = history[terminal.id]
      let changed = previous?.state != state
      let becameWaiting = previous != nil && changed && state.needsYou && previous?.state == .working
      let attention = (previous?.attention ?? 0) + (becameWaiting ? 1 : 0)
      let since = process?.statusSince ?? (changed ? now : (previous?.since ?? now))
      let looking = snapshot.isFrontmost && snapshot.focusedID == terminal.id
      let seen = looking || (changed ? Self.startsSeen(previous: previous == nil, since: since, now: now) : previous?.seen ?? false)
      history[terminal.id] = (state, since, attention, seen)

      let root = Self.root(for: process?.cwd ?? terminal.cwd, folders: folders)
      let claudeTitle = title.isEmpty ? (info?.title ?? "Claude") : title
      let customName = terminal.tabName != terminal.title && !terminal.tabName.isEmpty
      let session = Session(
        id: terminal.id,
        title: customName ? terminal.tabName : claudeTitle,
        claudeTitle: customName ? claudeTitle : nil,
        shellRunning: process?.status == "shell",
        cwd: terminal.cwd,
        repos: chips(for: info?.repos ?? [], root: root, cwd: process?.cwd ?? terminal.cwd),
        state: state,
        since: since,
        detail: state == .needsPermission ? (info?.pendingTool ?? "Waiting for permission") : nil,
        lastTool: info?.pendingTool,
        attention: attention,
        seen: seen
      )

      if becameWaiting {
        onNeedsYou?(session, looking)
      }

      return session
    }

    let live = Set(snapshot.terminals.map(\.id))
    history = history.filter { live.contains($0.key) }
    launched = launched.filter { live.contains($0.value) }

    let sorted = next.sorted { (Self.rank($0), $0.since) < (Self.rank($1), $1.since) }
    if sorted != sessions { sessions = sorted }
    if focusedID != snapshot.focusedID { focusedID = snapshot.focusedID }
  }

  // A tab launched here is matched by its session ID. Other tabs are matched by
  // title, because Claude Code sets the tab title to the transcript's ai-title.
  private func match(
    terminal: GhosttyTerminal, title: String, in processes: inout [ClaudeProcess], transcripts: [String: TranscriptInfo]
  ) -> ClaudeProcess? {
    let launchedID = launched.first { $0.value == terminal.id }?.key
    let index = processes.firstIndex { process in
      if process.sessionID == launchedID { return true }
      if transcripts[process.sessionID]?.title == title { return true }
      return process.name == title
    }
    guard let index else { return nil }
    return processes.remove(at: index)
  }

  private static func rank(_ session: Session) -> Int {
    if session.needsYou { return 0 }
    return session.state == .working ? 1 : 2
  }

  // When the app starts it cannot know what you already looked at, so a session
  // that finished more than an hour ago counts as seen.
  private static func startsSeen(previous isFirstPoll: Bool, since: Date, now: Date) -> Bool {
    isFirstPoll && now.timeIntervalSince(since) > 3600
  }

  // A session that starts inside a repo has paths relative to it, so the repo itself is the chip.
  private func chips(for repos: [String], root: String, cwd: String) -> [RepoChip] {
    guard repos.isEmpty else {
      return repos.map { RepoChip(label: $0, path: root + "/" + $0, branch: Git.branch(at: root + "/" + $0)) }
    }
    guard let branch = Git.branch(at: cwd) else { return [] }
    return [RepoChip(label: (cwd as NSString).lastPathComponent, path: cwd, branch: branch)]
  }

  // Paths in a transcript are read relative to the saved folder that holds the
  // session, such as ~/code, so a session that moves between repos shows all of them.
  nonisolated static func root(for cwd: String, folders: [String]) -> String {
    folders.first { cwd == $0 || cwd.hasPrefix($0 + "/") } ?? cwd
  }

  private func state(for process: ClaudeProcess?, glyph: Character) -> SessionState {
    switch process?.status {
    case "waiting": return .needsPermission
    case "idle", "shell": return .yourTurn
    case "busy": return .working
    default: return Self.idleGlyphs.contains(glyph) ? .yourTurn : .working
    }
  }
}

// Transcripts grow to megabytes, so each one is read again only after it changes.
final class TranscriptCache: @unchecked Sendable {
  private var entries: [String: (modified: Date, size: Int, info: TranscriptInfo)] = [:]
  private let lock = NSLock()

  func info(for process: ClaudeProcess, root: String) -> TranscriptInfo {
    guard let url = Claude.transcriptURL(for: process),
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    else { return TranscriptInfo() }

    let modified = attributes[.modificationDate] as? Date ?? .distantPast
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0

    lock.lock()
    let cached = entries[process.sessionID]
    lock.unlock()
    if let cached, cached.modified == modified, cached.size == size { return cached.info }

    let info = Claude.readTranscript(url, root: root)
    lock.lock()
    entries[process.sessionID] = (modified, size, info)
    lock.unlock()
    return info
  }
}
