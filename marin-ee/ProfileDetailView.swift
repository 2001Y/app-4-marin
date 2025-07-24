import SwiftUI
import PhotosUI
import SwiftData

struct ProfileDetailView: View {
    let partnerName: String
    let partnerAvatar: UIImage?
    let roomID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var anniversaries: [Anniversary]

    @State private var showAddSheet: Bool = false
    @State private var newTitle: String = ""
    @State private var newDate: Date = Date()

    init(partnerName: String, partnerAvatar: UIImage?, roomID: String) {
        self.partnerName = partnerName
        self.partnerAvatar = partnerAvatar
        self.roomID = roomID
        _anniversaries = Query(filter: #Predicate<Anniversary> { $0.roomID == roomID }, sort: \Anniversary.date)
    }

    var body: some View {
        NavigationStack {
            List {
                profileHeader

                Section(header: Text("記念日・目標日")) {
                    ForEach(anniversaries) { ann in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(ann.title).font(.headline)
                                Text(dateFormatter.string(from: ann.date)).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .swipeActions {
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
                TextField("タイトル", text: $newTitle)
                DatePicker("日付", selection: $newDate, displayedComponents: .date)
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

    private func save() {
        let ann = Anniversary(roomID: roomID, title: newTitle.trimmingCharacters(in: .whitespaces), date: newDate)
        modelContext.insert(ann)
        Task { @MainActor in
            if let recName = try? await CKSync.saveAnniversary(title: ann.title, date: ann.date, roomID: roomID) {
                ann.ckRecordName = recName
            }
        }
        showAddSheet = false
        newTitle = ""
        newDate = Date()
    }

    private func delete(_ ann: Anniversary) {
        modelContext.delete(ann)
        if let rec = ann.ckRecordName { Task { await CKSync.deleteAnniversary(recordName: rec) } }
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }
}