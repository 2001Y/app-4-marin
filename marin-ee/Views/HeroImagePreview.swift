import SwiftUI

/// 単一画像用ヒーロープレビュー。サムネイルと同じ `matchedGeometryEffect` id を共有して全画面化し、
/// 下方向 Drag でインタラクティブに閉じられる。
struct HeroImagePreview: View {
    let image: UIImage
    let geometryID: String
    var namespace: Namespace.ID
    var onDismiss: () -> Void
    var message: Message?
    @Environment(\.modelContext) private var modelContext
    @Environment(ReactionStore.self) private var reactionStore
    @AppStorage("recentEmojis") private var recentEmojisString: String = "😀,👍,🎉"
    @AppStorage("photosFavoriteSync") private var photosFavoriteSync: Bool = true
    @State private var showEmojiPicker = false
    @State private var pickedEmoji: String = ""

    // Drag
    @GestureState private var dragState: CGSize = .zero
    private let dismissThreshold: CGFloat = 120

    // アクションボタン表示
    @State private var showActions: Bool = false
    @State private var toast: String? = nil
    
    // Corner radius animation
    @State private var cornerRadius: CGFloat = 8

    private var dragProgress: CGFloat {
        let dy = abs(dragState.height)
        return min(dy / dismissThreshold, 1)
    }

    var body: some View {
        ZStack {
            // 背景 (黒+薄ブラー) - ドラッグで薄く
            Rectangle()
                .fill(Color.black.opacity(Double(0.15 * (1 - dragProgress))))
                .background(.thinMaterial)
                .ignoresSafeArea()
                .onTapGesture { close() }

            // 画像本体
            GeometryReader { geometry in
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .matchedGeometryEffect(id: geometryID, in: namespace)
                    .offset(dragState)
                    .scaleEffect(1 - 0.2 * dragProgress)
                    .gesture(
                        DragGesture()
                            .updating($dragState) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                if abs(value.translation.height) > dismissThreshold {
                                    close()
                                }
                            }
                    )
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }

            // アクション (遅延フェードイン)
            VStack {
                HStack {
                    Spacer()
                    // Close button (top right)
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.regularMaterial)
                    }
                    .opacity(showActions ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: showActions)
                }
                .padding(.horizontal, 24)
                .padding(.top, 50)
                
                Spacer()
                
                HStack {
                    Spacer()
                    // Download button (bottom right)
                    Button {
                        saveImage()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.title)
                            .foregroundStyle(.regularMaterial)
                    }
                    .opacity(showActions ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: showActions)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 50)
            }
            
            // Quick emoji bar in center
            if let msg = message {
                let recentEmojis = recentEmojisString.split(separator: ",").map(String.init)
                QuickEmojiBar(recentEmojis: Array(recentEmojis.prefix(3))) { emoji in
                    // Add reaction
                    var reactions = msg.reactionEmoji ?? ""
                    reactions.append(emoji)
                    msg.reactionEmoji = reactions
                    updateRecentEmoji(emoji)
                    // Sync to Photos favorite if heart
                    if photosFavoriteSync && emoji == "❤️" {
                        syncToPhotosFavorite(true)
                    }
                    // Sync to CloudKit
                    if let recName = msg.ckRecordName {
                        Task { try? await CKSync.updateReaction(recordName: recName, emoji: reactions) }
                    }
                } onShowPicker: {
                    showEmojiPicker = true
                }
                .opacity(showActions ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: showActions)
            }

            // Toast
            if let msg = toast {
                Text(msg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { toast = nil }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 60)
            }
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showEmojiPicker) {
            MCEmojiPickerSheet(selectedEmoji: $pickedEmoji)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: pickedEmoji) { newValue, _ in
            guard !newValue.isEmpty, let msg = message else { return }
            var reactions = msg.reactionEmoji ?? ""
            reactions.append(newValue)
            msg.reactionEmoji = reactions
            updateRecentEmoji(newValue)
            pickedEmoji = ""
            // Sync to Photos favorite if heart
            if photosFavoriteSync && newValue == "❤️" {
                syncToPhotosFavorite(true)
            }
            if let recName = msg.ckRecordName {
                Task { try? await CKSync.updateReaction(recordName: recName, emoji: reactions) }
            }
        }
        .onAppear {
            // Corner radius animation
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                cornerRadius = 0
            }
            // Button fade in after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showActions = true
            }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
            showActions = false
            cornerRadius = 8
        }
        // 少し遅らせないとボタンが一瞬残る場合がある
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onDismiss()
        }
    }

    private func saveImage() {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        withAnimation { toast = "ダウンロードしました" }
        
        // Auto-download check
        if let msg = message, let reactions = msg.reactionEmoji, 
           photosFavoriteSync && reactions.contains("❤️") {
            syncToPhotosFavorite(true)
        }
    }
    
    private func updateRecentEmoji(_ emoji: String) {
        var arr = recentEmojisString.split(separator: ",").map(String.init)
        if let idx = arr.firstIndex(of: emoji) {
            arr.remove(at: idx)
        }
        arr.insert(emoji, at: 0)
        if arr.count > 3 { arr = Array(arr.prefix(3)) }
        recentEmojisString = arr.joined(separator: ",")
    }
    
    private func syncToPhotosFavorite(_ favorite: Bool) {
        // This would require Photos framework integration
        // For now, just log the intent
        print("[HeroImagePreview] Would sync to Photos favorite: \(favorite)")
    }
}