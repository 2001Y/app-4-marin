# SwiftData FetchDescriptor と ChatRoom モデル修正メモ

## 背景
- `FetchDescriptor` の初期化時に `fetchLimit` を指定していたが、公式ドキュメントではプロパティで指定するのが推奨となっており、引数を受け取るイニシャライザは存在しない。 doc/websites/developer_apple_swiftdata
- `ChatRoom` の `participants` は `Data` へのシリアライズを介した擬似ストレージだが、`@Model` マクロがストアドプロパティとして扱おうとするため、トランジェント指定が必要だった。

## 変更方針
1. `FetchDescriptor` を `var` として生成し、`fetchLimit` をプロパティ経由で設定する。
2. `modelContext.fetch` の結果に対する `try?` はフェッチ本体にかかるよう `(...)?` を用いてエラーを握り潰す従来の意図を維持する。
3. `ChatRoom.participants` に `@Transient` を付与し、ストレージとの整合性を保ちつつマクロ生成エラーを防止する。

## 今後の確認項目
- Xcode でビルドして SwiftData マクロ生成が正しく完了することを確認する。
- `participants` のデータ破損時の復元ロジック（現状ログのみ）を要件次第で強化するか検討する。
