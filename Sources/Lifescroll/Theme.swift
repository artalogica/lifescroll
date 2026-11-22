import AppKit
import SwiftUI

// Smoked glass. Every surface is a dark, blurred panel with light text on it, so the app reads the
// same over a white wallpaper as over a dark one, and in light or dark system appearance.
// Colour is spent in one place only: the blush on suggestion cards.

enum Glass {
  // The three text strengths and the pane tint are kept as numbers too, so the self-test can
  // check every one of them stays readable over a pure white backdrop (see `contrast`).
  static let inkOpacity = 0.96
  static let softOpacity = 0.80
  static let faintOpacity = 0.62
  static let smokeLevel = 0.09
  static let paneOpacity = 0.80

  static let ink = Color.white.opacity(inkOpacity)
  static let soft = Color.white.opacity(softOpacity)
  static let faint = Color.white.opacity(faintOpacity)

  /// The tint laid over the blur.
  static let smoke = Color(red: 0.085, green: 0.085, blue: 0.095)

  /// The contrast ratio (as WCAG measures it) of white text at `textOpacity` on the pane, when what
  /// lies behind the glass has the given brightness, 0 for black to 1 for white. The system blur
  /// darkens the backdrop further, so the real figure is a little better than this.
  static func contrast(textOpacity: Double, backdrop: Double) -> Double {
    func luminance(_ level: Double) -> Double {
      level <= 0.03928 ? level / 12.92 : pow((level + 0.055) / 1.055, 2.4)
    }
    let pane = paneOpacity * smokeLevel + (1 - paneOpacity) * backdrop
    let text = textOpacity + (1 - textOpacity) * pane
    return (luminance(text) + 0.05) / (luminance(pane) + 0.05)
  }

  /// Room left at the top of a window for the close, minimise and zoom buttons.
  static let titleBarHeight: CGFloat = 28
  /// Inset cards sit darker than the panel, like wells cut into the glass.
  static let well = Color.black.opacity(0.26)
  static let hairline = Color.white.opacity(0.10)

  static let blushRose = Color(red: 0.97, green: 0.60, blue: 0.70)
  static let blushPeach = Color(red: 0.99, green: 0.78, blue: 0.60)
  static let amber = Color(red: 1.0, green: 0.80, blue: 0.47)
  static let coral = Color(red: 1.0, green: 0.56, blue: 0.52)
  static let mint = Color(red: 0.52, green: 0.88, blue: 0.66)

  static let cardRadius: CGFloat = 16
}

// MARK: - Surfaces

private struct RenderingPreviewKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// True while a view is being drawn to an image for `--render-ui`. AppKit-backed pieces (the
  /// behind-window blur, text fields, scroll views) cannot be drawn that way and are stood in for.
  var renderingPreview: Bool {
    get { self[RenderingPreviewKey.self] }
    set { self[RenderingPreviewKey.self] = newValue }
  }
}

/// Blurs whatever is behind the window: the wallpaper, or other apps.
struct BehindWindowBlur: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    // Pinned dark, so the blur itself does not turn pale in light system appearance.
    view.appearance = NSAppearance(named: .vibrantDark)
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct GlassPanel: ViewModifier {
  @Environment(\.renderingPreview) private var preview

  func body(content: Content) -> some View {
    content
      .foregroundStyle(Glass.ink)
      .background {
        ZStack {
          if !preview { BehindWindowBlur() }
          Glass.smoke.opacity(Glass.paneOpacity)
          // A faint sheen from the top-left corner, the way light catches a pane.
          LinearGradient(
            colors: [Color.white.opacity(0.10), Color.white.opacity(0)], startPoint: .topLeading,
            endPoint: .center)
        }
        .ignoresSafeArea()
      }
      .environment(\.colorScheme, .dark)
  }
}

private struct GlassCard: ViewModifier {
  var blush = false
  var tint: Color?
  var padding: CGFloat = 14

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Glass.cardRadius, style: .continuous)
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        ZStack {
          shape.fill(Glass.well)
          if blush {
            shape.fill(
              LinearGradient(
                colors: [Glass.blushRose.opacity(0.24), Glass.blushPeach.opacity(0.08), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing))
          }
          if let tint { shape.fill(tint.opacity(0.14)) }
        }
      }
      .overlay {
        shape.strokeBorder(
          LinearGradient(
            colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)], startPoint: .top,
            endPoint: .bottom), lineWidth: 1
        )
        // Decoration only: it must never take a click meant for what is inside the card.
        .allowsHitTesting(false)
      }
  }
}

extension View {
  /// The outer pane of a popover or window.
  func glassPanel() -> some View { modifier(GlassPanel()) }

  /// An inset card on a pane.
  func glassCard(blush: Bool = false, tint: Color? = nil, padding: CGFloat = 14) -> some View {
    modifier(GlassCard(blush: blush, tint: tint, padding: padding))
  }
}

// MARK: - Controls

struct GlassButtonStyle: ButtonStyle {
  enum Kind {
    /// The one white pill on a card: the thing to do.
    case primary
    /// A glass pill for everything else.
    case secondary
    /// Text only until hovered. For footers.
    case quiet
    /// A round glass button holding a symbol.
    case icon
    /// A full-width choice, as in "which matters more?".
    case row
  }

  var kind: Kind = .secondary
  var compact = false
  /// Marks a button whose action cannot be undone. Only the secondary kind draws it.
  var destructive = false

  func makeBody(configuration: Configuration) -> some View {
    GlassButtonBody(configuration: configuration, kind: kind, compact: compact, destructive: destructive)
  }
}

private struct GlassButtonBody: View {
  let configuration: ButtonStyle.Configuration
  let kind: GlassButtonStyle.Kind
  let compact: Bool
  let destructive: Bool
  @Environment(\.isEnabled) private var enabled
  @State private var hovering = false

  private func fill(rest: Double, hover: Double, pressed: Double) -> Color {
    Color.white.opacity(configuration.isPressed ? pressed : (hovering ? hover : rest))
  }

  var body: some View {
    Group {
      switch kind {
      case .primary:
        configuration.label
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color(white: 0.07))
          .frame(maxWidth: .infinity)
          .frame(height: compact ? 28 : 34)
          .background(Capsule().fill(fill(rest: 0.94, hover: 1, pressed: 0.78)))
      case .secondary:
        configuration.label
          .font(.system(size: compact ? 11 : 12, weight: .medium))
          .foregroundStyle(destructive ? Glass.coral : Glass.ink)
          .padding(.horizontal, compact ? 10 : 12)
          .frame(height: compact ? 24 : 28)
          .background(Capsule().fill(fill(rest: 0.10, hover: 0.16, pressed: 0.24)))
          .overlay(
            Capsule().strokeBorder(destructive ? Glass.coral.opacity(0.45) : Glass.hairline))
      case .quiet:
        configuration.label
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(hovering ? Glass.ink : Glass.soft)
          .padding(.horizontal, 10)
          .frame(height: 26)
          .background(Capsule().fill(fill(rest: 0, hover: 0.09, pressed: 0.16)))
      case .icon:
        configuration.label
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Glass.ink)
          .frame(width: 28, height: 28)
          .background(Circle().fill(fill(rest: 0.10, hover: 0.16, pressed: 0.24)))
          .overlay(Circle().strokeBorder(Glass.hairline))
      case .row:
        configuration.label
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(Glass.ink)
          .multilineTextAlignment(.leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(fill(rest: 0.08, hover: 0.14, pressed: 0.22))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Glass.hairline))
      }
    }
    .opacity(enabled ? 1 : 0.36)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.12), value: hovering)
  }
}

/// A pill-shaped switch between a few options, with the chosen one raised.
struct GlassSegmented<Value: Hashable>: View {
  let options: [(value: Value, label: String)]
  @Binding var selection: Value
  /// What the switch chooses, read out by VoiceOver before the options.
  var label = ""
  @Namespace private var namespace

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options, id: \.value) { option in
        let selected = option.value == selection
        Button {
          withAnimation(.easeOut(duration: 0.16)) { selection = option.value }
        } label: {
          Text(option.label)
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Glass.ink : Glass.soft)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background {
              if selected {
                Capsule().fill(Color.white.opacity(0.18))
                  .matchedGeometryEffect(id: "selection", in: namespace)
              }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // These are drawn as plain buttons, so the chosen one has to be announced explicitly.
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
      }
    }
    .padding(3)
    .background(Capsule().fill(Color.black.opacity(0.28)))
    .overlay(Capsule().strokeBorder(Glass.hairline))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
  }
}

/// A small pill for a fact about a card: a deadline, a project, a time estimate.
struct Chip: View {
  let text: String
  var systemImage: String?
  var color: Color = Glass.soft

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
      }
      Text(text).lineLimit(1)
    }
    .font(.system(size: 11, weight: .medium))
    .foregroundStyle(color)
    .padding(.horizontal, 8)
    .frame(height: 20)
    .background(Capsule().fill(Color.white.opacity(0.09)))
  }
}

/// Lays chips out left to right and wraps onto a new line when they run out of room, so a chip is
/// never squeezed down to "due in…".
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  private func rows(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
    var frames: [CGRect] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      // A single chip wider than the whole row is allowed to shrink; nothing else is.
      let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      if x > 0, x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return (frames, CGSize(width: widest, height: y + rowHeight))
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    rows(width: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let frames = rows(width: bounds.width, subviews: subviews).frames
    for (subview, frame) in zip(subviews, frames) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }
}

/// A scrolling column at run time. Scroll views cannot be drawn to an image, so previews get a plain stack.
struct GlassScroll<Content: View>: View {
  @Environment(\.renderingPreview) private var preview
  /// The id of a row to keep in view, for lists driven from the keyboard.
  var following: String? = nil
  @ViewBuilder let content: () -> Content

  var body: some View {
    if preview {
      // Takes the space it is given and cuts off what does not fit, as a scroll view would show it.
      Color.clear
        .overlay(alignment: .top) { content() }
        .clipped()
    } else {
      ScrollViewReader { proxy in
        ScrollView { content() }
          .scrollContentBackground(.hidden)
          .onChange(of: following) { _, target in
            if let target { proxy.scrollTo(target) }
          }
      }
    }
  }
}

/// A text field set into the glass. Previews show its prompt as plain text.
struct GlassField: View {
  @Environment(\.renderingPreview) private var preview
  let prompt: String
  @Binding var text: String
  var onSubmit: () -> Void = {}
  @FocusState private var focused: Bool

  var body: some View {
    Group {
      if preview {
        Text(text.isEmpty ? prompt : text)
          .foregroundStyle(text.isEmpty ? Glass.faint : Glass.ink)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        TextField(
          "", text: $text, prompt: Text(prompt).foregroundStyle(Glass.faint)
        )
        .textFieldStyle(.plain)
        .foregroundStyle(Glass.ink)
        .focused($focused)
        .onSubmit(onSubmit)
      }
    }
    .font(.system(size: 13))
    .padding(.horizontal, 14)
    .frame(height: 34)
    // The text itself is only a line tall inside the pill. A click anywhere else on the pill
    // lands here and starts typing all the same.
    .background(Capsule().fill(Color.black.opacity(0.28)).onTapGesture { focused = true })
    // The outline is decoration. Left able to take clicks, it sat over the text and took every
    // one of them, so the field could never be clicked into.
    .overlay(Capsule().strokeBorder(Glass.hairline).allowsHitTesting(false))
  }
}
