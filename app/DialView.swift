import SwiftUI

struct DialView: View {
    @ObservedObject var controller: FanController

    private let size: CGFloat = 224
    private let tickRadius: CGFloat = 86
    private let tickCount = 28
    private let centerRadius: CGFloat = 50

    private enum DragMode { case idle, ring, centerTap, outside }
    @State private var dragMode: DragMode = .idle

    var body: some View {
        ZStack {
            // dial face
            Circle()
                .fill(Color(white: 0.10))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 18, y: 8)

            ticks
            marker
            center
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(dialGesture)
        .animation(.easeOut(duration: 0.15), value: controller.displayFraction)
    }

    // MARK: ring of ticks

    private var ticks: some View {
        let fraction = controller.displayFraction
        let filledCount = Int((fraction * Double(tickCount)).rounded())
        let dim = !controller.snapshot.manual && controller.dragFraction == nil
        return ForEach(0..<tickCount, id: \.self) { i in
            Capsule()
                .fill(tickColor(index: i, filledCount: filledCount, dim: dim))
                .frame(width: 5, height: 19)
                .offset(y: -tickRadius)
                .rotationEffect(.degrees(Double(i) / Double(tickCount) * 360))
        }
    }

    private func tickColor(index: Int, filledCount: Int, dim: Bool) -> Color {
        guard index < filledCount else { return Color(white: 0.27) }
        let pos = (Double(index) + 0.5) / Double(tickCount)
        let base: Color =
            pos < 0.60 ? Color(red: 0.20, green: 0.84, blue: 0.42) :
            pos < 0.85 ? Color(red: 1.00, green: 0.72, blue: 0.18) :
                         Color(red: 1.00, green: 0.33, blue: 0.30)
        return dim ? base.opacity(0.45) : base
    }

    // MARK: leading-edge marker

    private var marker: some View {
        let fraction = controller.displayFraction
        return TrianglePointer()
            .fill(markerColor)
            .frame(width: 9, height: 9)
            .offset(y: -(tickRadius + 20))
            .rotationEffect(.degrees(fraction * 360))
            .opacity(fraction > 0.01 ? 1 : 0)
    }

    private var markerColor: Color {
        let f = controller.displayFraction
        if !controller.snapshot.manual && controller.dragFraction == nil { return Color(white: 0.5) }
        return f < 0.60 ? Color(red: 0.20, green: 0.84, blue: 0.42)
             : f < 0.85 ? Color(red: 1.00, green: 0.72, blue: 0.18)
             : Color(red: 1.00, green: 0.33, blue: 0.30)
    }

    // MARK: center readout

    private var center: some View {
        VStack(spacing: 1) {
            Image(systemName: "fanblades.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(controller.snapshot.manual ? Color(red: 0.20, green: 0.84, blue: 0.42)
                                                            : Color(white: 0.55))
            Text(verbatim: "\(controller.displayRPM)")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(caption)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(Color(white: 0.55))
        }
        .frame(width: centerRadius * 2, height: centerRadius * 2)
        .background(
            Circle().strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
    }

    private var caption: String {
        if dragMode == .ring { return "SET RPM" }
        if controller.applying || controller.dragFraction != nil { return "APPLYING…" }
        return controller.snapshot.manual ? "RPM · MANUAL" : "RPM · AUTO"
    }

    // MARK: gesture

    private var dialGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let c = CGPoint(x: size / 2, y: size / 2)
                if dragMode == .idle {
                    let startDist = hypot(value.startLocation.x - c.x, value.startLocation.y - c.y)
                    if startDist < centerRadius * 0.9 {
                        dragMode = .centerTap
                    } else if startDist <= size / 2 + 10 {
                        dragMode = .ring
                    } else {
                        dragMode = .outside
                    }
                }
                if dragMode == .ring {
                    let f = fraction(at: value.location, center: c)
                    controller.dragFraction = clampNoWrap(f, previous: controller.dragFraction)
                }
            }
            .onEnded { value in
                defer { dragMode = .idle }
                switch dragMode {
                case .ring:
                    if let f = controller.dragFraction { controller.commit(fraction: f) }
                case .centerTap:
                    let moved = hypot(value.translation.width, value.translation.height)
                    if moved < 8 { controller.toggleAuto() }
                default:
                    break
                }
            }
    }

    /// Angle → fraction, 0 at 12 o'clock, clockwise.
    private func fraction(at p: CGPoint, center c: CGPoint) -> Double {
        var a = atan2(p.x - c.x, -(p.y - c.y))
        if a < 0 { a += 2 * .pi }
        return a / (2 * .pi)
    }

    /// Stop the value teleporting from 1 → 0 (or back) when the drag crosses 12 o'clock.
    private func clampNoWrap(_ f: Double, previous: Double?) -> Double {
        guard let prev = previous else { return f }
        if abs(f - prev) > 0.5 { return prev > 0.5 ? 1 : 0 }
        return f
    }
}

struct TrianglePointer: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
