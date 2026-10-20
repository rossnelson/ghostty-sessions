import AppKit

struct GhosttyTerminal: Hashable {
  let id: String
  let title: String
  let cwd: String
  let tabName: String
}

struct GhosttySnapshot {
  let terminals: [GhosttyTerminal]
  let focusedID: String?
  let isFrontmost: Bool
}

enum Ghostty {
  static let bundleID = "com.mitchellh.ghostty"

  static var isRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
  }

  static var executableURL: URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
      .appendingPathComponent("Contents/MacOS/ghostty")
  }

  // `tab` is a class in Ghostty's dictionary, so the field separator is `character id 9`.
  static func snapshot() -> GhosttySnapshot? {
    guard isRunning else { return nil }

    let script = """
      tell application id "\(bundleID)"
        set sep to character id 9
        set fid to ""
        try
          set fid to id of focused terminal of selected tab of front window
        end try
        set out to (frontmost as text) & sep & fid & linefeed
        repeat with w in windows
          repeat with tb in tabs of w
            set tabName to name of tb
            repeat with t in terminals of tb
              set out to out & (id of t) & sep & (name of t) & sep & (working directory of t) & sep & tabName & linefeed
            end repeat
          end repeat
        end repeat
        return out
      end tell
      """

    guard let output = run(script) else { return nil }

    var lines = output.split(separator: "\n").map(String.init)
    guard !lines.isEmpty else { return nil }

    let header = lines.removeFirst().components(separatedBy: "\t")
    let terminals = lines.compactMap(parseTerminal)

    return GhosttySnapshot(
      terminals: terminals,
      focusedID: header.count > 1 && !header[1].isEmpty ? header[1] : nil,
      isFrontmost: header.first == "true"
    )
  }

  static func focus(terminalID: String) {
    run("""
      tell application id "\(bundleID)"
        focus (first terminal whose id is "\(escape(terminalID))")
        activate
      end tell
      """)
  }

  static func newTab(cwd: String, input: String, environment: [String]) -> String? {
    let env = environment.map { "\"\(escape($0))\"" }.joined(separator: ", ")
    let config = """
      {initial working directory:"\(escape(cwd))", initial input:"\(escape(input))" & linefeed, \
      environment variables:{\(env)}}
      """

    return run("""
      tell application id "\(bundleID)"
        activate
        set cfg to \(config)
        if (count of windows) is 0 then
          set w to new window with configuration cfg
          set t to selected tab of w
        else
          set t to new tab in front window with configuration cfg
        end if
        return id of focused terminal of t
      end tell
      """)
  }

  private static func parseTerminal(_ line: String) -> GhosttyTerminal? {
    let parts = line.components(separatedBy: "\t")
    guard parts.count >= 3 else { return nil }
    let tabName = parts.count > 3 ? parts[3] : parts[1]
    return GhosttyTerminal(id: parts[0], title: parts[1], cwd: parts[2], tabName: tabName)
  }

  private static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
  }

  @discardableResult
  private static func run(_ script: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-"]

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    do {
      try process.run()
    } catch {
      NSLog("GhosttySessions: osascript failed to start: \(error)")
      return nil
    }

    stdin.fileHandleForWriting.write(Data(script.utf8))
    stdin.fileHandleForWriting.closeFile()

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      NSLog("GhosttySessions: osascript error: \(String(decoding: errorData, as: UTF8.self))")
      return nil
    }

    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
  }
}
