import SwiftUI

struct CalendarView: View {
    @State private var selectedDate = Date()
    @State private var displayedMonth = Date()
    
    // Temporary anniversary date (same as ChatView)
    private let anniversaryDate = Calendar.current.date(from: DateComponents(year: 2025, month: 2, day: 14))!
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: previousMonth) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
                
                Spacer()
                
                Text(monthYearString)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: nextMonth) {
                    Image(systemName: "chevron.right")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
            }
            .padding()
            
            // Calendar Grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 20) {
                // Day labels
                ForEach(Calendar.current.shortWeekdaySymbols, id: \.self) { day in
                    Text(day)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.semibold)
                }
                
                // Calendar days
                ForEach(daysInMonth(), id: \.self) { date in
                    if let date = date {
                        DayView(date: date, 
                               isSelected: isSameDay(date, selectedDate),
                               isAnniversary: isSameDay(date, anniversaryDate),
                               isToday: isSameDay(date, Date()))
                            .onTapGesture {
                                selectedDate = date
                            }
                    } else {
                        Color.clear
                            .frame(height: 40)
                    }
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Anniversary info
            VStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.pink)
                
                Text("記念日まで")
                    .font(.headline)
                
                Text("\(daysUntilAnniversary())日")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundColor(.accentColor)
                
                Text(anniversaryDateString)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
            .padding()
        }
        .background(Color(UIColor.systemBackground))
        .dismissKeyboardOnDrag()
    }
    
    // MARK: - Helper Views
    
    struct DayView: View {
        let date: Date
        let isSelected: Bool
        let isAnniversary: Bool
        let isToday: Bool
        
        var body: some View {
            ZStack {
                if isSelected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 40, height: 40)
                }
                
                if isAnniversary {
                    Circle()
                        .stroke(Color.pink, lineWidth: 2)
                        .frame(width: 40, height: 40)
                }
                
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 16, weight: isToday ? .bold : .regular))
                    .foregroundColor(isSelected ? .white : (isToday ? .accentColor : .primary))
            }
            .frame(height: 40)
        }
    }
    
    // MARK: - Helper Functions
    
    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年 M月"
        return formatter.string(from: displayedMonth)
    }
    
    private var anniversaryDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: anniversaryDate)
    }
    
    private func daysUntilAnniversary() -> Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: Date(), to: anniversaryDate)
        return max(0, components.day ?? 0)
    }
    
    private func previousMonth() {
        displayedMonth = Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
    }
    
    private func nextMonth() {
        displayedMonth = Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
    }
    
    private func daysInMonth() -> [Date?] {
        let calendar = Calendar.current
        let startOfMonth = calendar.dateInterval(of: .month, for: displayedMonth)?.start ?? Date()
        let range = calendar.range(of: .day, in: .month, for: startOfMonth)!
        let numberOfDays = range.count
        
        let firstWeekday = calendar.component(.weekday, from: startOfMonth) - 1
        var days: [Date?] = Array(repeating: nil, count: firstWeekday)
        
        for day in 1...numberOfDays {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: startOfMonth) {
                days.append(date)
            }
        }
        
        // Fill remaining days to complete the grid
        while days.count % 7 != 0 {
            days.append(nil)
        }
        
        return days
    }
    
    private func isSameDay(_ date1: Date, _ date2: Date) -> Bool {
        Calendar.current.isDate(date1, inSameDayAs: date2)
    }
} 