import AppKit

if CommandLine.arguments.contains("--dump") {
  dump()
  exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// Prints what the panel would show, for checking the matching without the UI.
func dump() {
  let processes = Claude.processes()
  let cache = TranscriptCache()
  let titles = Dictionary(processes.map { ($0.sessionID, cache.info(for: $0, root: NSHomeDirectory() + "/code")) }, uniquingKeysWith: { a, _ in a })

  for terminal in Ghostty.snapshot()?.terminals ?? [] {
    let title = String(terminal.title.dropFirst()).trimmingCharacters(in: .whitespaces)
    let process = processes.first { titles[$0.sessionID]?.title == title || $0.name == title }
    let info = process.flatMap { titles[$0.sessionID] }
    print("\(terminal.tabName.prefix(25).padding(toLength: 25, withPad: " ", startingAt: 0)) \(terminal.title.prefix(45).padding(toLength: 45, withPad: " ", startingAt: 0))  \(process?.status ?? "-")\t\(info?.repos.joined(separator: ", ") ?? "")\t\(info?.pendingTool ?? "")")
  }
}
