import Foundation

extension Notification.Name {
    static let didFinishDualCamRecording = Notification.Name("didFinishDualCamRecording")
    static let didFinishDualCamPhoto = Notification.Name("didFinishDualCamPhoto")
    static let showOfflineModal = Notification.Name("showOfflineModal")
    // FaceTime ID（Apple IDメール）登録が初回に完了したときにポストする
    static let faceTimeIDRegistered = Notification.Name("faceTimeIDRegistered")
    // CloudKit正規化リアクションの更新通知（MessageStore->View）
    static let reactionsUpdated = Notification.Name("reactionsUpdated")
    // スキャン完了後に特定のチャットを開かせるための通知
    static let openChatRoom = Notification.Name("openChatRoom")
}
