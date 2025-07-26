import Foundation
import SwiftData

enum RepeatType: String, CaseIterable, Codable {
    case none = "none"        // 繰り返しなし
    case yearly = "yearly"    // 毎年
    case monthly = "monthly"  // 毎月
    
    var displayName: String {
        switch self {
        case .none: return "繰り返しなし"
        case .yearly: return "毎年"
        case .monthly: return "毎月"
        }
    }
}

@Model
final class Anniversary: Identifiable {
    var id: UUID = UUID()
    var roomID: String = ""
    var title: String = ""
    var date: Date = Date()
    var repeatType: RepeatType = RepeatType.none
    var ckRecordName: String?

    init(id: UUID = UUID(), roomID: String, title: String, date: Date, repeatType: RepeatType = .none, ckRecordName: String? = nil) {
        self.id = id
        self.roomID = roomID
        self.title = title
        self.date = date
        self.repeatType = repeatType
        self.ckRecordName = ckRecordName
    }
    
    /// 次回の記念日を計算（繰り返し設定に基づく）
    func nextOccurrence(from referenceDate: Date = Date()) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        let originalDate = calendar.startOfDay(for: date)
        
        switch repeatType {
        case .none:
            return date
            
        case .yearly:
            // 今年の記念日を計算
            let currentYear = calendar.component(.year, from: today)
            var components = calendar.dateComponents([.month, .day], from: originalDate)
            components.year = currentYear
            
            guard let thisYearDate = calendar.date(from: components) else { return date }
            
            // 今年の記念日が過ぎていれば来年
            if thisYearDate >= today {
                return thisYearDate
            } else {
                components.year = currentYear + 1
                return calendar.date(from: components) ?? date
            }
            
        case .monthly:
            // 今月の記念日を計算
            let currentYear = calendar.component(.year, from: today)
            let currentMonth = calendar.component(.month, from: today)
            let originalDay = calendar.component(.day, from: originalDate)
            
            var components = DateComponents(year: currentYear, month: currentMonth, day: originalDay)
            
            guard let thisMonthDate = calendar.date(from: components) else { return date }
            
            // 今月の記念日が過ぎていれば来月
            if thisMonthDate >= today {
                return thisMonthDate
            } else {
                components.month = currentMonth + 1
                // 年をまたぐ場合の処理
                if components.month! > 12 {
                    components.month = 1
                    components.year = currentYear + 1
                }
                return calendar.date(from: components) ?? date
            }
        }
    }
}