import Foundation

struct SavedSpace: Codable, Identifiable {
    let id: UUID
    var name: String
    let roomId: Int
    let createdAt: Date

    init(id: UUID = UUID(), name: String = "내 공간", roomId: Int, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.roomId = roomId
        self.createdAt = createdAt
    }

    var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "yy.MM.dd"
        return f.string(from: createdAt)
    }
}
