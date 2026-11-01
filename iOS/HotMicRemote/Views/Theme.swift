import SwiftUI

/// blue gum's warm light look: paper background, flame accent, big thumb-sized buttons.
extension Color {
    static let flame = Color(red: 1.0, green: 0.42, blue: 0.10)
    static let ember = Color(red: 0.93, green: 0.25, blue: 0.08)
    static let paper = Color(red: 0.99, green: 0.97, blue: 0.94)
    static let card = Color.white
    static let ink = Color(red: 0.14, green: 0.16, blue: 0.18)
    static let inkSoft = Color(red: 0.42, green: 0.44, blue: 0.47)
}

struct BigButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(filled ? Color.white : Color.flame)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(filled ? Color.flame : Color.flame.opacity(0.12))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// White rounded panel used for groups of content.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.card))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

/// The mic level, breathing gently so it reads as "listening" even in silence.
struct LevelRing: View {
    var level: Float

    var body: some View {
        let l = CGFloat(level)
        ZStack {
            Circle()
                .fill(Color.flame.opacity(0.10))
                .scaleEffect(0.72 + l * 0.28)
            Circle()
                .stroke(Color.flame.opacity(0.35 + Double(l) * 0.65), lineWidth: 6 + l * 10)
                .scaleEffect(0.62 + l * 0.30)
            Circle()
                .fill(LinearGradient(colors: [.flame, .ember], startPoint: .top, endPoint: .bottom))
                .frame(width: 104, height: 104)
            Image(systemName: "mic.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 240, height: 240)
        .animation(.easeOut(duration: 0.12), value: level)
        .phaseAnimator([false, true]) { view, breathe in
            view.scaleEffect(breathe ? 1.03 : 0.97)
        } animation: { _ in .easeInOut(duration: 1.6) }
        .accessibilityLabel("Microphone level")
    }
}
