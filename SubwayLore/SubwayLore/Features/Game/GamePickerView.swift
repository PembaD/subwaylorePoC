import SwiftUI

struct GamePickerView: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("NEW GAME", systemImage: "bolt.fill")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1).foregroundStyle(Color.loreOrange)
            Text("A little friendly competition.")
                .font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(.white)
            Button {
                guard !isCreating else { return }
                isCreating = true
                Task {
                    do {
                        try await model.createGame()
                        dismiss()
                    } catch {
                        errorMessage = "Game could not be opened. Please try again."
                        isCreating = false
                    }
                }
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "stopwatch.fill")
                        .font(.system(size: 28, weight: .bold)).foregroundStyle(Color.loreOrange)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Time |t!").font(.system(size: 22, weight: .black, design: .rounded)).foregroundStyle(.white)
                        Text("Watch the timer. Stop exactly at the target: 1–6 seconds.")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.leading)
                        Text(isCreating ? "Creating…" : "2–8 players · Creator starts")
                            .font(.caption.bold()).foregroundStyle(Color.loreOrange)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").foregroundStyle(.white)
                }
                .padding(20)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .disabled(isCreating)
            .accessibilityIdentifier("chooseTimeIt")
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(Color.loreOrange)
            }
            Button("Cancel") { dismiss() }
                .font(.subheadline.bold()).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, minHeight: 44).disabled(isCreating)
        }
        .padding(24).padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.loreInk).preferredColorScheme(.dark)
        .interactiveDismissDisabled(isCreating)
    }
}
