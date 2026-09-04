import SwiftUI

public struct EggGlyph: View {
    var mode: EditorMode

    public var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.08, dy: size.height * 0.06)
            switch mode {
            case .uncooked:
                drawWholeEgg(context: context, in: rect)
            case .cooked:
                drawSunnySideUp(context: context, in: rect)
            }
        }
        .accessibilityHidden(true)
    }

    private func drawWholeEgg(context: GraphicsContext, in rect: CGRect) {
        let path = wholeEggPath(in: rect)

        context.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 1.00, green: 0.98, blue: 0.93),
                    Color(red: 0.93, green: 0.87, blue: 0.74)
                ]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
            )
        )

        var inner = context
        inner.clip(to: path)
        let shine = Path(ellipseIn: CGRect(
            x: rect.minX + rect.width * 0.22,
            y: rect.minY + rect.height * 0.16,
            width: rect.width * 0.32,
            height: rect.height * 0.28
        ))
        inner.fill(shine, with: .color(.white.opacity(0.72)))

        let speckles: [(CGFloat, CGFloat, CGFloat)] = [
            (0.38, 0.46, 0.05),
            (0.62, 0.58, 0.045),
            (0.48, 0.70, 0.04),
            (0.70, 0.38, 0.035)
        ]
        for speckle in speckles {
            let r = rect.width * speckle.2
            inner.fill(
                Path(ellipseIn: CGRect(
                    x: rect.minX + rect.width * speckle.0,
                    y: rect.minY + rect.height * speckle.1,
                    width: r,
                    height: r * 0.85
                )),
                with: .color(Color(red: 0.72, green: 0.58, blue: 0.38).opacity(0.35))
            )
        }

        context.stroke(
            path,
            with: .color(Color(red: 0.55, green: 0.45, blue: 0.30).opacity(0.45)),
            lineWidth: max(0.6, rect.width * 0.045)
        )
    }

    private func drawSunnySideUp(context: GraphicsContext, in rect: CGRect) {
        let white = albumenPath(in: rect)
        context.fill(white, with: .color(.white))
        context.stroke(
            white,
            with: .color(Color.black.opacity(0.10)),
            lineWidth: max(0.5, rect.width * 0.04)
        )

        let yolkSide = min(rect.width, rect.height) * 0.42
        let yolkRect = CGRect(
            x: rect.midX - yolkSide * 0.42,
            y: rect.midY - yolkSide * 0.48,
            width: yolkSide,
            height: yolkSide
        )
        let yolk = Path(ellipseIn: yolkRect)
        context.fill(
            yolk,
            with: .radialGradient(
                Gradient(colors: [
                    Color(red: 1.00, green: 0.86, blue: 0.28),
                    Color(red: 0.96, green: 0.55, blue: 0.12)
                ]),
                center: CGPoint(x: yolkRect.midX - yolkSide * 0.08, y: yolkRect.midY - yolkSide * 0.10),
                startRadius: 0,
                endRadius: yolkSide * 0.62
            )
        )

        let highlight = Path(ellipseIn: CGRect(
            x: yolkRect.minX + yolkSide * 0.18,
            y: yolkRect.minY + yolkSide * 0.16,
            width: yolkSide * 0.28,
            height: yolkSide * 0.22
        ))
        context.fill(highlight, with: .color(.white.opacity(0.75)))

        context.stroke(
            yolk,
            with: .color(Color(red: 0.78, green: 0.38, blue: 0.06).opacity(0.45)),
            lineWidth: max(0.5, rect.width * 0.035)
        )
    }

    private func wholeEggPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY + rect.height * 0.12),
            control1: CGPoint(x: rect.maxX - rect.width * 0.06, y: rect.minY + rect.height * 0.16),
            control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.38)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.06),
            control2: CGPoint(x: rect.midX + rect.width * 0.38, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.12),
            control1: CGPoint(x: rect.midX - rect.width * 0.38, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.06)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.38),
            control2: CGPoint(x: rect.minX + rect.width * 0.06, y: rect.minY + rect.height * 0.16)
        )
        path.closeSubpath()
        return path
    }

    private func albumenPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.18))
        path.addCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.10, y: rect.minY + rect.height * 0.30),
            control1: CGPoint(x: rect.minX + rect.width * 0.48, y: rect.minY - rect.height * 0.02),
            control2: CGPoint(x: rect.maxX - rect.width * 0.22, y: rect.minY + rect.height * 0.04)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.maxY - rect.height * 0.22),
            control1: CGPoint(x: rect.maxX + rect.width * 0.06, y: rect.minY + rect.height * 0.48),
            control2: CGPoint(x: rect.maxX - rect.width * 0.02, y: rect.maxY - rect.height * 0.40)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY - rect.height * 0.12),
            control1: CGPoint(x: rect.maxX - rect.width * 0.22, y: rect.maxY + rect.height * 0.04),
            control2: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.18),
            control1: CGPoint(x: rect.minX - rect.width * 0.04, y: rect.maxY - rect.height * 0.36),
            control2: CGPoint(x: rect.minX + rect.width * 0.04, y: rect.minY + rect.height * 0.38)
        )
        path.closeSubpath()
        return path
    }
}

public struct EggModeToggle: View {
    @Binding var mode: EditorMode
    @State private var hovering = false

    public var body: some View {
        Button(action: toggle) {
            EggGlyph(mode: mode)
                .id(mode)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .frame(width: 16, height: 16)
                .padding(4)
                .background {
                    Circle()
                        .fill(.quaternary.opacity(hovering ? 0.95 : 0.55))
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8)
                }
                .scaleEffect(hovering ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .help(mode.helpText)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                self.hovering = hovering
            }
        }
        .accessibilityLabel("Cook notes")
        .accessibilityValue(mode.title)
        .accessibilityHint("Toggles uncooked raw text and cooked rendered markdown.")
    }

    private func toggle() {
        withAnimation(.spring(duration: 0.28, bounce: 0.32)) {
            mode = mode == .uncooked ? .cooked : .uncooked
        }
    }
}
