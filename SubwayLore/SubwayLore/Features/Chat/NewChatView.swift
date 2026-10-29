import SwiftUI

struct NewChatView: View {
    @ObservedObject var model: NearbySessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label("NEW CHAT", systemImage: "plus.bubble.fill")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.loreBlue)
                Text("Start a conversation.")
                    .font(.system(size: 27, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                TextField("Chat name", text: $title)
                    .accessibilityIdentifier("chatTitle")
                    .padding(16)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
                Text("Nearby riders can join automatically and read the chat’s saved history.")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                if let error { Text(error).font(.caption).foregroundStyle(Color.loreOrange) }
                Button {
                    isCreating = true
                    Task {
                        do {
                            try await model.createChat(title: title)
                            dismiss()
                        } catch {
                            self.error = "Could not create chat. Use a name up to 80 bytes and try again."
                        }
                        isCreating = false
                    }
                } label: {
                    Text(isCreating ? "Creating…" : "Create chat")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.loreInk)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.loreGreen, in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(isCreating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.utf8.count > 80)
                .accessibilityIdentifier("createChat")
                Button("Cancel") { dismiss() }.frame(maxWidth: .infinity).disabled(isCreating)
            }
            .padding(24)
            .padding(.top, 12)
        }
        .background(Color.loreInk)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isCreating)
    }
}
