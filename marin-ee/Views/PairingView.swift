import SwiftUI

struct PairingView: View {
    @AppStorage("remoteUserID") private var remoteUserID: String = ""
    @State private var partnerID: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 72))
                    .foregroundColor(.accentColor)
                    .padding(.top, 40)

                Text("Marin-ee")
                    .font(.largeTitle.bold())

                Text("ようこそ！")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Text("さっそく、相手の連絡先を登録しよう。")
                    .font(.body)

                VStack(alignment: .leading, spacing: 8) {
                    Text("相手のAppleアカウント")
                        .font(.subheadline.weight(.semibold))

                    TextField("メールアドレス または 電話番号", text: $partnerID)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Button {
                    remoteUserID = partnerID.trimmingCharacters(in: .whitespacesAndNewlines)
                } label: {
                    Text("登録して開始")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(partnerID.trimmingCharacters(in: .whitespaces).isEmpty)

                Text("""
マリニーはAppleアカウント上(※)で動作するので、あなたはアカウントを作る必要はありません。

※Appleアカウントに紐付けられたメールアドレスまたは電話番号を連絡先として、画像を含むチャットのデータはあなたのiCloud上で管理されます。
""")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }
} 