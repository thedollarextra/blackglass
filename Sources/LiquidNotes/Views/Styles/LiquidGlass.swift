import SwiftUI
import AppKit

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

/// Frost behind the traffic lights. On macOS 26 this is the system Liquid
/// Glass scroll-edge blur (content goes out of focus as it passes under the
/// lights). Older macOS keeps a masked in-window material fade.
struct ProgressiveTitlebarGlass: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.55), location: 0.45),
                            .init(color: .black.opacity(0.18), location: 0.78),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .allowsHitTesting(false)
        } else {
            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .top) {
                    FinderTitlebarFrost(material: .hudWindow, peak: 1)
                        .frame(height: h)
                    FinderTitlebarFrost(material: .titlebar, peak: 0.9)
                        .frame(height: h * 0.62)
                    FinderTitlebarFrost(material: .headerView, peak: 1)
                        .frame(height: h * 0.28)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Finder-style out-of-focus blur as notes scroll under the traffic lights.
struct TrafficLightScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectHidden(true, for: .bottom)
                .safeAreaBar(edge: .top, spacing: 0) {
                    Color.clear
                        .frame(height: WindowChrome.trafficLightContentInset)
                        .allowsHitTesting(false)
                }
        } else {
            content
                .contentMargins(.top, WindowChrome.trafficLightContentInset, for: .scrollContent)
                .contentMargins(.top, WindowChrome.trafficLightContentInset, for: .scrollIndicators)
        }
    }
}

/// NSVisualEffectView with `.withinWindow` blending — the same path Finder
/// uses to blur scrolling content under the titlebar — plus a stretchable
/// `maskImage` so the frost eases off with no hard edge.
private struct FinderTitlebarFrost: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var peak: CGFloat

    func makeNSView(context: Context) -> MaskedTitlebarEffectView {
        let view = MaskedTitlebarEffectView()
        view.apply(material: material, peak: peak)
        return view
    }

    func updateNSView(_ nsView: MaskedTitlebarEffectView, context: Context) {
        nsView.apply(material: material, peak: peak)
    }
}

final class MaskedTitlebarEffectView: NSVisualEffectView {
    private var peak: CGFloat = 1
    private var maskHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .withinWindow
        state = .active
        isEmphasized = true
        material = .titlebar
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        blendingMode = .withinWindow
        state = .active
        isEmphasized = true
        material = .titlebar
        autoresizingMask = [.width, .height]
    }

    func apply(material: NSVisualEffectView.Material, peak: CGFloat) {
        self.material = material
        blendingMode = .withinWindow
        state = .active
        isEmphasized = true
        if self.peak != peak {
            self.peak = peak
            maskHeight = 0
            refreshMask()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshMask()
    }

    private func refreshMask() {
        let height = bounds.height
        guard height > 0, abs(height - maskHeight) > 0.5 else { return }
        maskHeight = height
        maskImage = Self.fadeMask(height: height, peak: peak)
    }

    /// Alpha-only vertical gradient. Stops match the previous fade so the
    /// frost still starts in the same place; only the material is Finder’s.
    private static func fadeMask(height: CGFloat, peak: CGFloat) -> NSImage {
        let size = NSSize(width: 1, height: max(ceil(height), 1))
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let stops: [(CGFloat, CGFloat)] = [
                (0.00, peak),
                (0.45, peak * 0.55),
                (0.78, peak * 0.18),
                (1.00, 0)
            ]
            let colors = stops.map { CGColor(gray: 0, alpha: $0.1) } as CFArray
            let locations = stops.map(\.0)
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceGray(),
                colors: colors,
                locations: locations
            ) else { return false }
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: rect.height),
                options: []
            )
            return true
        }
        image.resizingMode = .stretch
        image.capInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        return image
    }
}

public extension View {
    func liquidGlass(cornerRadius: CGFloat = 12) -> some View {
        self.modifier(LiquidGlassModifier(cornerRadius: cornerRadius))
    }

    func hidesTitlebarFill() -> some View {
        modifier(TitlebarFillHider())
    }

    /// Replicates the system's "double-click title bar" gesture on custom
    /// chrome standing in for the real (hidden) titlebar, honoring the
    /// user's own System Settings choice instead of hard-coding one.
    func systemTitlebarDoubleClick() -> some View {
        modifier(TitlebarDoubleClickModifier())
    }

    /// Tags this view's window `.liquidNotesMainWindow` so
    /// `MenuBarController` can find/reuse the real main window without
    /// matching a popped-out note window, which also hosts `MainWindowView`
    /// but passes `isMain: false` here.
    func tagAsLiquidNotesMainWindow(_ isMain: Bool = true) -> some View {
        background {
            if isMain {
                MainWindowTagger()
            }
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    static let liquidNotesMainWindow = NSUserInterfaceItemIdentifier("liquidNotesMainWindow")
}

private struct TitlebarDoubleClickModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard let window = NSApp.keyWindow else { return }
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize":
                    window.performMiniaturize(nil)
                case "None":
                    break
                default:
                    window.performZoom(nil)
                }
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
        // A window launched this app silently at login (see AppDelegate):
        // close the very first one instead of letting it appear, leaving
        // only the menu bar extra behind. One-shot — every window after
        // this turn (including one the user opens later from the status
        // item) behaves normally.
        if let delegate = NSApp.delegate as? AppDelegate, delegate.suppressInitialWindow {
            delegate.suppressInitialWindow = false
            // Deferred one tick: closing a window from inside its own
            // layout pass (this can be called from `layout()`) is safer
            // done just after that pass finishes, and it's still well
            // before AppKit would actually composite the window on screen.
            DispatchQueue.main.async { [weak window] in
                window?.close()
            }
        }
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
