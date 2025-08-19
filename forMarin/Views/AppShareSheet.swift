//
//  AppShareSheet.swift
//  forMarin
//
//  Created by Claude on 2025/07/29.
//

import SwiftUI

// MARK: - ShareSheet（通常の共有）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - AirDropFocusedShareSheet（AirDrop専用）
struct AirDropFocusedShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let completion: ((Bool) -> Void)?
    
    init(items: [Any], completion: ((Bool) -> Void)? = nil) {
        self.items = items
        self.completion = completion
    }
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        
        // AirDrop以外のほぼ全てのオプションを除外
        controller.excludedActivityTypes = [
            .postToFacebook, .postToTwitter, .postToWeibo, .message,
            .mail, .print, .copyToPasteboard, .assignToContact,
            .saveToCameraRoll, .addToReadingList, .postToFlickr,
            .postToVimeo, .postToTencentWeibo, .openInIBooks,
            .markupAsPDF, .sharePlay
        ]
        
        // 完了ハンドラを設定
        controller.completionWithItemsHandler = { activityType, completed, returnedItems, error in
            if let completion = completion {
                // AirDropで成功した場合はtrue、それ以外（キャンセル含む）はfalse
                completion(completed && activityType == .airDrop)
            }
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}