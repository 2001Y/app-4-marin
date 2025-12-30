# 2 台の iOS Simulator（Marin-A / Marin-B）で forMarin を起動する手順

このファイルの役割: **2 台の iOS Simulator を用意して、forMarin（`me.2001y.4-marin`）をビルド → インストール → 起動**するための、再利用できる最短手順。

---

## 前提（このプロジェクトで確定している値）

- **Project**: `/Users/2001y/dev-app/forMarin`
- **Scheme**: `forMarin`
- **Target(App)**: `4-Marin.app`
- **Bundle ID**: `me.2001y.4-marin`
- **ログ（NDJSON）**: `/Users/2001y/dev-app/forMarin/.cursor/debug.log`

---

## まずは “既存の Marin-A / Marin-B を起動する” （最短）

```bash
set -euo pipefail

PROJECT="/Users/2001y/dev-app/forMarin"
DERIVED_DATA="$PROJECT/DerivedDataSim"
APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/4-Marin.app"
BUNDLE_ID="me.2001y.4-marin"

# 既に作成済みのUDID（あなたの環境で作った Marin-A / Marin-B）
UDID_A="782064E0-CF17-4AD3-938C-253AA918137A"
UDID_B="B9600B76-6D70-4CE1-B87A-5F2AC4DDDE25"

# 1) 2台を起動して表示
xcrun simctl boot "$UDID_A" || true
xcrun simctl boot "$UDID_B" || true
xcrun simctl bootstatus "$UDID_A" -b || true
xcrun simctl bootstatus "$UDID_B" -b || true
open -a Simulator --args -CurrentDeviceUDID "$UDID_A" || true
open -a Simulator --args -CurrentDeviceUDID "$UDID_B" || true

# 2) Simulator向けにビルド（DerivedDataはプロジェクト内に出す）
xcodebuild \
  -project "$PROJECT/forMarin.xcodeproj" \
  -scheme forMarin \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID_A" \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackageUpdates \
  build

# 3) 2台にインストール＆起動
xcrun simctl install "$UDID_A" "$APP"
xcrun simctl install "$UDID_B" "$APP"
xcrun simctl launch "$UDID_A" "$BUNDLE_ID" || true
xcrun simctl launch "$UDID_B" "$BUNDLE_ID" || true
```

---

## 初回/消した場合（runtime + 2 台作成まで）

### 1) iOS runtime が無い場合だけ入れる（容量大）

```bash
set -euo pipefail
PROJECT="/Users/2001y/dev-app/forMarin"
mkdir -p "$PROJECT/_simruntimes"

# 例: iOS Simulator Runtime をダウンロード＆インストール（8GB前後）
xcodebuild -downloadPlatform iOS -exportPath "$PROJECT/_simruntimes" -architectureVariant arm64
```

### 2) 2 台作成（Marin-A / Marin-B）

```bash
set -euo pipefail

RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.iOS-26-0"
DEVICETYPE_ID="com.apple.CoreSimulator.SimDeviceType.iPhone-16"

UDID_A=$(xcrun simctl create "Marin-A" "$DEVICETYPE_ID" "$RUNTIME_ID")
UDID_B=$(xcrun simctl create "Marin-B" "$DEVICETYPE_ID" "$RUNTIME_ID")
echo "Marin-A: $UDID_A"
echo "Marin-B: $UDID_B"
```

---

## CloudKit ユーザー認証（チャット作成で必須）

### サインインが必要な状態の典型

- 「**CloudKit ユーザー認証が必要です**」
- ログに `Not Authenticated` / `No iCloud account is configured`

### 設定アプリを開く（手動で Apple ID 入力が必要）

```bash
UDID="782064E0-CF17-4AD3-938C-253AA918137A" # 例: Marin-A
xcrun simctl launch "$UDID" com.apple.Preferences
```

※ P2P 検証をするなら **Marin-A と Marin-B は別 Apple ID** 推奨（同一 ID だと remote == self になりやすい）

---

## デバッグログを“新しい実行だけ”にする（手動）

このパスを消す（無ければ OK）:

- `/Users/2001y/dev-app/forMarin/.cursor/debug.log`

例:

```bash
rm -f /Users/2001y/dev-app/forMarin/.cursor/debug.log
```

---

## 共有 URL を Marin-B で開く（参加テスト用）

```bash
UDID_B="B9600B76-6D70-4CE1-B87A-5F2AC4DDDE25"
SHARE_URL="https://www.icloud.com/share/xxxxxxxxxxxxxxxx#4-Marin_Chat"
xcrun simctl openurl "$UDID_B" "$SHARE_URL"
```
