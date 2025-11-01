import SwiftUI
import PhotosUI
import SwiftData
import CloudKit

struct RoomDetailSheet: View {
    let chatRoom: ChatRoom
    let partnerAvatar: UIImage?
    let roomID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var anniversaries: [Anniversary] = []
    // ルームメンバー表示（userIDと表示名）
    @State private var members: [(id: String, name: String)] = []
    @State private var showAddSheet: Bool = false
    @State private var newTitle: String = ""
    @State private var newDate: Date = Date()
    @State private var newRepeatType: RepeatType = .none
    // 編集用
    @State private var showEditSheet: Bool = false
    @State private var editingAnniversary: Anniversary?
    @State private var editTitle: String = ""
    @State private var editDate: Date = Date()
    @State private var editRepeatType: RepeatType = .none
    // 招待導線はChatView/リストの統一モーダルに集約（Profileからは撤廃）

    var partnerName: String {
        if let name = chatRoom.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let counterpart = chatRoom.primaryCounterpart {
            if let display = counterpart.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty {
                return display
            }
            let uid = counterpart.userID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !uid.isEmpty { return uid }
        }
        return ""
    }

    init(chatRoom: ChatRoom, partnerAvatar: UIImage?) {
        self.chatRoom = chatRoom
        self.partnerAvatar = partnerAvatar
        self.roomID = chatRoom.roomID
    }

    var body: some View {
        NavigationStack {
            List {
                profileHeader

                // メンバー一覧（SwiftUI標準のList/Sectionでネイティブに）
                if !members.isEmpty {
                    Section(header: Text("メンバー")) {
                        ForEach(members, id: \.id) { m in
                            HStack(spacing: 12) {
                                Image(systemName: "person.circle.fill").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name.isEmpty ? m.id : m.name).font(.body)
                                    if !m.name.isEmpty { Text(m.id).font(.caption2).foregroundStyle(.secondary) }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                settingsSection

                Section(header: Text("記念日・目標日")) {
                    ForEach(anniversaries) { ann in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ann.title).font(.headline)
                                HStack {
                                    Text(dateFormatter.string(from: ann.date)).font(.caption).foregroundColor(.secondary)
                                    if ann.repeatType != .none {
                                        Text("(\(ann.repeatType.displayName))").font(.caption).foregroundColor(.accentColor)
                                    }
                                }
                                if ann.repeatType != .none {
                                    let nextDate = ann.nextOccurrence()
                                    Text("次回: \(dateFormatter.string(from: nextDate))")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { beginEdit(ann) }
                        .swipeActions {
                            Button { beginEdit(ann) } label: { Label("編集", systemImage: "pencil") }
                            Button(role: .destructive) {
                                delete(ann)
                            } label: { Label("削除", systemImage: "trash") }
                        }
                    }
                    Button(action: { showAddSheet = true }) {
                        Label("記念日を追加", systemImage: "plus")
                    }
                }
            }
            .navigationTitle(partnerName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .sheet(isPresented: $showAddSheet) { addSheet }
            .sheet(isPresented: $showEditSheet) { editSheet }
            .onAppear {
                loadAnniversaries()
                Task { await loadMembers() }
            }
        }
    }

    // MARK: - Header
    private var profileHeader: some View {
        VStack(alignment: .center, spacing: 12) {
            if let img = partnerAvatar {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.gray.opacity(0.2), lineWidth: 1))
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .foregroundColor(.secondary)
            }
            VStack(spacing: 2) {
                Text(partnerName.isEmpty ? roomID : partnerName)
                    .font(.title3).fontWeight(.semibold)
                Text("Room: \(roomID)")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowInsets(EdgeInsets())
        .padding(.vertical, 12)
    }

    // MARK: - Add / Edit Sheets
    private var addSheet: some View {
        NavigationStack {
            Form {
                Section("タイトル") {
                    TextField("タイトル", text: $newTitle)
                }
                Section("日付") {
                    DatePicker("日付", selection: $newDate, displayedComponents: .date)
                }
                Section("繰り返し") {
                    Picker("繰り返し", selection: $newRepeatType) {
                        ForEach(RepeatType.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                }
            }
            .navigationTitle("記念日を追加")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(action: { showAddSheet = false }) { Image(systemName: "xmark") } }
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { showAddSheet = false } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { saveNewAnniversary() } }
            }
        }
    }

    private var editSheet: some View {
        NavigationStack {
            Form {
                Section("タイトル") {
                    TextField("タイトル", text: $editTitle)
                }
                Section("日付") {
                    DatePicker("日付", selection: $editDate, displayedComponents: .date)
                }
                Section("繰り返し") {
                    Picker("繰り返し", selection: $editRepeatType) {
                        ForEach(RepeatType.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                }
            }
            .navigationTitle("記念日を編集")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(action: { showEditSheet = false }) { Image(systemName: "xmark") } }
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { showEditSheet = false } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { saveEditedAnniversary() } }
            }
        }
    }

    // MARK: - Actions

    private func beginEdit(_ ann: Anniversary) {
        editingAnniversary = ann
        editTitle = ann.title
        editDate = ann.date
        editRepeatType = ann.repeatType
        showEditSheet = true
    }

    private func saveNewAnniversary() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let ann = Anniversary(roomID: roomID, title: title, date: newDate, repeatType: newRepeatType)
        // Cloud用のrecordNameを先につけて送出
        if #available(iOS 17.0, *) {
            let recName = UUID().uuidString
            ann.ckRecordName = recName
            Task { @MainActor in
                await CKSyncEngineManager.shared.queueAnniversaryCreate(recordName: recName, roomID: roomID, title: ann.title, date: ann.date)
            }
        }
        modelContext.insert(ann)
        try? modelContext.save()
        loadAnniversaries()
        showAddSheet = false
        newTitle = ""
        newDate = Date()
        newRepeatType = .none
    }

    private func saveEditedAnniversary() {
        guard let ann = editingAnniversary else { return }
        ann.title = editTitle.trimmingCharacters(in: .whitespaces)
        ann.date = editDate
        ann.repeatType = editRepeatType
        do { try modelContext.save() } catch { }

        if #available(iOS 17.0, *) {
            if let rec = ann.ckRecordName {
                Task { @MainActor in
                    await CKSyncEngineManager.shared.queueAnniversaryUpdate(recordName: rec, roomID: roomID, title: ann.title, date: ann.date)
                }
            } else {
                // 互換: 既存データにrecord名が無い場合は作成として扱う
                let recName = UUID().uuidString
                ann.ckRecordName = recName
                Task { @MainActor in
                    await CKSyncEngineManager.shared.queueAnniversaryCreate(recordName: recName, roomID: roomID, title: ann.title, date: ann.date)
                }
            }
        }
        showEditSheet = false
        editingAnniversary = nil
        loadAnniversaries()
    }

    private func delete(_ ann: Anniversary) {
        modelContext.delete(ann)
        if let rec = ann.ckRecordName {
            if #available(iOS 17.0, *) {
                Task { @MainActor in
                    await CKSyncEngineManager.shared.queueAnniversaryDelete(recordName: rec, roomID: roomID)
                }
            }
        }
        try? modelContext.save()
        loadAnniversaries()
    }

    private func loadAnniversaries() {
        do {
            let desc = FetchDescriptor<Anniversary>(predicate: #Predicate<Anniversary> { $0.roomID == roomID }, sortBy: [SortDescriptor(\.date)])
            anniversaries = try modelContext.fetch(desc)
        } catch {
            anniversaries = []
        }
    }

    private var settingsSection: some View {
        Section(header: Text("設定")) {
            Toggle("画像を自動ダウンロード", isOn: Binding(
                get: { chatRoom.autoDownloadImages },
                set: { newValue in
                    chatRoom.autoDownloadImages = newValue
                    try? modelContext.save()
                }
            ))
        }
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }
}

// MARK: - Members
extension RoomDetailSheet {
    @MainActor
    private func loadMembers() async {
        do {
            // ゾーンとDBを解決し、RoomMemberをそのゾーン内でクエリ
            let (db, zoneID) = try await CloudKitChatManager.shared.resolveDatabaseAndZone(for: roomID)
            let query = CKQuery(recordType: CKSchema.SharedType.roomMember, predicate: NSPredicate(value: true))
            let (results, _) = try await db.records(matching: query, inZoneWith: zoneID)
            var list: [(String, String)] = []
            for (_, result) in results {
                if case .success(let rec) = result {
                    let uid = (rec[CKSchema.FieldKey.userId] as? String) ?? ""
                    let name = (rec[CKSchema.FieldKey.displayName] as? String) ?? ""
                    if !uid.isEmpty { list.append((uid, name)) }
                }
            }
            // 自分のプロフィール（ローカル保存）を上書き優先
            if let me = CloudKitChatManager.shared.currentUserID, !me.isEmpty {
                if let idx = list.firstIndex(where: { $0.0 == me }),
                   let myName = UserDefaults.standard.string(forKey: "myDisplayName")?.trimmingCharacters(in: .whitespacesAndNewlines), !myName.isEmpty {
                    list[idx].1 = myName
                }
            }
            members = list
        } catch {
            members = []
        }
    }
}
