import Foundation
import SwiftData

@Model
final class Anniversary: Identifiable {
    var id: UUID = UUID()
    var roomID: String = ""
    var title: String = ""
    var date: Date = Date()
    var ckRecordName: String?

    init(id: UUID = UUID(), roomID: String, title: String, date: Date, ckRecordName: String? = nil) {
        self.id = id
        self.roomID = roomID
        self.title = title
        self.date = date
        self.ckRecordName = ckRecordName
    }
}