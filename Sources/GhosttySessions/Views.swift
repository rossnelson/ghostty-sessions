import AppKit
import SwiftUI

struct SidebarView: View {
  @ObservedObject var store: SessionStore
  @Namespace private var rows
  @Local private var appeared = false

  private var theme: Theme { store.theme }
  private var order: [String] { store.sessions.map { "\($0.id)-\($0.needsYou)-\($0.idle)" } }

  var body: some View {
    VStack(spacing: 0) {
      Header(store: store)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)

      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 4) {
          content
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: order)
      }

      NewSessionCard(store: store)
        .padding(10)
    }
    .foregroundStyle(theme.foreground)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PanelBackground(theme: theme))
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .strokeBorder(
          LinearGradient(
            colors: [theme.foreground.opacity(0.25), theme.foreground.opacity(0.04)],
            startPoint: .top, endPoint: .bottom),
          lineWidth: 1)
    )
    .opacity(appeared ? 1 : 0)
    .offset(x: appeared ? 0 : 40)
    .onAppear {
      withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { appeared = true }
    }
  }

  @ViewBuilder
  private var content: some View {
    if !store.ghosttyRunning {
      EmptyState(theme: theme, text: "Ghostty is not running")
    }

    if store.ghosttyRunning && store.sessions.isEmpty {
      EmptyState(theme: theme, text: "No Claude sessions yet")
    }

    if !store.waiting.isEmpty {
      SectionLabel(title: "Needs you", count: store.waiting.count, color: theme.waiting)
        .transition(.opacity)
    }

    ForEach(Array(store.waiting.enumerated()), id: \.element.id) { index, session in
      row(session, index: index)
    }

    if !store.working.isEmpty {
      SectionLabel(title: "Working", count: store.working.count, color: theme.working)
        .padding(.top, store.waiting.isEmpty ? 0 : 10)
        .transition(.opacity)
    }

    ForEach(Array(store.working.enumerated()), id: \.element.id) { index, session in
      row(session, index: index)
    }

    if !store.idle.isEmpty {
      SectionLabel(title: "Idle", count: store.idle.count, color: theme.dim)
        .padding(.top, 10)
        .transition(.opacity)
    }

    ForEach(Array(store.idle.enumerated()), id: \.element.id) { index, session in
      row(session, index: index)
    }
  }

  // `--expand-all` opens every card, for screenshots.
  private static let expandAll = CommandLine.arguments.contains("--expand-all")

  private func row(_ session: Session, index: Int) -> some View {
    SessionRow(
      session: session,
      theme: theme,
      isCurrent: store.focusedID == session.id,
      expanded: store.expanded.contains(session.id) || Self.expandAll,
      onTap: { store.focus(session) },
      onToggle: {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { store.toggleExpanded(session.id) }
      }
    )
    .stageFrame("row-\(session.id)")
    .matchedGeometryEffect(id: session.id, in: rows)
    .transition(
      .asymmetric(
        insertion: .scale(scale: 0.92).combined(with: .opacity).combined(with: .offset(x: 30)),
        removal: .scale(scale: 0.9).combined(with: .opacity)
      )
    )
  }
}

private struct PanelBackground: View {
  let theme: Theme

  var body: some View {
    ZStack {
      if #available(macOS 26.0, *) {
        Color.clear.glassEffect(.regular.tint(theme.background.opacity(0.55)), in: .rect(cornerRadius: 24))
      } else {
        VisualEffect().overlay(theme.background.opacity(0.7))
      }

      // A slow drifting glow keeps the glass from feeling flat.
      TimelineView(.animation(minimumInterval: 1 / 30)) { context in
        let t = context.date.timeIntervalSinceReferenceDate
        RadialGradient(
          colors: [theme.accent.opacity(0.18), .clear],
          center: UnitPoint(x: 0.5 + 0.35 * sin(t / 7), y: 0.15 + 0.1 * cos(t / 9)),
          startRadius: 0, endRadius: 320
        )
        .blendMode(.plusLighter)
      }
      .allowsHitTesting(false)
    }
  }
}

private struct VisualEffect: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct Header: View {
  @ObservedObject var store: SessionStore

  var body: some View {
    let theme = store.theme
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Sessions")
          .font(.system(size: 20, weight: .semibold, design: .rounded))
        HStack(spacing: 8) {
          Stat(value: store.waiting.count, label: "waiting", color: theme.waiting)
          Stat(value: store.working.count, label: "working", color: theme.working)
        }
        .font(theme.mono(11))
        .foregroundStyle(theme.dim)
      }
      Spacer()
      Text("⌃⌥Space")
        .font(theme.mono(10))
        .foregroundStyle(theme.dim)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(theme.foreground.opacity(0.08)))
        .help("Jump to the session that has waited longest")
    }
  }
}

private struct Stat: View {
  let value: Int
  let label: String
  let color: Color

  var body: some View {
    HStack(spacing: 4) {
      Circle().fill(color).frame(width: 5, height: 5)
      Text("\(value)")
        .contentTransition(.numericText(value: Double(value)))
        .animation(.spring, value: value)
      Text(label)
    }
  }
}

private struct SectionLabel: View {
  let title: String
  let count: Int
  let color: Color

  var body: some View {
    HStack(spacing: 6) {
      Text(title.uppercased())
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .tracking(1.2)
      Rectangle()
        .fill(LinearGradient(colors: [color.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing))
        .frame(height: 1)
    }
    .foregroundStyle(color)
    .padding(.horizontal, 8)
    .padding(.top, 6)
    .padding(.bottom, 2)
  }
}

private struct EmptyState: View {
  let theme: Theme
  let text: String

  var body: some View {
    VStack(spacing: 10) {
      TimelineView(.animation(minimumInterval: 1 / 30)) { context in
        Text("✳")
          .font(.system(size: 34))
          .foregroundStyle(theme.accent.opacity(0.6))
          .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 12))
      }
      Text(text)
        .font(theme.mono(12))
        .foregroundStyle(theme.dim)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }
}

struct SessionRow: View {
  let session: Session
  let theme: Theme
  let isCurrent: Bool
  let expanded: Bool
  let onTap: () -> Void
  let onToggle: () -> Void

  @Local private var hovering = false
  @Local private var flash = false

  private var color: Color {
    guard !session.idle else { return theme.dim }
    return switch session.state {
    case .needsPermission: theme.permission
    case .yourTurn: theme.waiting
    case .working: theme.working
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header

      if expanded {
        SessionDetails(session: session, theme: theme)
          .padding(.leading, 21)
          .transition(.opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.97, anchor: .top)))
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, session.idle && !expanded ? 7 : 10)
    .background(rowBackground)
    .overlay(Shimmer(trigger: session.attention, color: color))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(color.opacity(isCurrent ? 0.55 : 0), lineWidth: 1)
    )
    .contentShape(Rectangle())
    .scaleEffect(hovering && !expanded ? 1.015 : 1)
    .keyframeAnimator(initialValue: 1.0, trigger: session.attention) { content, scale in
      content.scaleEffect(scale)
    } keyframes: { _ in
      SpringKeyframe(1.06, duration: 0.18, spring: .bouncy)
      SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
    .animation(.easeInOut(duration: 0.25), value: isCurrent)
    .onHover { hovering = $0 }
    .onTapGesture {
      flash = true
      withAnimation(.easeOut(duration: 0.45)) { flash = false }
      onTap()
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 11) {
      StatusOrb(state: session.state, color: color, quiet: session.idle)

      VStack(alignment: .leading, spacing: 3) {
        Text(session.title)
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(session.idle ? theme.foreground.opacity(0.7) : theme.foreground)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)

        if let claudeTitle = session.claudeTitle {
          Text(claudeTitle)
            .font(.system(size: 10.5))
            .foregroundStyle(theme.dim)
            .lineLimit(1)
        }

        if !session.repos.isEmpty || session.shellRunning {
          HStack(spacing: 4) {
            if session.shellRunning { ShellBadge(theme: theme) }
            if !expanded { RepoChips(repos: session.repos, theme: theme) }
          }
          .contentShape(Rectangle())
          .onTapGesture(perform: onToggle)
          .stageFrame("chips-\(session.id)")
        }


        if let detail = session.detail {
          Text(detail)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(theme.permission)
            .lineLimit(2)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }

      Spacer(minLength: 4)

      VStack(alignment: .trailing, spacing: 6) {
        Elapsed(since: session.since, theme: theme)
        Button(action: onToggle) {
          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .frame(width: 18, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.dim)
        .opacity(hovering || expanded ? 1 : 0)
        .help(expanded ? "Collapse" : "Show repos and last action")
      }
    }
  }

  private var rowBackground: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(theme.foreground.opacity(hovering ? 0.09 : (isCurrent ? 0.06 : 0.025)))
      if session.needsYou {
        LinearGradient(colors: [color.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
      }
      color.opacity(flash ? 0.35 : 0)
    }
  }
}

struct StatusOrb: View {
  let state: SessionState
  let color: Color
  var quiet = false

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 60)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      ZStack {
        switch state {
        case _ where quiet: Circle().fill(color).frame(width: 6, height: 6).transition(.scale.combined(with: .opacity))
        case .working: working(t)
        case .yourTurn: breathing(t)
        case .needsPermission: ripple(t)
        }
      }
    }
    .frame(width: 16, height: 16)
    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: state)
  }

  private func working(_ t: Double) -> some View {
    ZStack {
      Circle()
        .stroke(color.opacity(0.15), lineWidth: 2)
      Circle()
        .trim(from: 0, to: 0.7)
        .stroke(
          AngularGradient(colors: [color.opacity(0), color], center: .center, startAngle: .zero, endAngle: .degrees(252)),
          style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(t * 300))
      Circle()
        .fill(color)
        .frame(width: 4, height: 4)
    }
    .transition(.scale.combined(with: .opacity))
  }

  private func breathing(_ t: Double) -> some View {
    let phase = (sin(t * 2.2) + 1) / 2
    return Circle()
      .fill(color)
      .frame(width: 9, height: 9)
      .scaleEffect(0.85 + 0.15 * phase)
      .shadow(color: color.opacity(0.9), radius: 2 + 5 * phase)
      .transition(.scale.combined(with: .opacity))
  }

  private func ripple(_ t: Double) -> some View {
    let phase = t.truncatingRemainder(dividingBy: 1.4) / 1.4
    return ZStack {
      Circle()
        .stroke(color, lineWidth: 1.5)
        .scaleEffect(0.6 + phase * 1.1)
        .opacity(1 - phase)
      Circle()
        .fill(color)
        .frame(width: 9, height: 9)
        .shadow(color: color, radius: 4)
    }
    .transition(.scale.combined(with: .opacity))
  }
}

private struct Elapsed: View {
  let since: Date
  let theme: Theme

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let text = Self.format(context.date.timeIntervalSince(since))
      Text(text)
        .font(theme.mono(10.5))
        .foregroundStyle(theme.dim)
        .contentTransition(.numericText())
        .animation(.snappy, value: text)
    }
  }

  static func format(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    if s < 5 { return "now" }
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
    return "\(s / 86400)d"
  }
}

// A band of light that sweeps across a row when its session starts to wait.
private struct Shimmer: View {
  let trigger: Int
  let color: Color
  @Local private var progress: CGFloat = 1.5

  var body: some View {
    GeometryReader { proxy in
      LinearGradient(
        colors: [.clear, color.opacity(0.35), .clear],
        startPoint: .leading, endPoint: .trailing
      )
      .frame(width: proxy.size.width * 0.5)
      .offset(x: proxy.size.width * progress - proxy.size.width * 0.25)
    }
    .allowsHitTesting(false)
    .onChange(of: trigger) {
      progress = -0.5
      withAnimation(.easeInOut(duration: 0.9)) { progress = 1.5 }
    }
  }
}

// Claude finished its turn, but a background shell it started is still running.
private struct ShellBadge: View {
  let theme: Theme

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
      let phase = (sin(context.date.timeIntervalSinceReferenceDate * 3) + 1) / 2
      HStack(spacing: 3) {
        Circle().fill(theme.success).frame(width: 5, height: 5).opacity(0.4 + 0.6 * phase)
        Text("shell")
      }
    }
    .font(theme.mono(10))
    .foregroundStyle(theme.success)
    .padding(.horizontal, 5)
    .padding(.vertical, 1.5)
    .background(Capsule().fill(theme.success.opacity(0.12)))
    .fixedSize()
    .help("A background shell is still running")
  }
}

private struct RepoChips: View {
  let repos: [RepoChip]
  let theme: Theme

  var body: some View {
    if let first = repos.first {
      HStack(spacing: 4) {
        HStack(spacing: 3) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 8, weight: .semibold))
          Text((first.label as NSString).lastPathComponent)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .foregroundStyle(theme.foreground.opacity(0.75))
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(theme.foreground.opacity(0.09)))

        if repos.count > 1 {
          Text("+\(repos.count - 1)")
            .foregroundStyle(theme.dim)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(theme.foreground.opacity(0.05)))
            .fixedSize()
        }
      }
      .font(theme.mono(10))
      .help("Click to show all repos")
    }
  }
}

private struct SessionDetails: View {
  let session: Session
  let theme: Theme

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(session.repos.enumerated()), id: \.element) { index, repo in
        RepoLine(repo: repo, primary: index == 0, theme: theme)
      }

      if let lastTool = session.lastTool, session.detail == nil {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Image(systemName: "terminal")
            .font(.system(size: 8.5, weight: .semibold))
          Text(lastTool)
            .lineLimit(3)
        }
        .font(theme.mono(10))
        .foregroundStyle(theme.dim)
        .padding(.top, 2)
      }
    }
    .padding(.top, 4)
  }
}

private struct RepoLine: View {
  let repo: RepoChip
  let primary: Bool
  let theme: Theme
  @Local private var hovering = false

  private var showsBranch: Bool {
    guard let branch = repo.branch else { return false }
    return branch != (repo.label as NSString).lastPathComponent
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      Image(systemName: primary ? "arrow.triangle.branch" : "folder")
        .font(.system(size: 8.5, weight: .semibold))
        .foregroundStyle(primary ? theme.accent : theme.dim)
      VStack(alignment: .leading, spacing: 1) {
        Text(repo.label)
          .foregroundStyle(theme.foreground.opacity(primary ? 0.9 : 0.75))
        if showsBranch, let branch = repo.branch {
          Text(branch)
            .foregroundStyle(theme.dim)
        }
      }
      .lineLimit(2)
      .truncationMode(.middle)
      Spacer(minLength: 0)
      Image(systemName: "arrow.up.forward.square")
        .font(.system(size: 9))
        .foregroundStyle(theme.dim)
        .opacity(hovering ? 1 : 0)
    }
    .font(theme.mono(10.5))
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(RoundedRectangle(cornerRadius: 6).fill(theme.foreground.opacity(hovering ? 0.08 : 0)))
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture {
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
    }
    .help("Show \(repo.path) in Finder")
    .animation(.easeOut(duration: 0.15), value: hovering)
  }
}

struct NewSessionCard: View {
  @ObservedObject var store: SessionStore
  @Namespace private var morph
  @Local private var folder = ""
  @Local private var name = ""
  @Local private var busy = false
  @Local private var failed = false
  @FocusState private var promptFocused: Bool

  private var theme: Theme { store.theme }

  var body: some View {
    ZStack {
      if store.composerOpen { form } else { button }
    }
    .animation(.spring(response: 0.45, dampingFraction: 0.82), value: store.composerOpen)
  }

  private var button: some View {
    Button {
      folder = folder.isEmpty ? (store.folders.first ?? "") : folder
      store.composerOpen = true
      promptFocused = true
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "plus")
          .font(.system(size: 12, weight: .bold))
        Text("New session")
          .font(.system(size: 12.5, weight: .semibold))
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 11)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(LinearGradient(colors: [theme.accent.opacity(0.35), theme.working.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
          .matchedGeometryEffect(id: "card", in: morph)
      )
    }
    .buttonStyle(.plain)
    .stageFrame("new")
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("New session").font(.system(size: 13, weight: .semibold))
        Spacer()
        Button { close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
          .buttonStyle(.plain)
          .foregroundStyle(theme.dim)
      }

      TextField("What should Claude do? (optional)", text: $store.composerPrompt, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .lineLimit(2...6)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.foreground.opacity(0.07)))
        .focused($promptFocused)
        .stageFrame("prompt")

      HStack(spacing: 6) {
        TextField("name", text: $name)
          .textFieldStyle(.plain)
          .font(theme.mono(11))
          .padding(7)
          .background(RoundedRectangle(cornerRadius: 9).fill(theme.foreground.opacity(0.07)))

        Menu {
          ForEach(store.folders, id: \.self) { path in
            Button(abbreviate(path)) { folder = path }
          }
          Divider()
          Button("Choose folder…", action: chooseFolder)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "folder").font(.system(size: 9))
            Text((folder as NSString).lastPathComponent).lineLimit(1)
          }
          .font(theme.mono(11))
          .padding(7)
          .background(RoundedRectangle(cornerRadius: 9).fill(theme.foreground.opacity(0.07)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
      }

      if failed {
        Text("Ghostty did not open a tab. Allow Automation for Ghostty Sessions in System Settings.")
          .font(.system(size: 10.5))
          .foregroundStyle(theme.permission)
          .transition(.opacity)
      }

      Button(action: create) {
        ZStack {
          if busy {
            ProgressView().controlSize(.small)
          } else {
            Text("Start Claude  ⌘↩").font(.system(size: 12, weight: .semibold))
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.accent.opacity(0.45)))
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.return, modifiers: .command)
      .stageFrame("start")
      .disabled(folder.isEmpty || busy)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(theme.foreground.opacity(0.06))
        .matchedGeometryEffect(id: "card", in: morph)
    )
    .animation(.easeInOut(duration: 0.2), value: failed)
  }

  private func create() {
    guard !folder.isEmpty, !busy else { return }
    busy = true
    failed = false
    let task = store.composerPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let label = name.trimmingCharacters(in: .whitespaces)

    Task {
      let ok = await store.startSession(in: folder, name: label, prompt: task)
      busy = false
      failed = !ok
      if ok { close() }
    }
  }

  private func close() {
    store.composerOpen = false
    name = ""
    store.composerPrompt = ""
    failed = false
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.directoryURL = URL(fileURLWithPath: folder.isEmpty ? NSHomeDirectory() : folder)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    store.addFolder(url.path)
    folder = url.path
  }

  private func abbreviate(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }
}
