import SwiftUI
import PhotosUI

struct NameInputSheet: View {
    @Binding var isPresented: Bool
    var onSaved: (() -> Void)? = nil
    @AppStorage("myDisplayName") private var myDisplayName: String = ""
    @AppStorage("myAvatarData") private var myAvatarData: Data = Data()
    @State private var tempName: String = ""
    @State private var saving = false
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var selectedImage: UIImage? = nil
    @FocusState private var focusedField: Field?
    @State private var detentSelection: PresentationDetent = .medium

    private enum Field: Hashable {
        case displayName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        PhotosPicker(selection: $photosPickerItem,
                                     matching: .images,
                                     photoLibrary: .shared()) {
                            avatarView
                        }
                        .buttonStyle(.plain)

                        Text("アイコンをタップして画像を選択")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                Section("表示名") {
                    TextField("表示名", text: $tempName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .displayName)
                        .submitLabel(.done)
                }
            }
            .formStyle(.grouped)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { isPresented = false }) { Image(systemName: "xmark") }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") {
                        focusedField = nil
                    }
                }
            }
            .navigationTitle("あなたの名前は？")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large], selection: $detentSelection)
        .presentationDragIndicator(.visible)
        .safeAreaInset(edge: .bottom) { bottomActionArea.ignoresSafeArea(.keyboard) }
        .onAppear {
            tempName = myDisplayName
            if !myAvatarData.isEmpty { selectedImage = UIImage(data: myAvatarData) }
            scheduleFocus()
        }
        .onChange(of: focusedField) { _, newValue in
            if newValue != nil {
                detentSelection = .large
            }
        }
        .onChange(of: photosPickerItem) { _, newItem in
            Task { @MainActor in
                if let item = newItem,
                   let data = try? await item.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    let resized = uiImage.resized(to: CGSize(width: 200, height: 200))
                    selectedImage = resized
                    if let jpegData = resized.jpegData(compressionQuality: 0.8) {
                        myAvatarData = jpegData
                    }
                }
            }
        }
    }

    @MainActor
    private func save() async {
        saving = true
        defer { saving = false }
        let name = tempName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        myDisplayName = name
        // CloudKitプロフィールへ反映（失敗は無視）
        try? await CloudKitChatManager.shared.saveMasterProfile(name: name, avatarData: myAvatarData)
        // 共有中の全ゾーンへ同報
        await CloudKitChatManager.shared.updateParticipantProfileInAllZones(name: name, avatarData: myAvatarData)
        log("NameInputSheet: saved displayName=\(name)", category: "Onboarding")
        focusedField = nil
        // ルート判定用に表示名更新を通知
        NotificationCenter.default.post(name: .displayNameUpdated, object: nil, userInfo: ["name": name])
        // 呼び出し元へ登録完了を通知
        onSaved?()
        isPresented = false
    }

    @ViewBuilder
    private var avatarView: some View {
        Group {
            if let image = selectedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if !myAvatarData.isEmpty, let image = UIImage(data: myAvatarData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle()
                        .fill(Color.gray.opacity(0.15))
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 54))
                        .foregroundColor(.gray)
                }
            }
        }
        .frame(width: 100, height: 100)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.gray.opacity(0.25), lineWidth: 1))
        .contentShape(Circle())
        .accessibilityLabel("プロフィール画像を選択")
    }

    private var bottomActionArea: some View {
        VStack(spacing: 12) {
            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 8) {
                    if saving {
                        ProgressView()
                    }
                    Text("つづける")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(tempName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .shadow(color: Color.black.opacity(0.08), radius: 16, y: -2)
    }

    private func scheduleFocus() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            focusedField = .displayName
        }
    }
}
