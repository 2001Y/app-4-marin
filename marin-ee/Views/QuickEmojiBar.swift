import SwiftUI
import UIKit

/// 入力欄横やリアクションピッカーで再利用できる、最近使った絵文字 3 件 + 追加ボタンのバー
struct QuickEmojiBar: View {
    /// 最近使った絵文字 (最大 3 件)
    let recentEmojis: [String]
    /// 絵文字をタップしたときのハンドラ
    var onEmojiTap: (String) -> Void
    /// プラス(スマイリー)ボタンをタップしたときのハンドラ
    var onShowPicker: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(recentEmojis, id: \.self) { emoji in
                Button(emoji) {
                    onEmojiTap(emoji)
                }
                .buttonStyle(.plain)
                .font(.system(size: UIFont.preferredFont(forTextStyle: .body).pointSize * 1.5))
            }

            Button {
                onShowPicker()
            } label: {
                Image(systemName: "smiley")
            }
        }
    }
} 