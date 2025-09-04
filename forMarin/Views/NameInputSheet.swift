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

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 8)
            // プロフィール画像（デフォルトアイコン）
            Button {
                // PhotosPickerは背景に載せるためアクション不要
            } label: {
                Group {
                    if let image = selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                    } else if !myAvatarData.isEmpty, let image = UIImage(data: myAvatarData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                    } else {
                        ZStack {
                            Circle()
                                .fill(Color.gray.opacity(0.15))
                                .frame(width: 96, height: 96)
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 56))
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .background(
                PhotosPicker(selection: $photosPickerItem,
                            matching: .images,
                            photoLibrary: .shared()) {
                    Color.clear
                }
            )
            .padding(.top, 4)
            Text("アイコンをタップして画像を選択")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("あなたの名前は？")
                .font(.headline)
            // 入力エリアの高さ・角丸を統一
            HStack { 
                TextField("表示名", text: $tempName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .font(.system(size: 16))
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
            .padding(.horizontal)

            // ボタンの高さ・角丸を統一（52pt / 12R）
            Button {
                Task { await save() }
            } label: {
                HStack {
                    if saving {
                        ProgressView().tint(.white)
                    } else {
                        Text("つづける")
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundColor(.white)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(tempName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            .padding(.horizontal)
            Spacer(minLength: 12)
        }
        .onAppear {
            tempName = myDisplayName
            if !myAvatarData.isEmpty { selectedImage = UIImage(data: myAvatarData) }
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
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
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
        // 呼び出し元へ登録完了を通知
        onSaved?()
        isPresented = false
    }
}
