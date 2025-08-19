#!/bin/bash

# アプリアイコンのアルファチャンネル除去スクリプト
# ダブルクリックで実行可能

# スクリプトの場所に移動
cd "$(dirname "$0")"

echo "==================================="
echo "4-Marin アプリアイコン修正ツール"
echo "==================================="

# アイコンファイルのパス
ICON_PATH="forMarin/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

# ファイルの存在確認
if [ ! -f "$ICON_PATH" ]; then
    echo "❌ エラー: アイコンファイルが見つかりません"
    echo "   パス: $ICON_PATH"
    echo ""
    echo "Enterキーを押して終了..."
    read
    exit 1
fi

# ImageMagickの確認
if ! command -v magick &> /dev/null && ! command -v convert &> /dev/null; then
    echo "❌ エラー: ImageMagickがインストールされていません"
    echo "   インストール方法: brew install imagemagick"
    echo ""
    echo "Enterキーを押して終了..."
    read
    exit 1
fi

echo "📋 処理前のファイル情報:"
file "$ICON_PATH"
echo ""

# アルファチャンネル除去処理
echo "🔧 アルファチャンネルを除去中..."
if command -v magick &> /dev/null; then
    magick "$ICON_PATH" -background white -alpha remove -alpha off "$ICON_PATH"
else
    convert "$ICON_PATH" -background white -alpha remove -alpha off "$ICON_PATH"
fi

if [ $? -eq 0 ]; then
    echo "✅ 処理完了!"
    echo ""
    echo "📋 処理後のファイル情報:"
    file "$ICON_PATH"
    echo ""
    echo "🎉 アプリアイコンからアルファチャンネルが除去されました"
    echo "   App Storeへの提出が可能になりました"
else
    echo "❌ 処理中にエラーが発生しました"
fi

echo ""
echo "Enterキーを押して終了..."
read