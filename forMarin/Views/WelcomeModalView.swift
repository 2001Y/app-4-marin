//
//  WelcomeModalView.swift
//  forMarin
//
//  Created by Claude on 2025/07/28.
//

import SwiftUI

struct WelcomeModalView: View {
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            // ドラッグインジケーター
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 20)
            
            VStack(spacing: 16) {
                // アプリロゴ
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                
                // タイトル
                Text("4-Marin")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                // 説明文
                VStack(spacing: 16) {
                    Text("このアプリは\n作成者のパートナー Marin のためにつくられた\n特別なメッセージアプリです。")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                    
                    Text("日本にいるわたしと、\n長期間オーストラリアに行ってしまう Marin")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .foregroundColor(.secondary)
                    
                    Text("でも私たちだけではなく、\n遠くに大切な人がいる方はもちろん\nテキストのやりとりが苦手な方にも\nよろこんでもらえると嬉しいです。")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                    
                    Text("気に入ったらぜひ共有してみてね")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .foregroundColor(.secondary)
                    
                    // 署名
                    HStack {
                        Spacer()
                        Text("よしき")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 12)
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 20)
                
                // つづけるボタン
                Button {
                    // 触覚フィードバック
                    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                    impactFeedback.impactOccurred()
                    
                    onContinue()
                } label: {
                    Text("つづける")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                
                // このアプリを共有するボタン
                Button {
                    // 触覚フィードバック
                    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                    impactFeedback.impactOccurred()
                    
                    showShareSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16))
                        Text("このアプリを共有する")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
        .cornerRadius(20, corners: [.topLeft, .topRight])
        .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: -2)
        .sheet(isPresented: $showShareSheet) {
            let items: [Any] = [shareText] + (shareURL.map { [$0] } ?? [])
            ShareSheet(items: items)
        }
    }
    
    // MARK: - 共有コンテンツ
    private var shareText: String {
        "「4-Marin」で遠距離コミュニケーションをもっと身近に。一緒に開いてる時は顔が見える特別なメッセージアプリです。"
    }
    
    private var shareURL: URL? {
        // 実際のApp Store URLに置き換えてください
        return URL(string: "https://apps.apple.com/app/4-marin/id123456789")
    }
}

// カスタムコーナーラジアス用のExtension
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}


// ハーフモーダル表示用のオーバーレイ
struct WelcomeModalOverlay: View {
    @Binding var isPresented: Bool
    let onContinue: () -> Void
    @State private var dragOffset: CGFloat = 0
    
    var body: some View {
        ZStack {
            if isPresented {
                // 背景のディミング
                Color.black.opacity(0.4)
                    .ignoresSafeArea(.all, edges: .all)
                    .onTapGesture {
                        // 背景タップでは閉じない（意図的）
                    }
                
                // モーダル本体
                VStack {
                    Spacer()
                    WelcomeModalView {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isPresented = false
                        }
                        onContinue()
                    }
                    .offset(y: dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let translation = value.translation
                                if translation.height > 0 {
                                    dragOffset = translation.height
                                }
                            }
                            .onEnded { value in
                                let translation = value.translation
                                let predictedEnd = value.predictedEndTranslation
                                if translation.height > 150 || predictedEnd.height > 300 {
                                    // スワイプで閉じる
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        isPresented = false
                                    }
                                } else {
                                    // 元の位置に戻す
                                    withAnimation(.easeOut(duration: 0.3)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isPresented)
        .ignoresSafeArea(.all, edges: .all)
    }
}

#Preview {
    @Previewable @State var isPresented = true
    return ZStack {
        Color.gray.ignoresSafeArea()
        WelcomeModalOverlay(isPresented: $isPresented) {
            log("Continue tapped", category: "App")
        }
    }
}
