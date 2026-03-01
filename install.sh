#!/bin/bash
#
# claude-statusline インストーラー
# ~/.claude/ にシンボリックリンクを作成し、設定方法を案内する
#

set -euo pipefail

# 色定義
RED=$'\033[91m'
GREEN=$'\033[92m'
YELLOW=$'\033[93m'
BLUE=$'\033[94m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# スクリプト自身のディレクトリ（リポジトリルート）
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

echo ""
echo "${BOLD}claude-statusline インストーラー${RESET}"
echo "================================"
echo ""

# 前提条件チェック
errors=0

# bun チェック
if ! command -v bun >/dev/null 2>&1; then
    echo "${YELLOW}警告:${RESET} bun が見つかりません"
    echo "  高解像度バー表示には bun が必要です"
    echo "  インストール: ${BLUE}curl -fsSL https://bun.sh/install | bash${RESET}"
    echo ""
    errors=$((errors + 1))
fi

# jq チェック
if ! command -v jq >/dev/null 2>&1; then
    echo "${RED}エラー:${RESET} jq が見つかりません"
    echo "  インストール: ${BLUE}brew install jq${RESET}"
    echo ""
    errors=$((errors + 1))
fi

# Claude Code ディレクトリチェック
if [ ! -d "$CLAUDE_DIR" ]; then
    echo "${RED}エラー:${RESET} ~/.claude/ が見つかりません"
    echo "  Claude Code を先にインストールしてください"
    echo ""
    exit 1
fi

if [ "$errors" -gt 0 ]; then
    echo "${YELLOW}上記の警告・エラーを確認してから続行してください${RESET}"
    echo ""
    read -p "続行しますか？ [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "中断しました"
        exit 1
    fi
    echo ""
fi

# シンボリックリンク作成
echo "${BOLD}シンボリックリンクを作成...${RESET}"

for file in statusline-handler.sh bar-renderer.ts; do
    src="${REPO_DIR}/${file}"
    dst="${CLAUDE_DIR}/${file}"

    if [ -L "$dst" ]; then
        current_target=$(readlink "$dst")
        if [ "$current_target" = "$src" ]; then
            echo "  ${GREEN}✓${RESET} ${file} （既にリンク済み）"
            continue
        else
            echo "  ${YELLOW}→${RESET} ${file} （リンク先を更新: ${current_target} → ${src}）"
            ln -sf "$src" "$dst"
        fi
    elif [ -f "$dst" ]; then
        echo "  ${YELLOW}→${RESET} ${file} （既存ファイルをバックアップ: ${dst}.bak）"
        mv "$dst" "${dst}.bak"
        ln -s "$src" "$dst"
    else
        echo "  ${GREEN}+${RESET} ${file}"
        ln -s "$src" "$dst"
    fi
done

echo ""
echo "${GREEN}インストール完了！${RESET}"
echo ""

# settings.json への設定案内
echo "${BOLD}次のステップ:${RESET}"
echo ""
echo "~/.claude/settings.json に以下を追加してください:"
echo ""
echo "${BLUE}  \"statusLine\": {"
echo "    \"type\": \"command\","
echo "    \"command\": \"cat | bash ~/.claude/statusline-handler.sh\""
echo "  }${RESET}"
echo ""
echo "例（既存の settings.json にマージ）:"
echo ""
echo "  ${BLUE}vim ~/.claude/settings.json${RESET}"
echo ""
echo "設定後、Claude Code を再起動すると statusline が表示されます。"
echo ""

# 動作確認コマンドの案内
echo "${BOLD}動作確認:${RESET}"
echo ""
echo '  echo '"'"'{"model":{"display_name":"Opus 4.6"},"session_id":"test","cwd":"/tmp","context_window":{"used_percentage":29}}'"'"' | bash ~/.claude/statusline-handler.sh'
echo ""
