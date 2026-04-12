#!/bin/bash
set -e

APP_NAME="process_management"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> 実行中のアプリを停止..."
pkill -x "$APP_NAME" 2>/dev/null && echo "    停止しました" || echo "    起動中のプロセスなし"

echo "==> ビルド中..."
# ⚠️ 署名は Xcode GUI ビルドと完全に同じにしないとダメ。
# TCC (アクセシビリティ権限) はバイナリの "code requirement" で紐付けされる。
# Xcode GUI → Apple Development: tomoemon3022@icloud.com (5Q2VXYR4SR)
# ad-hoc (-) や unsigned だと TCC 上は "別のアプリ" 扱いになり、
# Xcode 版に付与した権限が無視されて ⌘⇧Space が効かず OS がビープを鳴らす。
#
# なので Automatic 署名 + DEVELOPMENT_TEAM で Xcode と同じ cert を使う。
# keychain に "Apple Development: ..." がある必要あり:
#   security find-identity -v -p codesigning
SIGN_FLAGS=(
  CODE_SIGN_IDENTITY="Apple Development"
  CODE_SIGN_STYLE="Automatic"
  DEVELOPMENT_TEAM="5Q2VXYR4SR"
)

xcodebuild \
  -project "$PROJECT_DIR/${APP_NAME}.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  "${SIGN_FLAGS[@]}" \
  2>&1 | grep -E "(error:|warning: Stale|BUILD SUCCEEDED|BUILD FAILED)"

APP_PATH=$(xcodebuild \
  -project "$PROJECT_DIR/${APP_NAME}.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  "${SIGN_FLAGS[@]}" \
  -showBuildSettings 2>/dev/null \
  | grep "BUILT_PRODUCTS_DIR" | head -1 | awk '{print $3}')

APP_BUNDLE="$APP_PATH/$APP_NAME.app"

# 署名の検証 (Xcode GUI 版と同じ Authority / flags になっているか)
# NOTE: Authority 行を出すには `codesign -dvv` 以上が必要 (`-dv` だと省略される)。
echo "==> 署名検証"
CS_OUT=$(codesign -dvv "$APP_BUNDLE" 2>&1)
AUTH_LINE=$(echo "$CS_OUT" | grep "Authority=Apple Development" || true)
HAS_RUNTIME=$(echo "$CS_OUT" | grep -c "flags=.*runtime" || true)
if [[ -z "$AUTH_LINE" || "$HAS_RUNTIME" == "0" ]]; then
  echo "    ❌ Xcode GUI 版と同じ署名になっていません"
  echo "$CS_OUT" | grep -E "Identifier|Authority|flags|TeamIdentifier" | sed 's/^/       /'
  echo "    → ⌘⇧Space グローバルホットキーは動かない可能性"
  echo "    → keychain に Apple Development cert があるか: security find-identity -v -p codesigning"
  exit 1
else
  echo "    ✅ $AUTH_LINE"
  echo "    ✅ hardened runtime 有効"
fi

echo "==> 起動中: $APP_BUNDLE"
open "$APP_BUNDLE"
