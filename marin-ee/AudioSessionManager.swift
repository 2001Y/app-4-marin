import Foundation
import AVFoundation
#if canImport(WebRTC)
import WebRTC
#endif

/// 単一箇所で AVAudioSession / RTCAudioSession のポリシーを管理するユーティリティ。
/// - アプリ起動時に `configureForAmbient()` を呼び、外部オーディオを停止させない。
/// - 録画や WebRTC 音声送出が必要な場合は `beginRecording()` / `endRecording()` でカテゴリを一時的に昇格させる。
struct AudioSessionManager {
    private static var previousCategory: AVAudioSession.Category?
    private static var previousOptions: AVAudioSession.CategoryOptions = []

    /// 他アプリの音楽をミックスし、Duck もさせずにそのまま再生継続させる設定。
    static func configureForAmbient() {
        let avSession = AVAudioSession.sharedInstance()
        do {
            #if canImport(WebRTC)
            // WebRTC が勝手に Category を変更しないよう Manual モードへ
            let rtcSession = RTCAudioSession.sharedInstance()
            rtcSession.useManualAudio = true
            #endif
            try avSession.setCategory(.ambient, options: [.mixWithOthers])
            try avSession.setActive(true, options: [])
        } catch {
            print("AudioSessionManager: Failed to set ambient category - \(error)")
        }
    }

    /// 録画 (カメラ + マイク) 開始前に呼ぶ。現在のカテゴリを保持し PlayAndRecord へ昇格。
    static func beginRecording() {
        let avSession = AVAudioSession.sharedInstance()
        previousCategory = avSession.category
        previousOptions = avSession.categoryOptions
        do {
            try avSession.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
            try avSession.setActive(true, options: [])
        } catch {
            print("AudioSessionManager: Failed to elevate category - \(error)")
        }
    }

    /// 録画終了後に呼ぶ。元のカテゴリに戻す。
    static func endRecording() {
        guard let prev = previousCategory else { return }
        let avSession = AVAudioSession.sharedInstance()
        do {
            try avSession.setCategory(prev, options: previousOptions)
            try avSession.setActive(true, options: [])
        } catch {
            print("AudioSessionManager: Failed to restore category - \(error)")
        }
    }
}