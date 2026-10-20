import Foundation

// Claude Code writes one file per running process to ~/.claude/sessions/<pid>.json.
// The format is internal to Claude Code, so every field is optional here.
struct ClaudeProcess {
  let pid: Int32
  let sessionID: String
  let status: String
  let name: String?
  let cwd: String
  let statusSince: Date?
}

struct TranscriptInfo {
  var title: String?
  var repos: [String] = []
  var pendingTool: String?
}

enum Claude {
  static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")

  static func processes() -> [ClaudeProcess] {
    let dir = home.appendingPathComponent("sessions")
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap(readProcess).filter(isAlive)
  }

  static func transcriptURL(for process: ClaudeProcess) -> URL? {
    let projects = home.appendingPathComponent("projects")
    let encoded = process.cwd.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    let direct = projects.appendingPathComponent(encoded).appendingPathComponent("\(process.sessionID).jsonl")
    if FileManager.default.fileExists(atPath: direct.path) { return direct }

    let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
    return dirs.map { $0.appendingPathComponent("\(process.sessionID).jsonl") }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  static func readTranscript(_ url: URL, root: String) -> TranscriptInfo {
    let lines = tail(of: url, bytes: 384 * 1024)
    var info = TranscriptInfo()
    info.title = lastTitle(in: lines)
    info.repos = repos(in: lines, root: root)
    info.pendingTool = lastToolUse(in: lines)
    return info
  }

  private static func readProcess(_ url: URL) -> ClaudeProcess? {
    guard let data = try? Data(contentsOf: url),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let pid = json["pid"] as? Int,
      let sessionID = json["sessionId"] as? String
    else { return nil }

    let since = (json["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
    return ClaudeProcess(
      pid: Int32(pid),
      sessionID: sessionID,
      status: json["status"] as? String ?? "",
      name: json["name"] as? String,
      cwd: json["cwd"] as? String ?? "",
      statusSince: since
    )
  }

  private static func isAlive(_ process: ClaudeProcess) -> Bool {
    kill(process.pid, 0) == 0
  }

  private static func tail(of url: URL, bytes: Int) -> [Substring] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }

    let size = (try? handle.seekToEnd()) ?? 0
    let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
    try? handle.seek(toOffset: start)
    let data = (try? handle.readToEnd()) ?? Data()
    var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    return lines
  }

  private static func lastTitle(in lines: [Substring]) -> String? {
    for line in lines.reversed() where line.contains("\"ai-title\"") {
      guard let json = decode(line), let title = json["aiTitle"] as? String else { continue }
      return title
    }
    return nil
  }

  // Sessions start in a shared root such as ~/code and move between repos, so the
  // row shows the repos the transcript touched most recently.
  private static func repos(in lines: [Substring], root: String) -> [String] {
    let roots = [root, (root as NSString).abbreviatingWithTildeInPath].map(NSRegularExpression.escapedPattern(for:))
    let pattern = "(?:" + roots.joined(separator: "|") + ")/([A-Za-z0-9._-]+)(?:/([A-Za-z0-9._-]+))?"
    guard !root.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

    var seen: [String] = []
    for line in lines.reversed() {
      let text = String(line)
      let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
      for match in matches.reversed() {
        guard let repo = repoLabel(match: match, in: text, root: root), !seen.contains(repo) else { continue }
        seen.append(repo)
        if seen.count == 6 { return seen }
      }
    }
    return seen
  }

  private static func repoLabel(match: NSTextCheckingResult, in text: String, root: String) -> String? {
    guard let first = Range(match.range(at: 1), in: text).map({ String(text[$0]) }) else { return nil }
    let second = Range(match.range(at: 2), in: text).map { String(text[$0]) }

    if let second, isRepo(root + "/" + first + "/" + second) { return first + "/" + second }
    if isRepo(root + "/" + first) { return first }
    return nil
  }

  private static func isRepo(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path + "/.git")
  }

  private static func lastToolUse(in lines: [Substring]) -> String? {
    for line in lines.reversed() where line.contains("\"tool_use\"") {
      guard let json = decode(line),
        let message = json["message"] as? [String: Any],
        let content = message["content"] as? [[String: Any]],
        let tool = content.last(where: { $0["type"] as? String == "tool_use" })
      else { continue }
      return describe(tool)
    }
    return nil
  }

  private static func describe(_ tool: [String: Any]) -> String {
    let name = tool["name"] as? String ?? "Tool"
    let input = tool["input"] as? [String: Any] ?? [:]
    let detail = ["command", "file_path", "url", "pattern", "description"]
      .lazy.compactMap { input[$0] as? String }.first
    guard let detail else { return name }
    let flat = detail.replacingOccurrences(of: "\n", with: " ")
    return "\(name): \(flat.prefix(90))"
  }

  private static func decode(_ line: Substring) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
  }
}
