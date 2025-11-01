# Xcode の .pcm「No such file or directory」対処手順（forMarin）

## 要約
- 症状: ビルド時に `~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex/*.pcm: No such file or directory` が多数発生。
- 主因: モジュールキャッシュの不整合（Xcode/SDK更新後のハッシュ不一致、壊れたキャッシュ、CLTのXcode不一致）。
- 解決: ModuleCache/DerivedData のクリーンリセット＋XcodeのCommand Line Tools整合確認。プロジェクト内に存在する非標準 `.modulecache/` は原則廃止。

## 迅速チェックリスト（推奨順）
- Xcode を終了する（Sim/関連プロセスも停止）。
- `scripts/xc-reset-modulecache.sh` を実行してユーザLibrary配下の ModuleCache を削除。
- Xcode > Settings > Locations > Command Line Tools が現在のXcodeを指しているか確認。
- Xcode を開き直し、Product > Clean Build Folder（Shift+Cmd+K）→ Build。
- まだ失敗する場合のみ、`~/Library/Developer/Xcode/DerivedData` 全体を削除して再ビルド。

## 背景と根本原因
Clangモジュールはインポート時に `.pcm`（precompiled module）を `ModuleCache.noindex` に生成します。Xcode/SDKの更新やCLTが別Xcodeを指している場合、既存 `.pcm` と新しいヘッダ/モジュール記述のハッシュが合わず、古いパスを参照して「No such file or directory」が連発します。

補足として、本リポジトリ直下に `.modulecache/` と `DerivedData/` が存在しますが、これらはデフォルトの推奨配置ではなく、環境により混乱の原因になり得ます（本件の直接原因ではない可能性が高いが“匂い”）。

## 手順（詳細）
1) ツールチェーン確認（ログ採取用）
```
xcode-select -p
xcrun --show-sdk-path --sdk iphoneos
xcrun --show-sdk-path --sdk iphonesimulator
```

2) モジュールキャッシュ初期化（ユーザLibrary）
```
rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex
```
必要に応じて DerivedData 全体を初期化：
```
rm -rf ~/Library/Developer/Xcode/DerivedData/*
```

3) SwiftPM キャッシュ（プロジェクトローカル）
```
rm -rf .build
```

4) Xcode 再起動 → Clean Build Folder → Build

5) なおるかの検証ポイント
- ビルドログに `.pcm: No such file or directory` が再発しない。
- `xcode-select -p` のパスが Xcode の Locations 画面の CLT 選択と一致。

## プロジェクト健全化（実装/構成ポリシーに沿った改善）
- `.modulecache/`（リポ直下）は非推奨。Xcodeの標準 `ModuleCache.noindex` に委ねる。
- リポ直下の `DerivedData/` も原則不要。ユーザLibrary側に集約する。
- `.gitignore` に `.modulecache/` を追加済み（リポに持ち込まない）。

## “匂い”として挙がった箇所（削除・簡素化候補）
- `.modulecache/` ディレクトリ（リポ直下）
- `DerivedData/` ディレクトリ（リポ直下）
  - どちらもXcode標準運用では不要。今後は作らない/残さない方針が安全。

## 代替案と不採用理由（コメント）
<!--
- ビルド前スクリプトで毎回 ModuleCache を削除 → 起動/ビルドが遅くなるため不採用。恒久対策は“壊れたキャッシュをリセットして正常化”が筋。
- CLANG_ENABLE_MODULES を無効化 → Apple推奨経路から逸脱しコンパイル時間/安定性に悪影響のため不採用。
-->

## 変更差分
- `.gitignore:line 13` に `.modulecache/` を追加。
- `scripts/xc-reset-modulecache.sh:1` 追加（ログ出力付きの安全なリセットスクリプト）。

## 実行例（ログ）
```
$ bash scripts/xc-reset-modulecache.sh
[xc-reset] Starting Xcode cache reset (no sudo).
[xc-reset] 1) Print current Xcode toolchain and SDK info
> xcode-select -p
> xcrun --show-sdk-path --sdk iphoneos
> xcrun --show-sdk-path --sdk iphonesimulator
[xc-reset] 2) Advise: Close Xcode before proceeding
# Please close Xcode and any running simulators before continuing.
[xc-reset] 3) Purge ModuleCache + DerivedData (user Library)
> rm -rf /Users/you/Library/Developer/Xcode/DerivedData/ModuleCache.noindex
[xc-reset] 4) Clean SwiftPM caches for this project (resolve later in Xcode)
[xc-reset] 5) Project-local artifacts (no delete by default)
[xc-reset] Found .modulecache/ in repo (non-standard). Consider removing it: rm -rf .modulecache
[xc-reset] 6) Next steps
...
[xc-reset] Done.
```

---
最終更新: 2025-10-19

