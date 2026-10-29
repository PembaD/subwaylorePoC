import Foundation

enum ChatHistorySync {
    static let pageSize = 100

    static func inventoryPages(_ messages: [ChatMessage], chatID: UUID) -> [HistoryInventory] {
        let ids = messages.filter { $0.chatID == chatID }.map(\.id)
        return stride(from: 0, to: ids.count, by: pageSize).map { offset in
            HistoryInventory(chatID: chatID, requestID: UUID(),
                             messageIDs: Array(ids[offset..<min(offset + pageSize, ids.count)]))
        }
    }

    static func missingIDs(_ inventory: HistoryInventory, knownMessages: [ChatMessage]) -> [UUID] {
        let known = Set(knownMessages.filter { $0.chatID == inventory.chatID }.map(\.id))
        var requested = Set<UUID>()
        return inventory.messageIDs.filter { !known.contains($0) && requested.insert($0).inserted }
    }
}
