import SwiftUI
import CoreMotion
import QuartzCore

/// The hand-drawn inbox doodles, ported path-for-path from the web app's
/// `inbox-doodles.tsx` — wobbly sketch strokes, ink at 16% with the odd
/// orange accent, and the hand-drawn sparkle.

struct DoodleSpec {
    struct Stroke {
        var d: String
        var orange = false
        var filled = false
    }

    var width: CGFloat
    var height: CGFloat
    var strokes: [Stroke]
}

enum DoodleGlyphs {
    static let envelope = DoodleSpec(width: 34, height: 28, strokes: [
        .init(d: "M3.4 5.1 Q4 3.4 6 3.8 L26 2.9 Q29.2 2.7 28.4 5.7 L29.1 18.6 Q29.7 21.6 26.5 21.1 L5.2 22.2 Q2.1 22.7 3 19.6 L3.4 5.1 Z"),
        .init(d: "M2.7 5.7 Q8.8 10.6 14.3 14.2 Q15.4 15 16.6 13.9 Q22.2 9.2 28.6 4.9"),
    ])

    static let document = DoodleSpec(width: 26, height: 32, strokes: [
        .init(d: "M4.9 3.5 Q2.7 2.9 3.3 5.3 L2.4 26.6 Q2 29.5 4.8 29 L20.9 28.1 Q23.6 28.5 23 25.8 L23.8 5 Q24.3 2.2 21.5 2.9 L4.9 3.5 Z"),
        .init(d: "M6.8 9.7 Q12.1 8 17.4 9.2"),
        .init(d: "M6.9 15.4 Q12.2 16.8 17.5 14.9"),
        .init(d: "M7 21.2 Q10.3 19.9 13.6 21.6"),
    ])

    static let clock = DoodleSpec(width: 28, height: 28, strokes: [
        .init(d: "M15.3 3.5 C21.7 3.8 25.9 9.1 24.5 15.1 C23.2 20.9 17.7 25.7 11.8 24.3 C6.3 23.1 2.4 17.8 3.7 12 C4.8 6.9 9.2 3.2 14.4 3.6"),
        .init(d: "M14.5 7.9 Q13.4 11.2 14.1 14.3"),
        .init(d: "M13.8 13.7 Q16.9 15.1 19.6 17.5"),
    ])

    static let briefcase = DoodleSpec(width: 30, height: 30, strokes: [
        .init(d: "M4.7 8.7 Q2.4 8.2 3.2 10.5 L2.5 24.6 Q2.1 27.5 5 27 L25.3 26.1 Q27.9 26.6 27.3 24 L28.1 9.9 Q28.7 7.3 26 7.9 L4.7 8.7 Z"),
        .init(d: "M10.6 8.9 L9.7 4.8 Q9.5 3.4 11.1 3.7 L19 3.2 Q20.7 3 20.4 4.6 L20.8 8.4"),
    ])

    static let certificate = DoodleSpec(width: 26, height: 28, strokes: [
        .init(d: "M5.8 3 L16.3 2.1 Q17.5 2 18.2 2.9 L22.4 7.4 Q23.5 8.2 23.3 9.4 L22.3 24.7 Q22.6 27 20.5 26.6 L6.1 27.3 Q3.8 27.7 4.2 25.2 L5.8 3 Z"),
        .init(d: "M16.9 2.2 L16.4 8 Q16.3 9.2 17.7 9 L23.5 8.5"),
    ])

    static let checkCircle = DoodleSpec(width: 26, height: 26, strokes: [
        .init(d: "M13.8 3.6 C19.2 3.1 23.8 8 22.6 13.6 C21.6 18.7 17.2 23.6 11.7 22.3 C6.7 21.2 2.7 16.9 3.6 11.8 C4.4 7 8.7 3.8 13.2 3.8"),
        .init(d: "M8.2 13.6 Q10.5 14.8 11.7 17.2 Q14.2 12 19.1 9", orange: true),
    ])

    static let voicePill = DoodleSpec(width: 40, height: 24, strokes: [
        .init(d: "M10.5 3.8 L17.9 3.1 C23.3 2.7 27 7 25.8 11.7 C24.8 15.9 21.3 19.2 17.1 19.1 L9.1 19.5 C4.5 19.4 1.5 15.1 2.7 10.5 C3.6 6.5 6.6 4 10.5 3.8 Z"),
        .init(d: "M30.5 7.7 Q33.3 4.7 36.4 2.9", orange: true),
        .init(d: "M29.7 12.3 Q33.7 10.9 37.4 12.2", orange: true),
        .init(d: "M30.3 16.4 Q33.5 19.5 36.3 21.4", orange: true),
    ])

    static let sparkle = DoodleSpec(width: 26, height: 26, strokes: [
        .init(d: "M13.2 1.1 Q13.7 6.4 15.7 9.5 Q19.2 11.2 24 12.1 Q19.1 13 15.5 14.9 Q14.2 18.4 12.8 23 Q12 18.2 10.2 14.7 Q6.7 13.1 2 11.9 Q6.9 10.9 10.4 9.2 Q12.2 5.7 13.2 1.1 Z", orange: true, filled: true),
    ])

    /// Hand-drawn rubbish bin — wobbly lid, handle, tapered body, two ribs.
    static let bin = DoodleSpec(width: 26, height: 28, strokes: [
        .init(d: "M4.2 7.4 Q13.1 5.6 22.2 7"),
        .init(d: "M10.4 6.7 Q10.2 3.3 13.2 3.6 Q16 3.2 15.8 6.3"),
        .init(d: "M6.2 8.1 L7.5 24.2 Q7.6 26.4 9.7 26.2 L16.9 25.9 Q19 26.1 19.1 23.9 L20.1 7.6"),
        .init(d: "M11 11.3 Q10.7 16.6 11.4 21.5"),
        .init(d: "M15.5 11 Q15.9 16.2 15.2 21.3"),
    ])

    static let monitor = DoodleSpec(width: 30, height: 28, strokes: [
        .init(d: "M4.8 3.8 Q2.4 3.2 3.2 5.6 L2.5 17.2 Q2.1 20.3 5.2 19.8 L25 18.9 Q27.7 19.5 27.2 16.9 L28 5 Q28.5 2.4 25.7 3.1 L4.2 3.3 Z"),
        .init(d: "M6 24.7 Q15.2 22.9 24.2 24.3"),
        .init(d: "M15.5 19.4 Q14.5 22 15.1 24.6"),
    ])
}

/// Renders one doodle at its natural size, group opacity 16% like the web.
/// A `tint` overrides every stroke colour (for full-strength icon use).
struct DoodleGlyph: View {
    var spec: DoodleSpec
    var opacity: Double = 0.16
    var tint: Color?

    var body: some View {
        Canvas { context, _ in
            context.opacity = opacity
            for stroke in spec.strokes {
                let path = SVGPath.parse(stroke.d)
                let color = tint ?? (stroke.orange ? PaperInk.brand : PaperInk.ink)
                if stroke.filled {
                    context.fill(path, with: .color(color))
                } else {
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
        .frame(width: spec.width, height: spec.height)
    }
}

// MARK: - Gravity physics

/// One tumbling doodle. Positions are centre points in field coordinates.
private struct DoodleBody {
    var spec: DoodleSpec
    var homeFractionX: Double
    var designTop: Double
    var homeRotation: Double

    var x: CGFloat = 0
    var y: CGFloat = 0
    var vx: CGFloat = 0
    var vy: CGFloat = 0
    var rotation: CGFloat = 0
    var home: CGPoint = .zero
    var phase: CGFloat = .random(in: 0 ..< 2 * .pi)
    var bobSpeed: CGFloat = .random(in: 0.9 ..< 1.4)

    var radius: CGFloat { max(spec.width, spec.height) / 2 }
}

/// Device-gravity physics for the doodle field: held upright they sit in
/// their designed spots (with the idle bob); tilt the phone and they tumble,
/// bouncing off the tray walls, the floor, each other, and the underside of
/// the lowest inbox row.
@Observable
final class DoodleFieldModel: NSObject {
    struct Placed: Identifiable {
        var id: Int
        var spec: DoodleSpec
        var x: CGFloat
        var y: CGFloat
        var rotation: CGFloat
    }

    private(set) var placed: [Placed] = []
    private(set) var hidden = false

    var size: CGSize = .zero { didSet { rehome() } }
    var ceiling: CGFloat = 0 { didSet { rehome() } }

    private var bodies: [DoodleBody] = [
        DoodleBody(spec: DoodleGlyphs.envelope, homeFractionX: 0.09, designTop: 30, homeRotation: -6),
        DoodleBody(spec: DoodleGlyphs.document, homeFractionX: 0.28, designTop: 55, homeRotation: 5),
        DoodleBody(spec: DoodleGlyphs.clock, homeFractionX: 0.48, designTop: 28, homeRotation: -4),
        DoodleBody(spec: DoodleGlyphs.briefcase, homeFractionX: 0.67, designTop: 52, homeRotation: 6),
        DoodleBody(spec: DoodleGlyphs.certificate, homeFractionX: 0.86, designTop: 30, homeRotation: -5),
        DoodleBody(spec: DoodleGlyphs.checkCircle, homeFractionX: 0.17, designTop: 120, homeRotation: 4),
        DoodleBody(spec: DoodleGlyphs.voicePill, homeFractionX: 0.38, designTop: 125, homeRotation: -5),
        DoodleBody(spec: DoodleGlyphs.sparkle, homeFractionX: 0.58, designTop: 118, homeRotation: 0),
        DoodleBody(spec: DoodleGlyphs.monitor, homeFractionX: 0.76, designTop: 122, homeRotation: -4),
    ]

    private var link: CADisplayLink?
    private let motion = CMMotionManager()
    private var lastTimestamp: CFTimeInterval = 0
    private var settled = false

    func start() {
        guard link == nil else { return }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1 / 60
            motion.startDeviceMotionUpdates()
        }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        motion.stopDeviceMotionUpdates()
        lastTimestamp = 0
    }

    /// Recompute spawn positions when the field or the item pile changes:
    /// scatter the design layout across the empty zone, then let gravity
    /// take it from there.
    private func rehome() {
        guard size.width > 0 else { return }
        let zone = size.height - ceiling
        hidden = zone < 80

        for index in bodies.indices {
            bodies[index].home = CGPoint(
                x: size.width * bodies[index].homeFractionX + 16,
                y: ceiling + 18 + (bodies[index].designTop / 155) * max(zone - 36, 30)
            )
            if !settled {
                bodies[index].x = bodies[index].home.x
                bodies[index].y = bodies[index].home.y
                bodies[index].rotation = bodies[index].homeRotation
            }
            // Keep everything inside the new bounds when the pile grows.
            bodies[index].y = min(max(bodies[index].y, ceiling + bodies[index].radius), size.height - bodies[index].radius)
        }
        settled = true
        publish()
    }

    @objc private func step(_ link: CADisplayLink) {
        guard size.width > 0, !hidden else { return }
        let dt = CGFloat(min(link.targetTimestamp - (lastTimestamp == 0 ? link.timestamp : lastTimestamp), 1 / 30))
        lastTimestamp = link.targetTimestamp

        // Screen-plane gravity. Portrait mapping: +x right, +y down.
        // No motion data (simulator, reduced hardware) = plain downward pull.
        var ax: CGFloat = 0
        var ay: CGFloat = 1
        if let gravity = motion.deviceMotion?.gravity {
            ax = CGFloat(gravity.x)
            ay = CGFloat(-gravity.y)
        }

        // Gentle constants: modest pull, soft bounces, breathing room.
        let pull: CGFloat = 650
        let restitution: CGFloat = 0.45
        let spacing: CGFloat = 7

        for index in bodies.indices {
            var body = bodies[index]
            body.vx += ax * pull * dt
            body.vy += ay * pull * dt
            body.vx *= 0.99
            body.vy *= 0.99
            // Roll gently with horizontal travel.
            body.rotation += body.vx * dt * 0.9
            // Speed cap keeps a hard shake from turning into pinball.
            let speed = hypot(body.vx, body.vy)
            if speed > 700 {
                body.vx *= 700 / speed
                body.vy *= 700 / speed
            }
            bodies[index] = body
        }

        // Equal-mass collisions with padded radii so settled doodles keep
        // a little personal space instead of piling into one heap.
        for i in bodies.indices {
            for j in bodies.indices where j > i {
                let dx = bodies[j].x - bodies[i].x
                let dy = bodies[j].y - bodies[i].y
                let distance = max(hypot(dx, dy), 0.0001)
                let minimum = bodies[i].radius + bodies[j].radius + spacing
                guard distance < minimum else { continue }

                let nx = dx / distance
                let ny = dy / distance
                let overlap = (minimum - distance) / 2
                bodies[i].x -= nx * overlap
                bodies[i].y -= ny * overlap
                bodies[j].x += nx * overlap
                bodies[j].y += ny * overlap

                let relative = (bodies[i].vx - bodies[j].vx) * nx + (bodies[i].vy - bodies[j].vy) * ny
                if relative > 0 {
                    let bounce = relative * restitution
                    bodies[i].vx -= bounce * nx
                    bodies[i].vy -= bounce * ny
                    bodies[j].vx += bounce * nx
                    bodies[j].vy += bounce * ny
                }
            }
        }

        for index in bodies.indices {
            var body = bodies[index]
            body.x += body.vx * dt
            body.y += body.vy * dt

            // Walls, floor, and the lowest inbox row as the ceiling.
            if body.x < body.radius {
                body.x = body.radius
                body.vx = abs(body.vx) * restitution
            } else if body.x > size.width - body.radius {
                body.x = size.width - body.radius
                body.vx = -abs(body.vx) * restitution
            }
            if body.y < ceiling + body.radius {
                body.y = ceiling + body.radius
                body.vy = abs(body.vy) * restitution
            } else if body.y > size.height - body.radius {
                body.y = size.height - body.radius
                body.vy = -abs(body.vy) * restitution
                // Resting on the floor: bleed off sideways drift so they
                // come to a proper stop.
                body.vx *= 0.94
            }

            bodies[index] = body
        }

        publish()
    }

    private func publish() {
        placed = bodies.enumerated().map { index, body in
            Placed(id: index, spec: body.spec, x: body.x, y: body.y, rotation: body.rotation)
        }
    }
}

/// The doodle field overlay for the inbox tray. Pass the bottom edge of the
/// lowest inbox row (in the tray's coordinate space) as `ceiling`.
struct DoodleWatermark: View {
    var ceiling: CGFloat = 0

    @State private var model = DoodleFieldModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(model.placed) { item in
                    DoodleGlyph(spec: item.spec)
                        .rotationEffect(.degrees(item.rotation))
                        .position(x: item.x, y: item.y)
                }
            }
            .opacity(model.hidden ? 0 : 1)
            .onAppear {
                model.size = geometry.size
                model.ceiling = ceiling
                if !reduceMotion { model.start() }
            }
            .onDisappear { model.stop() }
            .onChange(of: geometry.size) { _, newSize in model.size = newSize }
            .onChange(of: ceiling) { _, newCeiling in model.ceiling = newCeiling }
        }
        .allowsHitTesting(false)
    }
}

/// Minimal SVG path-data parser: absolute M/L/Q/C/Z, which is all the
/// doodles use. Coordinates land in the spec's natural point space.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var numbers: [CGFloat] = []
        var command: Character = " "
        var numberText = ""

        func flushNumber() {
            if let value = Double(numberText) {
                numbers.append(CGFloat(value))
            }
            numberText = ""
        }

        func apply() {
            switch command {
            case "M" where numbers.count >= 2:
                path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "L" where numbers.count >= 2:
                path.addLine(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "Q" where numbers.count >= 4:
                path.addQuadCurve(
                    to: CGPoint(x: numbers[2], y: numbers[3]),
                    control: CGPoint(x: numbers[0], y: numbers[1])
                )
            case "C" where numbers.count >= 6:
                path.addCurve(
                    to: CGPoint(x: numbers[4], y: numbers[5]),
                    control1: CGPoint(x: numbers[0], y: numbers[1]),
                    control2: CGPoint(x: numbers[2], y: numbers[3])
                )
            case "Z":
                path.closeSubpath()
            default:
                break
            }
            numbers = []
        }

        for character in d {
            switch character {
            case "M", "L", "Q", "C", "Z":
                flushNumber()
                apply()
                command = character
                if character == "Z" { apply() }
            case " ", ",":
                flushNumber()
                // Polyline shorthand: extra coordinate pairs after a command
                // repeat it (only L-style repeats appear in these paths).
                if command == "M", numbers.count == 2 { apply(); command = "L" }
                else if command == "L", numbers.count == 2 { apply() }
                else if command == "Q", numbers.count == 4 { apply() }
                else if command == "C", numbers.count == 6 { apply() }
            default:
                numberText.append(character)
            }
        }
        flushNumber()
        apply()
        return path
    }
}
