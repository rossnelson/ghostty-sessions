import AppKit
import SwiftUI

// Demo mode draws a 1920×1080 stage: a mock menu bar, a mock Ghostty window and
// the real sidebar, all fed with invented sessions. It is for recording videos.

struct StageFrames: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

extension View {
  func stageFrame(_ key: String) -> some View {
    background(
      GeometryReader { proxy in
        Color.clear.preference(key: StageFrames.self, value: [key: proxy.frame(in: .named("stage"))])
      }
    )
  }
}

struct DemoTab: Identifiable, Equatable {
  let id: String
  var name: String
  var working: Bool
  var lines: [String]
}

@MainActor
final class DemoModel: ObservableObject {
  @Published var tabs: [DemoTab] = []
  @Published var selectedTab: String?
  @Published var cursor = CGPoint(x: 760, y: 620)
  @Published var cursorVisible = false
  @Published var clicks = 0
  @Published var keycaps: [String]?
  @Published var banner: (title: String, subtitle: String, body: String)?
  @Published var titleCard: (title: String, subtitle: String)?
  @Published var panelVisible = false
  @Published var curtain = true
  var frames: [String: CGRect] = [:]
}

struct DemoStage: View {
  @ObservedObject var store: SessionStore
  @ObservedObject var model: DemoModel

  private var theme: Theme { store.theme }

  var body: some View {
    ZStack(alignment: .topLeading) {
      Wallpaper(theme: theme)

      MockMenuBar(store: store)

      MockTerminal(model: model, theme: theme)
        .frame(width: 1430, height: 970)
        .offset(x: 50, y: 70)

      if model.panelVisible {
        SidebarView(store: store)
          .frame(width: 350, height: 1020)
          .offset(x: 1550, y: 46)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }

      if let banner = model.banner {
        Banner(title: banner.title, subtitle: banner.subtitle, text: banner.body, theme: theme)
          .frame(width: 380)
          .offset(x: 1150, y: 52)
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      if let keys = model.keycaps {
        Keycaps(keys: keys, theme: theme)
          .frame(width: 1430)
          .offset(x: 50, y: 760)
          .transition(.scale(scale: 0.8).combined(with: .opacity))
      }

      if let card = model.titleCard {
        TitleCard(title: card.title, subtitle: card.subtitle, theme: theme)
          .transition(.opacity)
      }

      if model.cursorVisible {
        Cursor(clicks: model.clicks)
          .offset(x: model.cursor.x, y: model.cursor.y)
          .transition(.opacity)
      }

      Color.black.opacity(model.curtain ? 1 : 0).allowsHitTesting(false)
    }
    .frame(width: 1920, height: 1080, alignment: .topLeading)
    .clipped()
    .coordinateSpace(name: "stage")
    .onPreferenceChange(StageFrames.self) { frames in
      MainActor.assumeIsolated { model.frames = frames }
    }
    .foregroundStyle(theme.foreground)
  }
}

private struct Wallpaper: View {
  let theme: Theme

  var body: some View {
    ZStack {
      LinearGradient(colors: [Color(hex: "#1a1b26"), Color(hex: "#24283b"), Color(hex: "#1f2335")], startPoint: .topLeading, endPoint: .bottomTrailing)
      TimelineView(.animation(minimumInterval: 1 / 30)) { context in
        let t = context.date.timeIntervalSinceReferenceDate
        ZStack {
          Circle().fill(theme.accent.opacity(0.35)).frame(width: 900).blur(radius: 160)
            .offset(x: -420 + 80 * sin(t / 6), y: -260 + 60 * cos(t / 7))
          Circle().fill(theme.working.opacity(0.3)).frame(width: 800).blur(radius: 170)
            .offset(x: 520 + 70 * cos(t / 8), y: 300 + 50 * sin(t / 5))
        }
      }
    }
    .frame(width: 1920, height: 1080)
  }
}

private struct MockMenuBar: View {
  @ObservedObject var store: SessionStore

  var body: some View {
    let theme = store.theme
    let waiting = store.waiting
    let permission = waiting.contains { $0.state == .needsPermission }
    let badge = permission ? theme.permission : theme.waiting

    HStack(spacing: 22) {
      Image(systemName: "apple.logo").font(.system(size: 15))
      Text("Ghostty").font(.system(size: 13.5, weight: .bold))
      ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 13.5)) }
      Spacer()
      HStack(spacing: 4) {
        Image(systemName: "sparkles.rectangle.stack")
          .foregroundStyle(waiting.isEmpty ? Color.white : badge)
        if !waiting.isEmpty {
          Text("\(waiting.count)")
            .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(badge)
            .contentTransition(.numericText(value: Double(waiting.count)))
        }
      }
      .animation(.spring, value: waiting.count)
      .animation(.easeInOut, value: permission)
      Image(systemName: "wifi")
      Image(systemName: "battery.75percent")
      Text("Tue 9:41 AM").font(.system(size: 13.5))
    }
    .font(.system(size: 14))
    .foregroundStyle(.white)
    .padding(.horizontal, 22)
    .frame(width: 1920, height: 32)
    .background(.black.opacity(0.28))
  }
}

private struct MockTerminal: View {
  @ObservedObject var model: DemoModel
  let theme: Theme

  private var selected: DemoTab? { model.tabs.first { $0.id == model.selectedTab } }

  var body: some View {
    VStack(spacing: 0) {
      titleBar
      tabBar
      transcript
    }
    .background(theme.background)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
    .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
  }

  private var titleBar: some View {
    HStack(spacing: 8) {
      ForEach([Color(hex: "#ff5f57"), Color(hex: "#febc2e"), Color(hex: "#28c840")], id: \.self) {
        Circle().fill($0).frame(width: 12, height: 12)
      }
      Spacer()
      Text(selected.map { "\($0.working ? "◐" : "✳") \($0.name)" } ?? "")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.dim)
      Spacer()
    }
    .padding(.horizontal, 16)
    .frame(height: 38)
  }

  private var tabBar: some View {
    TimelineView(.periodic(from: .now, by: 0.18)) { context in
      let spin = ["◐", "◓", "◑", "◒"][Int(context.date.timeIntervalSinceReferenceDate / 0.18) % 4]
      HStack(spacing: 4) {
        ForEach(model.tabs) { tab in
          let isSelected = tab.id == model.selectedTab
          HStack(spacing: 6) {
            Text(tab.working ? spin : "✳").foregroundStyle(tab.working ? theme.working : theme.dim)
            Text(tab.name).lineLimit(1)
          }
          .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? theme.foreground : theme.dim)
          .padding(.horizontal, 12)
          .frame(maxWidth: 230, minHeight: 30)
          .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(isSelected ? 0.1 : 0.03)))
          .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 8)
      .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.tabs)
      .animation(.easeInOut(duration: 0.2), value: model.selectedTab)
    }
  }

  private var transcript: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let tab = selected {
        ForEach(Array(tab.lines.enumerated()), id: \.offset) { _, line in
          TranscriptLine(text: line, theme: theme)
        }
        Spacer()
        if tab.working {
          WorkingLine(theme: theme)
        }
        InputBox(theme: theme, focused: !tab.working)
      }
    }
    .padding(.horizontal, 34)
    .padding(.vertical, 26)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .id(model.selectedTab)
    .transition(.opacity)
    .animation(.easeInOut(duration: 0.25), value: model.selectedTab)
  }
}

private struct TranscriptLine: View {
  let text: String
  let theme: Theme

  var body: some View {
    if text.hasPrefix(">") {
      Text(text)
        .foregroundStyle(theme.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
        .font(theme.mono(17))
    } else if text.hasPrefix("⏺") {
      Text(text).font(theme.mono(17)).foregroundStyle(theme.foreground)
    } else {
      Text(text).font(theme.mono(16)).foregroundStyle(theme.dim)
    }
  }
}

private struct WorkingLine: View {
  let theme: Theme

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.12)) { context in
      let glyphs = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
      let glyph = glyphs[Int(context.date.timeIntervalSinceReferenceDate / 0.12) % glyphs.count]
      Text("\(glyph) Working… (esc to interrupt)")
        .font(theme.mono(16))
        .foregroundStyle(theme.accent)
    }
  }
}

private struct InputBox: View {
  let theme: Theme
  let focused: Bool

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.55)) { context in
      let on = Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
      HStack(spacing: 8) {
        Text(">").foregroundStyle(theme.dim)
        Rectangle()
          .fill(theme.foreground)
          .frame(width: 10, height: 20)
          .opacity(focused && on ? 1 : 0)
        Spacer()
      }
      .font(theme.mono(17))
      .padding(.horizontal, 14)
      .frame(height: 46)
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.dim.opacity(focused ? 0.9 : 0.4)))
    }
  }
}

private struct Banner: View {
  let title: String
  let subtitle: String
  let text: String
  let theme: Theme

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      RoundedRectangle(cornerRadius: 9)
        .fill(LinearGradient(colors: [theme.accent, theme.working], startPoint: .topLeading, endPoint: .bottomTrailing))
        .frame(width: 38, height: 38)
        .overlay(Image(systemName: "sparkles.rectangle.stack").font(.system(size: 18)).foregroundStyle(.white))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 14, weight: .semibold))
        Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.foreground.opacity(0.85))
        Text(text).font(.system(size: 13)).foregroundStyle(theme.dim).lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .background {
      if #available(macOS 26.0, *) {
        Color.clear.glassEffect(.regular.tint(theme.background.opacity(0.5)), in: .rect(cornerRadius: 18))
      } else {
        RoundedRectangle(cornerRadius: 18).fill(theme.background.opacity(0.92))
      }
    }
    .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
  }
}

private struct Keycaps: View {
  let keys: [String]
  let theme: Theme

  var body: some View {
    HStack(spacing: 14) {
      ForEach(keys, id: \.self) { key in
        Text(key)
          .font(.system(size: 34, weight: .semibold, design: .rounded))
          .padding(.horizontal, key.count > 1 ? 30 : 22)
          .frame(minWidth: 78, minHeight: 78)
          .background(
            RoundedRectangle(cornerRadius: 16)
              .fill(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom))
              .shadow(color: .black.opacity(0.4), radius: 0, y: 4)
          )
          .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.25)))
      }
    }
    .foregroundStyle(.white)
  }
}

private struct TitleCard: View {
  let title: String
  let subtitle: String
  let theme: Theme

  var body: some View {
    ZStack {
      Rectangle().fill(.black.opacity(0.55))
      VStack(spacing: 18) {
        Image(systemName: "sparkles.rectangle.stack")
          .font(.system(size: 64, weight: .medium))
          .foregroundStyle(LinearGradient(colors: [theme.accent, theme.working], startPoint: .topLeading, endPoint: .bottomTrailing))
        Text(title).font(.system(size: 72, weight: .bold, design: .rounded))
        Text(subtitle).font(.system(size: 28, weight: .medium)).foregroundStyle(theme.foreground.opacity(0.75))
      }
    }
    .frame(width: 1920, height: 1080)
  }
}

private struct Cursor: View {
  let clicks: Int
  @Local private var ring = true

  var body: some View {
    ZStack(alignment: .topLeading) {
      Circle()
        .stroke(.white.opacity(ring ? 0 : 0.9), lineWidth: 3)
        .frame(width: ring ? 64 : 10, height: ring ? 64 : 10)
        .offset(x: ring ? -32 : -5, y: ring ? -32 : -5)
      Image(systemName: "cursorarrow")
        .font(.system(size: 30, weight: .regular))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.7), radius: 3, y: 2)
        .offset(x: -6, y: -4)
    }
    .onChange(of: clicks) {
      ring = false
      DispatchQueue.main.async {
        withAnimation(.easeOut(duration: 0.5)) { ring = true }
      }
    }
  }
}
