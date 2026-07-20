import SwiftUI
import CoreText

/// The CPD Dump design language: paper background, 2px ink borders,
/// hard offset shadows, slight tilts, rubber-stamp logo, Caveat scribbles.
enum PaperInk {
    // MARK: Colours (mirrors the web app's CSS custom properties)
    static let paper = Color(hex: 0xFAF9F6)
    static let paperAlt = Color(hex: 0xF5F3EE)
    static let ink = Color(hex: 0x1C1917)
    static let brand = Color(hex: 0xF4590C)
    static let tint = Color(hex: 0xFDE8DC)
    static let brandDark = Color(hex: 0xC2410C)
    static let pale = Color(hex: 0xFFF7F2)
    static let catBlue = Color(hex: 0x3F8FD2)
    static let catGreen = Color(hex: 0x2F9E64)
    static let catPurple = Color(hex: 0x9A6FD0)
    static let stone400 = Color(hex: 0xA8A29E)
    static let stone500 = Color(hex: 0x78716C)
    static let stone600 = Color(hex: 0x57534E)

    // MARK: Fonts
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Instrument Sans", size: size).weight(weight)
    }

    /// Headings: Bricolage Grotesque 800. Pair with `.tracking(size * -0.03)`
    /// (or use `Text.display(_:)`) per the brand spec.
    static func display(_ size: CGFloat) -> Font {
        .custom("Bricolage Grotesque", size: size).weight(.heavy)
    }

    /// Button labels: Bricolage Grotesque 600–700.
    static func button(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("Bricolage Grotesque", size: size).weight(weight)
    }

    static func hand(_ size: CGFloat) -> Font {
        .custom("Caveat", size: size).weight(.medium)
    }

    /// Registers the bundled variable fonts. Call once at launch.
    static func registerFonts() {
        for file in ["InstrumentSans", "BricolageGrotesque", "Caveat"] {
            guard let url = Bundle.main.url(forResource: file, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Text {
    /// Brand heading: Bricolage Grotesque 800 with -0.03em tracking.
    func display(_ size: CGFloat) -> Text {
        font(PaperInk.display(size)).kerning(size * -0.03)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Parses server-provided colour strings like "#3f8fd2".
    init(hexString: String, fallback: Color = PaperInk.stone500) {
        var cleaned = hexString.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = fallback
            return
        }
        self.init(hex: value)
    }
}

// MARK: - Modifiers

/// The hard offset "sticker" shadow — a zero-radius drop shadow.
struct StickerShadow: ViewModifier {
    var offset: CGFloat = 3
    var opacity: Double = 0.14

    func body(content: Content) -> some View {
        content.shadow(color: PaperInk.ink.opacity(opacity), radius: 0, x: offset, y: offset)
    }
}

/// The slight paper-scrap rotation.
struct Tilt: ViewModifier {
    var degrees: Double

    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(degrees))
    }
}

extension View {
    func stickerShadow(offset: CGFloat = 3, opacity: Double = 0.14) -> some View {
        modifier(StickerShadow(offset: offset, opacity: opacity))
    }

    func tilt(_ degrees: Double) -> some View {
        modifier(Tilt(degrees: degrees))
    }

    /// Deterministic small tilt derived from a stable id, alternating like the web's r1–r5 classes.
    func rowTilt(seed: Int) -> some View {
        tilt([-0.4, 0.3, -0.2, 0.45, -0.35][abs(seed) % 5])
    }
}

// MARK: - Components

/// The typographic wordmark — "cpd dump." with the orange full stop.
struct Wordmark: View {
    var size: CGFloat = 20
    /// The tiny "d." monogram for cramped headers.
    var compact = false

    var body: some View {
        Text("\(Text(compact ? "d" : "cpd dump"))\(Text(".").foregroundColor(PaperInk.brand))")
            .font(PaperInk.display(size))
            .kerning(size * -0.03)
            .foregroundStyle(PaperInk.ink)
    }
}

/// The 4-point diamond sparkle that marks everything AI.
struct Sparkle: View {
    var size: CGFloat = 14
    var color = PaperInk.brand

    var body: some View {
        SparkleShape()
            .fill(color)
            .frame(width: size, height: size)
    }
}

struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Brand SVG: M10 1 L12.2 7.8 L19 10 L12.2 12.2 L10 19 L7.8 12.2 L1 10 L7.8 7.8 Z (viewBox 20)
        let points: [(CGFloat, CGFloat)] = [
            (10, 1), (12.2, 7.8), (19, 10), (12.2, 12.2), (10, 19), (7.8, 12.2), (1, 10), (7.8, 7.8),
        ]
        var path = Path()
        let scaleX = rect.width / 20
        let scaleY = rect.height / 20
        path.move(to: CGPoint(x: points[0].0 * scaleX, y: points[0].1 * scaleY))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.0 * scaleX, y: point.1 * scaleY))
        }
        path.closeSubpath()
        return path
    }
}

/// Bordered ink button — the "Dump it" / "Approve" style. Labels in
/// Bricolage Grotesque; primary gets the hard 4pt shadow and -1° tilt,
/// secondary sits flat with a +0.8° tilt.
struct InkButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PaperInk.button(15.5, weight: prominent ? .bold : .semibold))
            .foregroundStyle(prominent ? .white : PaperInk.ink)
            .padding(.horizontal, prominent ? 26 : 22)
            .padding(.vertical, 13)
            .background(prominent ? PaperInk.brand : .white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(PaperInk.ink, lineWidth: 2))
            .stickerShadow(offset: prominent ? (configuration.isPressed ? 2 : 4) : 0, opacity: prominent ? 1 : 0)
            .offset(x: configuration.isPressed ? 2 : 0, y: configuration.isPressed ? 2 : 0)
            .tilt(prominent ? -1 : 0.8)
    }
}

/// Small uppercase category chip (tint background).
struct Chip: View {
    var text: String
    var background = PaperInk.tint
    var foreground = PaperInk.brandDark

    var body: some View {
        Text(text)
            .font(PaperInk.sans(9, weight: .heavy))
            .textCase(.uppercase)
            .kerning(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
    }
}

/// Bordered "Review" pill.
struct Pill: View {
    var text: String

    var body: some View {
        Text(text)
            .font(PaperInk.sans(11, weight: .heavy))
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(.white)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(PaperInk.ink, lineWidth: 1.5))
    }
}

/// Uppercase field label.
struct FieldLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(PaperInk.sans(10, weight: .heavy))
            .textCase(.uppercase)
            .kerning(0.8)
            .foregroundStyle(PaperInk.stone500)
    }
}

/// The hand-drawn curved arrow that points from the tray label into the pile
/// (traced from the web's inline SVG: viewBox 0 0 32 44).
struct ScribbleArrow: View {
    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / 32
            let scaleY = size.height / 44
            var curve = Path()
            curve.move(to: CGPoint(x: 3 * scaleX, y: 8 * scaleY))
            curve.addCurve(
                to: CGPoint(x: 22 * scaleX, y: 36 * scaleY),
                control1: CGPoint(x: 18 * scaleX, y: 1 * scaleY),
                control2: CGPoint(x: 30 * scaleX, y: 13 * scaleY)
            )
            var head = Path()
            head.move(to: CGPoint(x: 22 * scaleX, y: 36 * scaleY))
            head.addLine(to: CGPoint(x: 19.5 * scaleX, y: 27.5 * scaleY))
            head.move(to: CGPoint(x: 22 * scaleX, y: 36 * scaleY))
            head.addLine(to: CGPoint(x: 30.5 * scaleX, y: 32 * scaleY))

            let stroke = StrokeStyle(lineWidth: 2.2, lineCap: .round)
            context.stroke(curve, with: .color(PaperInk.brandDark), style: stroke)
            context.stroke(head, with: .color(PaperInk.brandDark), style: stroke)
        }
        .frame(width: 32, height: 44)
    }
}

/// The dashed-border tray container with inner shadow.
struct Tray<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white)
                    .shadow(color: PaperInk.ink.opacity(0.10), radius: 5, x: 3, y: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(PaperInk.stone400, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            )
    }
}
