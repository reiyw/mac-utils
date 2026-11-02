#!/bin/bash
# extdisplay をビルドして ~/.local/bin に入れ、メニューバー常駐をログイン時に自動起動させる
#
#   ./install.sh            ビルド＋インストール＋常駐（自動起動）登録
#   ./install.sh --no-agent ビルド＋インストールのみ（CLI だけ使う場合）
#   ./install.sh --uninstall
set -euo pipefail

cd "$(dirname "$0")"

BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/extdisplay"
LABEL="local.extdisplay.menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

unload_agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  # bootout は非同期なので、消えるまで待たないと直後の bootstrap が失敗する（error 5）
  for _ in $(seq 1 50); do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
}

if [[ "${1:-}" == "--uninstall" ]]; then
  [[ -x "$BIN" ]] && "$BIN" on || true   # 無効化中なら戻してから消す
  unload_agent
  rm -f "$PLIST" "$BIN" "$HOME/.extdisplay-disabled"
  echo "アンインストールしました"
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc が見つかりません。先に次を実行してください: xcode-select --install" >&2
  exit 1
fi

echo "ビルド中..."
mkdir -p "$BIN_DIR"
swiftc -O extdisplay.swift -o "$BIN"
echo "インストール: $BIN"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "注意: $BIN_DIR が PATH にありません。~/.zshrc に次を追加してください:"
     echo "  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

if [[ "${1:-}" == "--no-agent" ]]; then
  exit 0
fi

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>menubar</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/extdisplay.stdout.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/extdisplay.stderr.log</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF

unload_agent
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "メニューバー常駐を起動しました（ログイン時に自動起動）。⌃⌥⌘D で切り替えできます"
