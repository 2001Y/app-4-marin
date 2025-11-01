#!/usr/bin/env bash
set -euo pipefail

log() { printf "[xc-reset] %s\n" "$*"; }

log "Starting Xcode cache reset (no sudo)."
DATE_TAG="$(date +%Y%m%d-%H%M%S)"

show_cmd() { printf "> %s\n" "$*"; }

log "1) Print current Xcode toolchain and SDK info"
show_cmd xcode-select -p || true
show_cmd "xcrun --show-sdk-path --sdk iphoneos" || true
show_cmd "xcrun --show-sdk-path --sdk iphonesimulator" || true

log "2) Advise: Close Xcode before proceeding"
echo "# Please close Xcode and any running simulators before continuing." >&2

log "3) Purge ModuleCache + DerivedData (user Library)"
USER_DD="$HOME/Library/Developer/Xcode/DerivedData"
if [ -d "$USER_DD" ]; then
  show_cmd "rm -rf $USER_DD/ModuleCache.noindex"
  rm -rf "$USER_DD/ModuleCache.noindex" || true
  # Optional: fully wipe DerivedData (uncomment next line if問題が継続する場合)
  # rm -rf "$USER_DD"/*
else
  log "DerivedData not found at $USER_DD (skipped)"
fi

log "4) Clean SwiftPM caches for this project (resolve later in Xcode)"
if [ -d ".build" ]; then
  show_cmd "rm -rf .build"
  rm -rf .build || true
fi

log "5) Project-local artifacts (no delete by default)"
if [ -d "DerivedData" ]; then
  log "Found project-local DerivedData/ (this is unusual). Consider removing it manually."
fi
if [ -d ".modulecache" ]; then
  log "Found .modulecache/ in repo (non-standard). Consider removing it: rm -rf .modulecache"
fi

log "6) Next steps"
cat <<'EOS'
- Reopen Xcode → Product > Clean Build Folder (Shift+Cmd+K)
- Product > Build で再ビルド
- 必要なら File > Packages > Reset Package Caches / Resolve Package Versions

検証:
- ビルドログに "No such file or directory" for *.pcm が再度出ないこと
- Xcodeの Locations > Command Line Tools が使用中のXcodeと一致していること
  (CLI: `xcode-select -p` の結果とXcodeの表示が同じ)
EOS

log "Done."

