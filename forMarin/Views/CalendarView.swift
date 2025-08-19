import SwiftUI

// MARK: - Calendar With Images (Month View)
struct CalendarWithImagesView: View {
    let imagesByDate: [Date: [Message]]
    let anniversaries: [Anniversary]
    let onImageTap: ([UIImage], Int) -> Void
    
    @State private var selectedDate = Date()
    @State private var currentDisplayMonth = Date()
    @State private var scrollOffset: CGFloat = 0
    @State private var shouldScrollToToday = false

    
    // 計算された週の配列を保持
    @State private var allWeeks: [(weekStartDate: Date, weeks: [[Date?]])] = []
    

    
    // パフォーマンス改善用キャッシュ
    @State private var cachedImagesByDate: [Date: [UIImage]] = [:]
    @State private var cachedAnniversariesByDate: [Date: [Anniversary]] = [:]
    @State private var isDataLoaded = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
        VStack(spacing: 0) {
                    // 固定曜日ヘッダー（最上部）
                    HStack(spacing: 2) {
                ForEach(Calendar.current.shortWeekdaySymbols, id: \.self) { day in
                    Text(day)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .zIndex(2)
                    
                    // メインカレンダー
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(allWeeks.enumerated()), id: \.offset) { index, weekData in
                                    WeekRowView(
                                        week: weekData.weeks.first ?? [],
                                        selectedDate: $selectedDate,
                                        cachedImages: cachedImagesByDate,
                                        cachedAnniversaries: cachedAnniversariesByDate,
                                        onImageTap: onImageTap,
                                        currentDisplayMonth: currentDisplayMonth
                                    )
                                    .background(
                                        GeometryReader { weekGeometry in
                                            Color.clear
                                                .onChange(of: weekGeometry.frame(in: .global).midY) { _, yPosition in
                                                    updateCurrentMonthFromWeekPosition(
                                                        weekIndex: index,
                                                        yPosition: yPosition,
                                                        geometry: geometry
                                                    )
                                                }
                                        }
                                    )
                                    .id("week-\(index)")
                                }
                            }
                            .coordinateSpace(name: "calendar")
                        }
                        .onAppear {
                            if !isDataLoaded {
                                loadCalendarData()
                                generateWeeks()
                                isDataLoaded = true
                                
                                // 今日の週を画面中央に表示
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    if let currentWeekIndex = findCurrentWeekIndex() {
                                        proxy.scrollTo("week-\(currentWeekIndex)", anchor: UnitPoint.center)
                                        selectedDate = Date()
                                    }
                                }
                            }
                        }
                        .onChange(of: shouldScrollToToday) { _, newValue in
                            if newValue {
                                if let todayWeekIndex = findCurrentWeekIndex() {
                                    withAnimation(.easeInOut(duration: 0.8)) {
                                        proxy.scrollTo("week-\(todayWeekIndex)", anchor: UnitPoint.center)
                                    }
                                    selectedDate = Date()
                                }
                                shouldScrollToToday = false
                            }
                        }
                        .onChange(of: imagesByDate.count) { _, _ in
                            // 画像データが変更された時にキャッシュを更新
                            loadCalendarData()
                        }
                        .onChange(of: anniversaries.count) { _, _ in
                            // 記念日が変更された時にキャッシュを更新
                            loadCalendarData()
                        }
                    }
                }
                
                // フローティング年月表示（左上）
                HStack {
                    Button {
                        scrollToToday()
                    } label: {
                        Text(currentMonthString)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                }
                .padding(.top, 54) // 曜日ヘッダーの高さに合わせて調整
                .padding(.horizontal, 8)
                .zIndex(1)
            }
        }
        .clipped()
    }
    
    // MARK: - データ読み込み
    
    private func loadCalendarData() {
        log("Loading calendar data...", category: "CalendarWithImagesView")
        
        // 画像データをキャッシュ
        var imagesCache: [Date: [UIImage]] = [:]
        for (date, messages) in imagesByDate {
            let images: [UIImage] = messages.compactMap { message -> UIImage? in
                guard let assetPath = message.assetPath,
                      FileManager.default.fileExists(atPath: assetPath) else { return nil }
                return UIImage(contentsOfFile: assetPath)
            }
            if !images.isEmpty {
                imagesCache[date] = images
            }
        }
        cachedImagesByDate = imagesCache
        
        // 記念日データをキャッシュ
        var anniversariesCache: [Date: [Anniversary]] = [:]
        let calendar = Calendar.current
        let today = Date()
        
        // 過去2年〜未来2年の範囲で記念日を計算（パフォーマンス考慮）
        let startDate = calendar.date(byAdding: .year, value: -2, to: today) ?? today
        let endDate = calendar.date(byAdding: .year, value: 2, to: today) ?? today
        
        var currentDate = startDate
        while currentDate <= endDate {
            let dayKey = calendar.startOfDay(for: currentDate)
            
            for anniversary in anniversaries {
                if shouldShowAnniversary(anniversary, on: currentDate) {
                    anniversariesCache[dayKey, default: []].append(anniversary)
                }
            }
            
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }
        cachedAnniversariesByDate = anniversariesCache
        
        log("Cached \(imagesCache.count) days with images, \(anniversariesCache.count) days with anniversaries", category: "CalendarWithImagesView")
    }
    
    private func shouldShowAnniversary(_ anniversary: Anniversary, on date: Date) -> Bool {
        let calendar = Calendar.current
        
        // 元の日付と比較
        if calendar.isDate(anniversary.date, inSameDayAs: date) {
            return true
        }
        
        // 繰り返し設定がある場合の判定
        switch anniversary.repeatType {
        case .none:
            return false
        case .yearly:
            let originalMonth = calendar.component(.month, from: anniversary.date)
            let originalDay = calendar.component(.day, from: anniversary.date)
            let targetMonth = calendar.component(.month, from: date)
            let targetDay = calendar.component(.day, from: date)
            return originalMonth == targetMonth && originalDay == targetDay
        case .monthly:
            let originalDay = calendar.component(.day, from: anniversary.date)
            let targetDay = calendar.component(.day, from: date)
            return originalDay == targetDay
        }
    }
    
    // MARK: - Helper Functions
    private var currentMonthString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年 M月"
        return formatter.string(from: currentDisplayMonth)
    }
    
    private func monthYearString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月"
        return formatter.string(from: date)
    }
    
    private func generateWeeks() {
        let calendar = Calendar.current
        let currentDate = Date()
        
        // 過去2年〜未来2年の週を生成
        guard let startDate = calendar.date(byAdding: .year, value: -2, to: currentDate),
              let endDate = calendar.date(byAdding: .year, value: 2, to: currentDate) else { return }
        
        var weeks: [(weekStartDate: Date, weeks: [[Date?]])] = []
        var currentWeek = startDate
        
        // 最初の週の開始日を日曜日に調整
        let weekday = calendar.component(.weekday, from: currentWeek)
        if let adjustedStart = calendar.date(byAdding: .day, value: -(weekday - 1), to: currentWeek) {
            currentWeek = adjustedStart
        }
        
        while currentWeek <= endDate {
            // 一週間分の日付を生成
            var weekDates: [Date?] = []
            for dayOffset in 0..<7 {
                if let date = calendar.date(byAdding: .day, value: dayOffset, to: currentWeek) {
                    weekDates.append(date)
                }
            }
            
            weeks.append((weekStartDate: currentWeek, weeks: [weekDates]))
            
            // 次の週へ
            if let nextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: currentWeek) {
                currentWeek = nextWeek
            } else {
                break
            }
        }
        
        allWeeks = weeks
    }
    
    private func findCurrentWeekIndex() -> Int? {
        let today = Date()
        
        return allWeeks.firstIndex { weekData in
            if let firstDate = weekData.weeks.first?.compactMap({ $0 }).first,
               let lastDate = weekData.weeks.first?.compactMap({ $0 }).last {
                return firstDate <= today && today <= lastDate
            }
            return false
        }
    }
    
    
    
    private func updateCurrentMonthFromWeekPosition(weekIndex: Int, yPosition: CGFloat, geometry: GeometryProxy) {
        let screenHeight = geometry.size.height
        let targetPosition = screenHeight * 0.65 // 画面の65%の位置で判定
        
        // 判定位置付近の週のみ処理（パフォーマンス向上）
        guard abs(yPosition - targetPosition) < screenHeight * 0.3 else { return }
        
        // 週の中央の日付を取得
        guard weekIndex < allWeeks.count,
              let weekDates = allWeeks[weekIndex].weeks.first else { return }
        
        let validDates = weekDates.compactMap({ $0 })
        let centerDate = validDates.count > 3 ? validDates[3] : validDates.first
        guard let centerDate = centerDate else { return }
        
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: centerDate)?.start ?? centerDate
        
        if !calendar.isDate(currentDisplayMonth, equalTo: monthStart, toGranularity: .month) {
            currentDisplayMonth = monthStart
        }
    }
    
    
    private func hasAnniversary(on date: Date) -> Bool {
        anniversaries.contains { anniversary in
            // 元の日付と比較
            if isSameDay(anniversary.date, date) {
                return true
            }
            
            // 繰り返し設定がある場合の判定
            switch anniversary.repeatType {
            case .none:
                return false
            case .yearly:
                let calendar = Calendar.current
                let originalMonth = calendar.component(.month, from: anniversary.date)
                let originalDay = calendar.component(.day, from: anniversary.date)
                let targetMonth = calendar.component(.month, from: date)
                let targetDay = calendar.component(.day, from: date)
                return originalMonth == targetMonth && originalDay == targetDay
            case .monthly:
                let calendar = Calendar.current
                let originalDay = calendar.component(.day, from: anniversary.date)
                let targetDay = calendar.component(.day, from: date)
                return originalDay == targetDay
            }
        }
    }
    
    private func getImagesForDate(_ date: Date) -> [UIImage] {
        let dayKey = Calendar.current.startOfDay(for: date)
        guard let messages = imagesByDate[dayKey] else { return [] }
        
        return messages.compactMap { message in
            guard let assetPath = message.assetPath,
                  FileManager.default.fileExists(atPath: assetPath) else { return nil }
            return UIImage(contentsOfFile: assetPath)
        }.shuffled().prefix(3).map { $0 }
    }
    
    private func isSameDay(_ date1: Date, _ date2: Date) -> Bool {
        Calendar.current.isDate(date1, inSameDayAs: date2)
    }
    
    // 今日の日付にスクロールする関数
    private func scrollToToday() {
        shouldScrollToToday = true
    }
}

// MARK: - Week Row View
struct WeekRowView: View {
    let week: [Date?]
    @Binding var selectedDate: Date
    let cachedImages: [Date: [UIImage]]
    let cachedAnniversaries: [Date: [Anniversary]]
    let onImageTap: ([UIImage], Int) -> Void
    let currentDisplayMonth: Date
    
    var body: some View {
        // 週の日付行
        HStack(spacing: 2) {
            ForEach(Array(week.enumerated()), id: \.offset) { dayIndex, date in
                if let date = date {
                    CalendarDayWithImages(
                        date: date,
                        isSelected: isSameDay(date, selectedDate),
                        isAnniversary: hasAnniversary(on: date),
                        isToday: isSameDay(date, Date()),
                        images: getImagesForDate(date),
                        anniversaries: getAnniversariesForDate(date),
                        onTap: { selectedDate = date },
                        onImageTap: onImageTap
                    )
                    .opacity(getOpacityForDate(date))
                } else {
                    Color.clear
                        .frame(height: 120)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
    
    // 表示月以外を50%不透明にする
    private func getOpacityForDate(_ date: Date) -> Double {
        let calendar = Calendar.current
        let dateMonth = calendar.component(.month, from: date)
        let dateYear = calendar.component(.year, from: date)
        let displayMonth = calendar.component(.month, from: currentDisplayMonth)
        let displayYear = calendar.component(.year, from: currentDisplayMonth)
        
        return (dateMonth == displayMonth && dateYear == displayYear) ? 1.0 : 0.5
    }
    
    private func hasAnniversary(on date: Date) -> Bool {
        let dayKey = Calendar.current.startOfDay(for: date)
        return !(cachedAnniversaries[dayKey]?.isEmpty ?? true)
    }
    
    private func getAnniversariesForDate(_ date: Date) -> [Anniversary] {
        let dayKey = Calendar.current.startOfDay(for: date)
        return cachedAnniversaries[dayKey] ?? []
    }
    
    private func getImagesForDate(_ date: Date) -> [UIImage] {
        let dayKey = Calendar.current.startOfDay(for: date)
        return Array((cachedImages[dayKey] ?? []).shuffled().prefix(3))
    }
    
    private func isSameDay(_ date1: Date, _ date2: Date) -> Bool {
        Calendar.current.isDate(date1, inSameDayAs: date2)
    }
    
}





// MARK: - Calendar Day Cell With Images
struct CalendarDayWithImages: View {
    let date: Date
    let isSelected: Bool
    let isAnniversary: Bool
    let isToday: Bool
    let images: [UIImage]
    let anniversaries: [Anniversary]
    let onTap: () -> Void
    let onImageTap: ([UIImage], Int) -> Void
    
    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isAnniversary ? Color.pink : Color.clear, lineWidth: 2)
                )
            
            VStack(spacing: 0) {
                // Top area with date (中央配置)
                VStack(spacing: 4) {
                    Text(formatDateText(date))
                        .font(.system(size: 12, weight: isToday ? .bold : .medium))
                        .foregroundColor(isSelected ? .white : (isToday ? .accentColor : .primary))
                        .frame(maxWidth: .infinity, alignment: .center)
                    
                    if isAnniversary, let anniversaryTitle = getAnniversaryTitle(for: date) {
                        Text(anniversaryTitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.orange.gradient)
                            )
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                
                Spacer()
                
                // Image area (大幅に拡大)
                if !images.isEmpty {
                    ZStack {
                        // Background images (斜め配置)
                        if images.count > 2 {
                            Image(uiImage: images[2])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 40, height: 40)
                                .clipped()
                                .cornerRadius(6)
                                .rotationEffect(.degrees(-12))
                                .offset(x: -10, y: 6)
                                .opacity(0.7)
                        }
                        
                        if images.count > 1 {
                            Image(uiImage: images[1])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 40, height: 40)
                                .clipped()
                                .cornerRadius(6)
                                .rotationEffect(.degrees(8))
                                .offset(x: 8, y: 3)
                                .opacity(0.8)
                        }
                        
                        // Front image (最前面・大型化)
                        Image(uiImage: images[0])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 48)
                            .clipped()
                            .cornerRadius(8)
                            .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 2)
                            .onTapGesture {
                                onImageTap(images, 0)
                            }
                    }
                    .frame(height: 70) // 大幅に高さ増加
                    .padding(.bottom, 8)
                } else {
                    // Empty space for consistency
                    Spacer()
                        .frame(height: 70)
                        .padding(.bottom, 8)
                }
            }
        }
        .frame(height: 120) // セル全体の高さ維持
        .frame(maxWidth: .infinity)
        .onTapGesture(perform: onTap)
    }
    
    // 指定日の記念日タイトルを取得
    private func getAnniversaryTitle(for date: Date) -> String? {
        let matchingAnniversary = anniversaries.first { anniversary in
            // 元の日付と比較
            if isSameDay(anniversary.date, date) {
                return true
            }
            
            // 繰り返し設定がある場合の判定
            switch anniversary.repeatType {
            case .none:
                return false
            case .yearly:
                let calendar = Calendar.current
                let originalMonth = calendar.component(.month, from: anniversary.date)
                let originalDay = calendar.component(.day, from: anniversary.date)
                let targetMonth = calendar.component(.month, from: date)
                let targetDay = calendar.component(.day, from: date)
                return originalMonth == targetMonth && originalDay == targetDay
            case .monthly:
                let calendar = Calendar.current
                let originalDay = calendar.component(.day, from: anniversary.date)
                let targetDay = calendar.component(.day, from: date)
                return originalDay == targetDay
            }
        }
        
        return matchingAnniversary?.title
    }
    
    private func isSameDay(_ date1: Date, _ date2: Date) -> Bool {
        Calendar.current.isDate(date1, inSameDayAs: date2)
    }
    
    // 日付表示フォーマット（月が変わる場合は月/日、同じ月なら日のみ）
    private func formatDateText(_ date: Date) -> String {
        let calendar = Calendar.current
        let day = calendar.component(.day, from: date)
        
        // 月の1日の場合は月/日表示
        if day == 1 {
            let month = calendar.component(.month, from: date)
            return "\(month)/\(day)"
        } else {
            return "\(day)"
        }
    }
}

// MARK: - Year Calendar View
struct YearCalendarView: View {
    let imagesByDate: [Date: [Message]]
    let anniversaries: [Anniversary]
    let onImageTap: ([UIImage], Int) -> Void
    
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(yearsToShow, id: \.self) { year in
                            YearCalendarPage(
                                year: year,
                                imagesByDate: imagesByDate,
                                anniversaries: anniversaries,
                                onImageTap: onImageTap,
                                screenHeight: geometry.size.height
                            )
                            .frame(height: geometry.size.height)
                            .id("year-\(year)")
                        }
                    }
                }
                .scrollTargetBehavior(.paging)
                .onAppear {
                    proxy.scrollTo("year-\(selectedYear)", anchor: .top)
                }
            }
        }
    }
    
    // 表示する年の範囲（過去5年〜未来5年）
    private var yearsToShow: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return Array((currentYear - 5)...(currentYear + 5))
    }
}

// MARK: - Year Calendar Page
struct YearCalendarPage: View {
    let year: Int
    let imagesByDate: [Date: [Message]]
    let anniversaries: [Anniversary]
    let onImageTap: ([UIImage], Int) -> Void
    let screenHeight: CGFloat
    
    var body: some View {
        VStack(spacing: 16) {
            // Year header
            Text("\(year)年")
                .font(.title2)
                .fontWeight(.semibold)
                .frame(height: 60)
            
            // 12 months grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                ForEach(1...12, id: \.self) { month in
                    MonthGridView(
                        year: year,
                        month: month,
                        imagesByDate: imagesByDate,
                        anniversaries: anniversaries,
                        onImageTap: onImageTap
                    )
                }
            }
            .frame(maxHeight: .infinity)
            
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Month Grid for Year View
struct MonthGridView: View {
    let year: Int
    let month: Int
    let imagesByDate: [Date: [Message]]
    let anniversaries: [Anniversary]
    let onImageTap: ([UIImage], Int) -> Void
    
    var monthDate: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month)) ?? Date()
    }
    
    var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月"
        return formatter.string(from: monthDate)
    }
    
    var daysWithImages: [Date] {
        let calendar = Calendar.current
        let range = calendar.range(of: .day, in: .month, for: monthDate)!
        
        return (1...range.count).compactMap { day in
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            let dayKey = calendar.startOfDay(for: date)
            return imagesByDate[dayKey] != nil ? date : nil
        }
    }
    
    var body: some View {
        VStack(spacing: 4) {
            Text(monthName)
                .font(.caption)
                .fontWeight(.semibold)
            
            // Show up to 9 days with images in a 3x3 grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 2) {
                ForEach(Array(daysWithImages.prefix(9).enumerated()), id: \.offset) { index, date in
                    if let firstImage = getFirstImageForDate(date) {
                        Image(uiImage: firstImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 24, height: 24)
                            .clipped()
                            .cornerRadius(4)
                            .onTapGesture {
                                let images = getImagesForDate(date)
                                onImageTap(images, 0)
                            }
                    }
                }
                
                // Fill empty slots
                ForEach(daysWithImages.count..<9, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 24, height: 24)
                }
            }
        }
        .frame(height: 100)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
    
    private func getFirstImageForDate(_ date: Date) -> UIImage? {
        let dayKey = Calendar.current.startOfDay(for: date)
        guard let messages = imagesByDate[dayKey]?.first,
              let assetPath = messages.assetPath,
              FileManager.default.fileExists(atPath: assetPath) else { return nil }
        return UIImage(contentsOfFile: assetPath)
    }
    
    private func getImagesForDate(_ date: Date) -> [UIImage] {
        let dayKey = Calendar.current.startOfDay(for: date)
        guard let messages = imagesByDate[dayKey] else { return [] }
        
        return messages.compactMap { message in
            guard let assetPath = message.assetPath else { return nil }
            return UIImage(contentsOfFile: assetPath)
        }
    }
} 