import SwiftUI

struct Theme {
  var background = Color(hex: "#24283b")
  var foreground = Color(hex: "#c0caf5")
  var palette: [Int: Color] = [
    1: Color(hex: "#f7768e"),
    2: Color(hex: "#9ece6a"),
    3: Color(hex: "#e0af68"),
    4: Color(hex: "#7aa2f7"),
    5: Color(hex: "#bb9af7"),
    6: Color(hex: "#7dcfff"),
    8: Color(hex: "#414868"),
  ]
  var fontFamily: String?

  var working: Color { palette[4] ?? .blue }
  var waiting: Color { palette[3] ?? .yellow }
  var permission: Color { palette[1] ?? .red }
  var accent: Color { palette[5] ?? .purple }
  var success: Color { palette[2] ?? .green }
  var dim: Color { foreground.opacity(0.55) }

  func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    guard let fontFamily else { return .system(size: size, weight: weight, design: .monospaced) }
    return .custom(fontFamily, size: size).weight(weight)
  }

  // Reads the user's resolved Ghostty config so the panel matches the terminal.
  static func load() -> Theme {
    var theme = Theme()
    guard let url = Ghostty.executableURL else { return theme }

    let process = Process()
    process.executableURL = url
    process.arguments = ["+show-config"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    guard (try? process.run()) != nil else { return theme }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()

    for line in output.split(separator: "\n") {
      let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2 else { continue }
      apply(key: parts[0], value: parts[1], to: &theme)
    }

    return theme
  }

  private static func apply(key: String, value: String, to theme: inout Theme) {
    if key == "background" { theme.background = Color(hex: value) }
    if key == "foreground" { theme.foreground = Color(hex: value) }
    if key == "font-family", theme.fontFamily == nil, !value.isEmpty {
      theme.fontFamily = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    guard key == "palette" else { return }

    let entry = value.split(separator: "=", maxSplits: 1)
    guard entry.count == 2, let index = Int(entry[0]) else { return }
    theme.palette[index] = Color(hex: String(entry[1]))
  }
}

extension Color {
  init(hex: String) {
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#\" "))
    let value = UInt64(cleaned, radix: 16) ?? 0
    self.init(
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255
    )
  }
}
