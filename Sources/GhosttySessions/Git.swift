import Foundation

enum Git {
  // Reads HEAD from disk so the poll loop does not spawn a git process per session.
  static func branch(at cwd: String) -> String? {
    guard let gitDir = gitDir(from: cwd),
      let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8)
    else { return nil }

    let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "ref: refs/heads/"
    guard trimmed.hasPrefix(prefix) else { return String(trimmed.prefix(7)) }
    return String(trimmed.dropFirst(prefix.count))
  }

  private static func gitDir(from cwd: String) -> String? {
    var url = URL(fileURLWithPath: cwd)

    while url.path != "/" {
      let dotGit = url.appendingPathComponent(".git").path
      var isDirectory: ObjCBool = false

      if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
        guard !isDirectory.boolValue else { return dotGit }
        return worktreeGitDir(file: dotGit, base: url.path)
      }

      url.deleteLastPathComponent()
    }

    return nil
  }

  private static func worktreeGitDir(file: String, base: String) -> String? {
    guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
    let path = contents.replacingOccurrences(of: "gitdir:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.hasPrefix("/") else { return path }
    return (base as NSString).appendingPathComponent(path)
  }
}
