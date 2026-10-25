import SwiftUI

struct ChatHistoryView: View {
    @ObservedObject var model: NearbySessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.chatSnapshot.history.isEmpty {
                        ContentUnavailableView("No saved chats", systemImage: "clock.arrow.circlepath",
                                               description: Text("Chats you join will appear here."))
                    }
                    ForEach(model.chatSnapshot.history) { entry in
                        Button {
                            open(entry.chat)
                        } label: {
                            ChatHistoryRow(entry: entry, isLive: isLive(entry.id))
                        }
                        .buttonStyle(.plain)
                    }
                    if let error { Text(error).foregroundStyle(Color.loreOrange) }
                }.padding(20)
            }
            .background(Color.loreInk)
            .navigationTitle("Chat history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func isLive(_ id: UUID) -> Bool {
        model.liveChats.contains(where: { $0.id == id })
    }

    private func open(_ chat: Chat) {
        Task {
            do {
                try await model.previewChat(chat)
                dismiss()
            } catch { self.error = "Unable to open saved history." }
        }
    }
}

private struct ChatHistoryRow: View {
    let entry: ChatHistoryEntry
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.chat.title).font(.headline).foregroundStyle(Color.white)
            Text(isLive ? "Live nearby" : "Inactive nearby")
                .font(.caption2).foregroundStyle(Color.loreGreen)
            Text(entry.lastMessage?.text ?? "No messages yet")
                .font(.subheadline).foregroundStyle(Color.white.opacity(0.5)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
    }
}
