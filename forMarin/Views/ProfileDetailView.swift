import SwiftUI
import PhotosUI
import SwiftData

struct ProfileDetailView: View {
    let chatRoom: ChatRoom
    let partnerAvatar: UIImage?
    let roomID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var anniversaries: [Anniversary] = []
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

    var partnerName: String { chatRoom.displayName ?? chatRoom.remoteUserID }

    init(chatRoom: ChatRoom, partnerAvatar: UIImage?) {
        self.chatRoom = chatRoom
        self.partnerAvatar = partnerAvatar
        self.roomID = chatRoom.roomID
    }

    var body: some View {
        NavigationStack {
            List {
                profileHeader

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
                    Button { showAddSheet = true } label: {
                        Label("追加", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("プロフィール")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .sheet(isPresented: $showAddSheet) { addSheet }
            .sheet(isPresented: $showEditSheet) { editSheet }
            .onAppear {
                loadAnniversaries()
            }
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 16) {
            if let img = partnerAvatar {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 80, height: 80).clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle").resizable().scaledToFit().frame(width: 80, height: 80).foregroundColor(.gray)
            }
            VStack(alignment: .leading) {
                Text(partnerName.isEmpty ? "Partner" : partnerName).font(.title3).fontWeight(.semibold)
                Text("Room ID: \(roomID.prefix(8))…").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section(header: Text("基本情報")) {
                    TextField("タイトル", text: $newTitle)
                    DatePicker("日付", selection: $newDate, displayedComponents: .date)
                }
                
                Section(header: Text("繰り返し設定")) {
                    Picker("繰り返し", selection: $newRepeatType) {
                        ForEach(RepeatType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    if newRepeatType != .none {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("説明")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            switch newRepeatType {
                            case .yearly:
                                Text("毎年 \(Calendar.current.component(.month, from: newDate))月\(Calendar.current.component(.day, from: newDate))日 に繰り返されます")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            case .monthly:
                                Text("毎月 \(Calendar.current.component(.day, from: newDate))日 に繰り返されます")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            case .none:
                                EmptyView()
                            }
                        }
                    }
                }
            }
            .navigationTitle("記念日追加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { showAddSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func loadAnniversaries() {
        let descriptor = FetchDescriptor<Anniversary>(
            sortBy: [SortDescriptor(\.date)]
        )
        do {
            let allAnniversaries = try modelContext.fetch(descriptor)
            let currentRoomID = self.roomID
            anniversaries = allAnniversaries.filter { anniversary in
                return anniversary.roomID == currentRoomID
            }
        } catch {
            log("Failed to load anniversaries: \(error)", category: "App")
            anniversaries = []
        }
    }

    private func save() {
        let ann = Anniversary(
            roomID: roomID,
            title: newTitle.trimmingCharacters(in: .whitespaces),
            date: newDate,
            repeatType: newRepeatType
        )
        // 先にレコード名を決めてローカルへ反映（Engineで同じIDを使用）
        let recName = UUID().uuidString
        ann.ckRecordName = recName
        modelContext.insert(ann)
        
        // CKSyncEngine 経由で作成をキュー
        if #available(iOS 17.0, *) {
            Task { @MainActor in
                await CKSyncEngineManager.shared.queueAnniversaryCreate(
                    recordName: recName,
                    roomID: roomID,
                    title: ann.title,
                    date: ann.date
                )
            }
        } else {
            // ENGINE_ONLY 運用のため通常到達しない
        }
        showAddSheet = false
        newTitle = ""
        newDate = Date()
        newRepeatType = .none
        loadAnniversaries() // リストを更新
    }

    private func beginEdit(_ ann: Anniversary) {
        editingAnniversary = ann
        editTitle = ann.title
        editDate = ann.date
        editRepeatType = ann.repeatType
        showEditSheet = true
    }

    private var editSheet: some View {
        NavigationStack {
            Form {
                Section(header: Text("基本情報")) {
                    TextField("タイトル", text: $editTitle)
                    DatePicker("日付", selection: $editDate, displayedComponents: .date)
                }
                Section(header: Text("繰り返し設定")) {
                    Picker("繰り返し", selection: $editRepeatType) {
                        ForEach(RepeatType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle("記念日を編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { showEditSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { updateEditedAnniversary() }
                        .disabled(editTitle.trimmingCharacters(in: .whitespaces).isEmpty || editingAnniversary == nil)
                }
            }
        }
    }

    private func updateEditedAnniversary() {
        guard let ann = editingAnniversary else { return }
        // ローカル更新
        ann.title = editTitle.trimmingCharacters(in: .whitespaces)
        ann.date = editDate
        ann.repeatType = editRepeatType
        do { try modelContext.save() } catch { log("Failed to save edited anniversary: \(error)", category: "ProfileDetailView") }

        // CloudKitへはEngine経由
        if #available(iOS 17.0, *) {
            if let rec = ann.ckRecordName {
                Task { @MainActor in
                    await CKSyncEngineManager.shared.queueAnniversaryUpdate(
                        recordName: rec,
                        roomID: roomID,
                        title: ann.title,
                        date: ann.date
                    )
                }
            } else {
                // 互換のため、ckRecordNameがない既存データは作成として扱う
                let recName = UUID().uuidString
                ann.ckRecordName = recName
                Task { @MainActor in
                    await CKSyncEngineManager.shared.queueAnniversaryCreate(
                        recordName: recName,
                        roomID: roomID,
                        title: ann.title,
                        date: ann.date
                    )
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
            } else {
                // ENGINE_ONLY 運用のため通常到達しない
            }
        }
        loadAnniversaries() // リストを更新
    }
    
    private func shareChat() {
        Task {
            guard let viewController = InvitationManager.shared.getCurrentViewController() else {
                log("Could not get current view controller", category: "ProfileDetailView")
                return
            }
            
            // まず既存の招待URLを再共有を試行
            await InvitationManager.shared.reshareExistingInvitation(
                roomID: roomID,
                from: viewController
            )
            
            // エラーが発生した場合は新しい招待を作成
            if InvitationManager.shared.lastError != nil {
                log("No existing share found, creating new invitation", category: "ProfileDetailView")
                await InvitationManager.shared.createAndShareInvitation(
                    for: chatRoom.remoteUserID,
                    from: viewController
                )
            }
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
            
            Button(action: shareChat) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.accentColor)
                    Text("チャットを招待")
                        .foregroundColor(.accentColor)
                    Spacer()
                }
            }
        }
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }
}
