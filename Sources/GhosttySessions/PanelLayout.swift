import CoreGraphics

enum PanelEdge: String {
  case left
  case right
}

/// Where the panel goes beside Ghostty's window, and where the window goes
/// when it must make room. All frames are in Cocoa coordinates.
struct PanelLayout: Equatable {
  /// The panel, beside the window and as tall as it.
  var panel: CGRect
  /// A new frame for the window when it reaches into the panel's place. `nil`
  /// means leave the window where it is.
  var windowFrame: CGRect?

  /// The space between the window and the panel.
  static let gap: CGFloat = 6
  /// The space between the panel and the screen edge.
  static let inset: CGFloat = 4
  /// The window is not narrowed below this width.
  static let minimumWindowWidth: CGFloat = 360
  /// Overflow up to this many points counts as fitting. A window often
  /// settles a point or two from where it was placed; without slack, each
  /// correction would trigger another one.
  static let tolerance: CGFloat = 6

  /// `screen` is the visible frame of the window's display: below the menu
  /// bar and beside the Dock.
  static func compute(window: CGRect, screen: CGRect, edge: PanelEdge, width: CGFloat) -> PanelLayout {
    let reserved = width + gap + inset
    var target = window
    switch edge {
    case .right:
      let limit = screen.maxX - reserved
      if target.maxX > limit + tolerance {
        target.size.width = max(limit - target.minX, minimumWindowWidth)
        target.origin.x = max(min(target.minX, limit - target.width), screen.minX)
      }
    case .left:
      let limit = screen.minX + reserved
      if target.minX < limit - tolerance {
        target.size.width = max(target.maxX - limit, minimumWindowWidth)
        target.origin.x = limit
      }
    }
    target = CGRect(
      x: target.minX.rounded(), y: target.minY.rounded(),
      width: target.width.rounded(), height: target.height.rounded())

    // As tall as the window, but never under the menu bar or the Dock.
    let bottom = max(target.minY, screen.minY)
    let top = min(target.maxY, screen.maxY)
    let x = edge == .right ? target.maxX + gap : target.minX - gap - width
    return PanelLayout(
      panel: CGRect(x: x, y: bottom, width: width, height: max(top - bottom, 0)),
      windowFrame: target.isClose(to: window, within: 0.5) ? nil : target)
  }
}
