import Foundation

// シンプルな同期コアレッサ（iOS17+）
// - 複数のトリガを1サイクルへ統合
// - 実行中はpendingを立て、完了時に1回だけ追走
actor SyncCoordinator {
    private var inFlight: Bool = false
    private var pending: Bool = false
    private let debounceNanos: UInt64 = 500_000_000 // 0.5s

    func requestSync(trigger: String, perform: @Sendable @escaping () async -> Void) async {
        if inFlight {
            pending = true
            return
        }

        inFlight = true
        // デバウンスでバーストを吸収
        try? await Task.sleep(nanoseconds: debounceNanos)

        await perform()

        inFlight = false
        if pending {
            pending = false
            // 追走1回
            await requestSync(trigger: "coalesced:") {
                await perform()
            }
        }
    }
}

