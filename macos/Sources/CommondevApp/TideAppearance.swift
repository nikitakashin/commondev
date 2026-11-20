import AppKit
import SwiftUI

enum TideAppearance {
    static let mint = 0x246C59
    static let swatches = [
        ("Мята", mint), ("Океан", 0x1B73A6), ("Ирис", 0x7855B0),
        ("Роза", 0xAC4E73), ("Янтарь", 0xA86020)
    ]

    static func sample(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    static func packed(_ color: Color) -> Int? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return (Int((rgb.redComponent * 255).rounded()) << 16)
            | (Int((rgb.greenComponent * 255).rounded()) << 8)
            | Int((rgb.blueComponent * 255).rounded())
    }

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func accent(_ rgb: Int) -> Color {
        let color = sample(rgb)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        let light = NSColor(hue: hue, saturation: saturation,
                            brightness: min(brightness, 0.76), alpha: 1)
        let dark = NSColor(hue: hue, saturation: saturation * 0.65,
                           brightness: max(0.80, brightness), alpha: 1)
        return adaptive(light: light, dark: dark)
    }

    static let canvas = adaptive(light: sample(0xF8FAF9), dark: sample(0x191F20))
    static let card = adaptive(light: .white, dark: sample(0x242B2B))
}

struct TideMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.28)
                    .fill(Color.accentColor.gradient)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.28).fill(.black.opacity(0.24)))
            }
            .accessibilityHidden(true)
    }
}

struct TideAccentPicker: View {
    @AppStorage("accentRGB") private var accent = TideAppearance.mint

    var body: some View {
        HStack(spacing: 7) {
                Text("Акцентный цвет")
                Spacer()
                ForEach(TideAppearance.swatches, id: \.1) { name, value in
                    Button { accent = value } label: {
                        Circle().fill(Color(nsColor: TideAppearance.sample(value)))
                            .frame(width: 23, height: 23)
                            .overlay {
                                if accent == value {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain).help(name).accessibilityLabel(name)
                    .accessibilityAddTraits(accent == value ? .isSelected : [])
                }
                ColorPicker("Свой цвет", selection: Binding(
                    get: { Color(nsColor: TideAppearance.sample(accent)) },
                    set: { if let value = TideAppearance.packed($0) { accent = value } }
                ), supportsOpacity: false)
                .labelsHidden().help("Выбрать свой цвет").accessibilityLabel("Свой акцентный цвет")
        }
        .accessibilityElement(children: .contain)
    }
}

/// This layer samples the desktop and other windows. The chat canvas stays opaque.
struct DesktopSidebarMaterial: NSViewRepresentable {
    final class Surface: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
        }
    }

    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        if #available(macOS 26, *) {
            // Keep the desktop visible beneath the diffusing glass surface.
            view.alphaValue = 0.42
        } else {
            view.alphaValue = 0.78
        }
        return view
    }

    func updateNSView(_ view: Surface, context: Context) {}
}

struct TideSidebarSurface: View {
    private let diffusionScale: CGFloat = 2.5
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                TideAppearance.canvas
            } else {
                DesktopSidebarMaterial()
                if #available(macOS 26, *) {
                    GeometryReader { geometry in
                        // Scale just the glass so its diffusion spans more screen points.
                        Color.clear
                            .frame(width: geometry.size.width / diffusionScale,
                                   height: geometry.size.height / diffusionScale)
                            .glassEffect(.regular.tint(Color.accentColor.opacity(0.15)), in: Rectangle())
                            .scaleEffect(diffusionScale, anchor: .topLeading)
                    }
                    .clipped()
                } else {
                    Color.accentColor.opacity(0.08)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct TideComposerGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if reduceTransparency {
            content.background(TideAppearance.card, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.12)))
        } else if #available(macOS 26, *) {
            content
                .background(TideAppearance.canvas.opacity(0.22), in: shape)
                .glassEffect(.clear.tint(Color.accentColor.opacity(0.09)), in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.09)))
        }
    }
}

extension View {
    @ViewBuilder
    func transparentTideWindow() -> some View {
        if #available(macOS 15, *) {
            containerBackground(.clear, for: .window)
        } else {
            self
        }
    }

    @ViewBuilder
    func tideActionStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}
