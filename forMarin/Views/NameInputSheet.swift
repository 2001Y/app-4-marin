import SwiftUI

struct NameInputSheet: View {
    @Binding var isPresented: Bool
    @AppStorage("myDisplayName") private var myDisplayName: String = ""
    @State private var tempName: String = ""
    @State private var saving = false

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 8)
            Text("あなたの名前は？").font(.headline)
            TextField("表示名", text: $tempName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            Button {
                Task { await save() }
            } label: {
                if saving { ProgressView() } else { Text("つづける").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(tempName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            .padding(.horizontal)
            Spacer(minLength: 12)
        }
        .onAppear { tempName = myDisplayName }
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
        try? await CloudKitChatManager.shared.saveMasterProfile(name: name, avatarData: Data())
        isPresented = false
    }
}
