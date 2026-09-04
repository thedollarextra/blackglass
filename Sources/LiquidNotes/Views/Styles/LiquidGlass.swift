import SwiftUI
import AppKit
import CoreImage
import QuartzCore

public struct VisualEffectBlur: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode
    public var state: NSVisualEffectView.State

    public init(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = true
        view.autoresizingMask = [.width, .height]
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.isEmphasized = true
    }
}

public struct LiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat

    public func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.45),
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)
    }
}

enum WindowChrome {
    /// Traffic-light row. Title + egg live in this band.
    static let titlebarRowHeight: CGFloat = 28
    /// At rest the list starts here, just below the lights. Scrolling
    /// moves rows up through the glass behind the buttons.
    static let trafficLightContentInset: CGFloat = 32
    /// Ends 1px above the scrollbar so the scroller itself is never frosted.
    static let trafficLightGlassHeight: CGFloat = 31
    static let headerVertical: CGFloat = 0
}

/// Real window controls drawn in the SwiftUI sidebar so they cannot be
/// covered by full-size content. Matches Finder: 12pt lights, 8pt gaps.
struct WindowTrafficLights: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            TrafficLightDot(fill: Color(red: 1.00, green: 0.37, blue: 0.34), symbol: "xmark", hovering: hovering) {
                NSApp.keyWindow?.performClose(nil)
            }
            .help("Close")
            .accessibilityLabel("Close")

            TrafficLightDot(fill: Color(red: 0.996, green: 0.74, blue: 0.18), symbol: "minus", hovering: hovering) {
                NSApp.keyWindow?.miniaturize(nil)
            }
            .help("Minimize")
            .accessibilityLabel("Minimize")

            TrafficLightDot(fill: Color(red: 0.15, green: 0.78, blue: 0.25), symbol: "plus", hovering: hovering) {
                NSApp.keyWindow?.zoom(nil)
            }
            .help("Zoom")
            .accessibilityLabel("Zoom")
        }
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

struct SidebarToggle: View {
    @Binding var sidebarVisible: Bool

    var body: some View {
        Button {
            sidebarVisible.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.body)
                .foregroundStyle(sidebarVisible ? Color.primary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .keyboardShortcut("s", modifiers: [.command, .control])
        .accessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
    }
}

private struct TrafficLightDot: View {
    var fill: Color
    var symbol: String
    var hovering: Bool
    var action: () -> Void

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
            if hovering {
                Image(systemName: symbol)
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.55))
            }
        }
        .frame(width: 12, height: 12)
        .contentShape(Circle())
        .onTapGesture(perform: action)
        .focusable(false)
    }
}

/// Finder's blur behind the traffic lights: rows going under the lights go
/// out of focus, while the window itself stays exactly as solid as it is
/// everywhere else.
///
/// This is a pure backdrop blur — a layer with a Gaussian `backgroundFilters`
/// and no background color of its own, so it *only* defocuses what is already
/// painted behind it and contributes no color. An `NSVisualEffectView` can't
/// do this: every material composites its own tint, which is what visibly
/// recoloured the top of the sidebar. macOS 26's `.scrollEdgeEffectStyle` is
/// the system version of this, but it keys off a real titlebar safe area,
/// which this window deliberately ignores to draw its own chrome.
struct ProgressiveTitlebarGlass: View {
    var body: some View {
        BackdropBlur(radius: 9)
            .allowsHitTesting(false)
    }
}

private struct BackdropBlur: NSViewRepresentable {
    var radius: Double

    func makeNSView(context: Context) -> BackdropBlurView {
        BackdropBlurView(radius: radius)
    }

    func updateNSView(_ nsView: BackdropBlurView, context: Context) {
        nsView.radius = radius
    }
}

final class BackdropBlurView: NSView {
    var radius: Double {
        didSet {
            guard radius != oldValue else { return }
            applyFilter()
        }
    }

    /// Fades the blur out toward the bottom of the strip, so rows don't snap
    /// from focused to defocused at a hard line.
    private let fade = CAGradientLayer()

    init(radius: Double) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        // Without this, AppKit never runs `backgroundFilters` through Core
        // Image at all — the filter is silently ignored rather than erroring,
        // which is why the strip showed no blur whatsoever.
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]

        fade.colors = [
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0.55).cgColor,
            NSColor.black.withAlphaComponent(0).cgColor,
        ]
        fade.locations = [0, 0.55, 1]
        // Layer geometry is bottom-up, so start at the top edge.
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.mask = fade
        applyFilter()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Never intercepts clicks — rows underneath stay selectable.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // The mask is not in the layer's own layout pass, so size it by hand.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = layer?.bounds ?? bounds
        CATransaction.commit()
    }

    private func applyFilter() {
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return }
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        layer?.backgroundFilters = [filter]
    }
}

/// Finder-style out-of-focus blur as notes scroll under the traffic lights:
/// just pushes scroll content down so it starts below the lights instead of
/// under them — the actual blurring is `ProgressiveTitlebarGlass`, an
/// overlay sampling this content in real time as it scrolls past.
struct TrafficLightScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        content
            .contentMargins(.top, WindowChrome.trafficLightContentInset, for: .scrollContent)
            .contentMargins(.top, WindowChrome.trafficLightContentInset, for: .scrollIndicators)
    }
}

public extension View {
    func liquidGlass(cornerRadius: CGFloat = 12) -> some View {
        self.modifier(LiquidGlassModifier(cornerRadius: cornerRadius))
    }

    func hidesTitlebarFill() -> some View {
        modifier(TitlebarFillHider())
    }
}

private struct TitlebarFillHider: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(WindowChromeInstaller())
            .toolbarBackground(.clear, for: .windowToolbar)
            .toolbarBackground(.clear, for: .automatic)
            .modifier(WindowContainerBackground())
            .modifier(HiddenToolbarBackgroundVisibility())
    }
}

private struct WindowContainerBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(.clear, for: .window)
        } else {
            content
        }
    }
}

private struct HiddenToolbarBackgroundVisibility: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// Pushes content under a transparent titlebar so the sidebar/editor
/// material is the only color at the top of the window.
struct WindowChromeInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeView {
        WindowChromeView()
    }

    func updateNSView(_ nsView: WindowChromeView, context: Context) {
        nsView.applyChrome()
    }
}

final class WindowChromeView: NSView {
    override var intrinsicContentSize: NSSize { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyChrome()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyChrome()
    }

    override func layout() {
        super.layout()
        applyChrome()
    }

    func applyChrome() {
        guard let window else { return }
        configureLiquidNotesWindow(window)
    }
}

public extension View {
    /// Double-clicking empty title-bar-style chrome (the row that stands in
    /// for a real NSWindow titlebar) does the same thing double-clicking an
    /// actual title bar does — zoom or minimize, per the user's System
    /// Settings preference. Only observes `mouseUp`, so `mouseDown` still
    /// falls through untouched to `isMovableByWindowBackground`'s own drag
    /// tracking on the same region.
    func systemTitlebarDoubleClick() -> some View {
        background(TitlebarDoubleClickCatcher())
    }

    /// Opts a region out of the window's `isMovableByWindowBackground`, so a
    /// drag starting here moves what's under the cursor rather than the whole
    /// window — without it, dragging a file row just slides the window.
    func blocksWindowDrag() -> some View {
        background(WindowDragBlocker())
    }
}

private struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragBlockingView { WindowDragBlockingView() }
    func updateNSView(_ nsView: WindowDragBlockingView, context: Context) {}
}

final class WindowDragBlockingView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

private struct TitlebarDoubleClickCatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarDoubleClickView { TitlebarDoubleClickView() }
    func updateNSView(_ nsView: TitlebarDoubleClickView, context: Context) {}
}

final class TitlebarDoubleClickView: NSView {
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard event.clickCount == 2, let window else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    /// Marks a window as belonging to the "main" WindowGroup (sidebar +
    /// editor), as opposed to a popped-out single-note window. Lets
    /// `MenuBarController` find a main window to surface even while note
    /// windows are also open, since both kinds share the same hidden-titlebar
    /// chrome and `canBecomeMain`.
    static let liquidNotesMainWindow = NSUserInterfaceItemIdentifier("LiquidNotes.mainWindow")
}

public extension View {
    /// Tags the window this view lands in as a main LiquidNotes window.
    /// Apply once, to the root of the main WindowGroup's content. Pass
    /// `false` for a popped-out single-note window, which shares this same
    /// view but shouldn't be found by `MenuBarController`'s main-window
    /// lookup.
    @ViewBuilder
    func tagAsLiquidNotesMainWindow(_ isMain: Bool = true) -> some View {
        if isMain {
            background(MainWindowTagger())
        } else {
            self
        }
    }
}

private struct MainWindowTagger: NSViewRepresentable {
    func makeNSView(context: Context) -> TaggingView { TaggingView() }
    func updateNSView(_ nsView: TaggingView, context: Context) {}
}

private final class TaggingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = .liquidNotesMainWindow
    }
}

@MainActor
func configureLiquidNotesWindow(_ window: NSWindow) {
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.styleMask.insert(.fullSizeContentView)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.isMovableByWindowBackground = true

    // System buttons stay in the titlebar layer, which SwiftUI covers.
    // The visible cluster is WindowTrafficLights in the sidebar.
    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
        window.standardWindowButton(kind)?.isHidden = true
    }
}
