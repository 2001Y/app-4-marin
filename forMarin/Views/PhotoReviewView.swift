import SwiftUI
import UIKit

struct PhotoReviewView: View {
    let photoURL: URL
    let onComplete: (Bool) -> Void
    
    @State private var image: UIImage?
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack {
                // 上部のコントロール
                HStack {
                    Button {
                        onComplete(false)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    
                    Spacer()
                    
                    Text("写真プレビュー")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    // 透明なスペーサー（左右対称にするため）
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 20)
                .padding(.horizontal, 20)
                
                // 写真表示エリア
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay {
                            ProgressView("写真を読み込み中...")
                                .foregroundColor(.white)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
                
                Spacer()
                
                // 下部のコントロール
                HStack(spacing: 40) {
                    // 閉じる（保存しない）
                    Button {
                        onComplete(false)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "trash")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 60, height: 60)
                                .background(Circle().fill(.red.opacity(0.8)))
                            
                            Text("破棄")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }
                    
                    // 送信
                    Button {
                        onComplete(true)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "paperplane.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 60, height: 60)
                                .background(Circle().fill(.blue.opacity(0.8)))
                            
                            Text("送信")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            loadImage()
        }
    }
    
    private func loadImage() {
        Task {
            if let loadedImage = UIImage(contentsOfFile: photoURL.path) {
                await MainActor.run {
                    image = loadedImage
                }
            }
        }
    }
} 