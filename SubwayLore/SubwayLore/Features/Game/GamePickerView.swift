import SwiftUI

struct GamePickerView: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pick your game.")
                    .font(.system(size: 28, weight: .black, design: .rounded)).foregroundStyle(.white)
                Text("2–8 riders · You start the fun")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 4)
                ForEach(GameKind.allCases, id: \.self) { kind in gameButton(kind) }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(Color.loreOrange)
                }
                Button("Cancel") { dismiss() }
                    .font(.subheadline.bold()).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: 44).disabled(isCreating)
            }
            .padding(24).padding(.top, 12)
        }
        .background(Color.loreInk).preferredColorScheme(.dark)
        .interactiveDismissDisabled(isCreating)
    }

    private func gameButton(_ kind: GameKind) -> some View {
        let accent: Color = kind == .timeIt ? .loreOrange : .loreGreen
        return Button {
            guard !isCreating else { return }
            isCreating = true
            Task {
                do {
                    try await model.createGame(kind: kind)
                    dismiss()
                } catch {
                    errorMessage = "Game could not be opened. Please try again."
                    isCreating = false
                }
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 19)
                        .fill(LinearGradient(colors: [accent.opacity(0.35), accent.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: kind == .timeIt ? "stopwatch.fill" : "tram.fill")
                        .font(.system(size: 30, weight: .bold)).rotationEffect(.degrees(kind == .timeIt ? -12 : 0))
                    Image(systemName: kind == .timeIt ? "sparkle" : "questionmark.bubble.fill")
                        .font(.system(size: 14, weight: .black)).offset(x: 21, y: -22)
                }
                .foregroundStyle(accent).frame(width: 62, height: 62).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title).font(.system(size: 20, weight: .black, design: .rounded)).foregroundStyle(.white)
                    Text(kind == .timeIt ? "Nail the second." : "Think you know NYC?")
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.65))
                    Text(isCreating ? "Opening…" : (kind == .timeIt ? "1–6 seconds" : "5 questions · A–D"))
                        .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(accent)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent).frame(width: 26, height: 26).background(accent.opacity(0.12), in: Circle())
            }
            .padding(14)
            .background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(accent.opacity(0.2)) }
        }
        .buttonStyle(.plain).disabled(isCreating)
        .accessibilityIdentifier(kind == .timeIt ? "chooseTimeIt" : "chooseSubwayTrivia")
    }
}
