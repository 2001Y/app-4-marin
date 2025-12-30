# iOS Simulator で iCloud 利用規約ポップアップが表示されない問題

## 症状

- シミュレータの設定アプリで Apple ID にサインイン後、「利用規約を表示する」が表示される
- しかしポップアップが表示されず、同意できない
- アプリで「CloudKitユーザー認証が必要です」エラーになる

## 原因

iOS Simulator の既知のバグ。特に iOS 26 beta などの新しいランタイムで発生しやすい。
設定アプリのモーダル表示が正常に動作しない。

## 試したが効果がなかった方法

1. Safari（シミュレータ内）で iCloud.com にサインイン → 利用規約表示されず
2. Mac のブラウザで iCloud.com にサインイン → 既に同意済みで表示されず
3. 設定アプリでサインアウト → 再サインイン → 変化なし

## 解決した方法

**シミュレータを完全に削除して再作成 + リセット**

### 手順

1. 問題のあるシミュレータを削除
```bash
xcrun simctl shutdown "UDID"
xcrun simctl delete "UDID"
```

2. 新しいシミュレータを作成
```bash
RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.iOS-26-0"
DEVICETYPE_ID="com.apple.CoreSimulator.SimDeviceType.iPhone-16"
NEW_UDID=$(xcrun simctl create "Marin-B" "$DEVICETYPE_ID" "$RUNTIME_ID")
```

3. 起動
```bash
xcrun simctl boot "$NEW_UDID"
xcrun simctl bootstatus "$NEW_UDID" -b
open -a Simulator --args -CurrentDeviceUDID "$NEW_UDID"
```

4. シミュレータをリセット（重要）
```bash
xcrun simctl shutdown "$NEW_UDID"
xcrun simctl erase "$NEW_UDID"
xcrun simctl boot "$NEW_UDID"
```

5. 設定アプリで Apple ID にサインイン
```bash
xcrun simctl launch "$NEW_UDID" com.apple.Preferences
```

→ **リセット後のクリーンな状態** で利用規約が正常に表示・同意できた

## ポイント

- 単なるサインアウト/サインインでは解決しない
- シミュレータの**削除→再作成→リセット（erase）**が必要
- ドキュメント内の UDID を新しい値に更新することを忘れずに

## 環境

- Xcode: 26 beta
- iOS Simulator Runtime: iOS 26.0 (26.0.1 - 23A8464)
- macOS: darwin 25.0.0
