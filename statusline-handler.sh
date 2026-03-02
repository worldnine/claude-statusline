#!/bin/bash
#
# Claude Code Statusline Handler
# ===============================
# Anthropic Usage API による利用率表示と
# コンテキスト使用率をリアルタイムで statusline に表示
#
# 表示レイアウト:
# 1行目: * Opus 4.6   29% ██▉░░░░░░░ 142.2K   58% ███▍│░░░░░ 6pm   5% ▎│░░░░░░░░░ 3/8
# （バーは背景色+eighth-block遷移セルで80段階の高解像度表示、bun依存）
# 2行目:  my-project  main +10 -5
#
# 使用方法:
# ~/.claude/settings.json に以下を設定:
#   "statusLine": {
#     "type": "command",
#     "command": "cat | bash ~/.claude/statusline-handler.sh"
#   }
#
# テスト方法:
#   echo '{"model":{"display_name":"Opus 4.6"},"session_id":"test","cwd":"/tmp","context_window":{"used_percentage":29}}' | bash ~/.claude/statusline-handler.sh
#
# デバッグモード:
#   DEBUG_STATUSLINE=1 を設定すると詳細ログが出力される
#

# スクリプト自身のディレクトリを基準にパスを解決
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# bun のパス補完（シェルプロファイルが未ロードの環境用）
[ -d "$HOME/.bun/bin" ] && export PATH="$HOME/.bun/bin:$PATH"

USAGE_CACHE="/tmp/claude-statusline-usage.json"
USAGE_CACHE_TTL=60  # キャッシュ有効期間（秒）
CONTEXT_MAX_TOKENS=200000  # コンテキスト制限の概算値（トークン数表示の概算用）
BAR_RENDERER="${SCRIPT_DIR}/bar-renderer.ts"  # 高解像度バーレンダラー（bun実行）

# アイコン設定
setup_icons() {
    ICON_TERMINAL="*"
    ICON_FOLDER=$'\xef\x81\xbb'    # U+F07B nf-fa-folder (フォルダ)
    ICON_GIT=$'\xee\x9c\xa5'       # U+E725 nf-dev-git (git)
    ICON_TAG=$'\xef\x80\xab'       # U+F02B nf-fa-tag (ブランチ)
    ICON_LEAF=$'\xef\x81\xac'      # U+F06C nf-fa-leaf (ワークツリー)
    ICON_CONTEXT=$'\xef\x80\xad'   # U+F02D nf-fa-book (本)
    ICON_5HR=$'\xf3\xb1\x91\x83'   # U+F1443 nf-md-clock_time_five (5時の時計)
    ICON_7DAY=$'\xef\x81\xb3'      # U+F073 nf-fa-calendar (カレンダー)
}

# カラー設定
setup_colors() {
    if [ -n "$NO_COLOR" ] || [ "$USE_COLORS" = "false" ]; then
        COLOR_RESET=""
        COLOR_DEFAULT=""
        COLOR_BLUE=""
        COLOR_PINK=""
        COLOR_GREEN=""
        COLOR_RED=""
        COLOR_BRIGHT_GREEN=""
        COLOR_ORANGE=""
        COLOR_DIM=""
    else
        COLOR_RESET=$'\033[0m'
        COLOR_DEFAULT=$'\033[39m'  # 前景色のみデフォルトに戻す（statusline環境用）
        COLOR_BLUE=$'\033[38;5;68m'
        COLOR_PINK=$'\033[38;5;168m'
        COLOR_GREEN=$'\033[38;5;71m'
        COLOR_RED=$'\033[38;5;167m'
        COLOR_BRIGHT_GREEN=$'\033[38;5;71m'
        COLOR_ORANGE=$'\033[38;5;208m'
        COLOR_DIM=$'\033[38;5;242m'
    fi
}

# ディレクトリパスフォーマッター
# HOME配下は ~/relative/path、HOME自体は ~、それ以外は絶対パス
format_dir_path() {
    local dir="$1"
    [ -z "$dir" ] && return
    case "$dir" in
        "$HOME") printf '~' ;;
        "$HOME"/*) printf '~/%s' "${dir#$HOME/}" ;;
        *) printf '%s' "$dir" ;;
    esac
}

# 親パス部分のみを返す（basename を除いた prefix）
# 例: ~/src/claude-statusline → "~/src/"、~/project → ""、/tmp/test → "/tmp/"
format_parent_path() {
    local dir="$1"
    [ -z "$dir" ] && return
    local formatted
    case "$dir" in
        "$HOME") return ;;
        "$HOME"/*) formatted="~/${dir#$HOME/}" ;;
        *) formatted="$dir" ;;
    esac
    local parent="${formatted%/*}"
    [ "$parent" = "$formatted" ] && return  # スラッシュなし = 親なし
    printf '%s/' "$parent"
}

# パスをターミナル幅に収まるよう左側から切り詰め
# $1: パス文字列  $2: 最大幅（省略時は切り詰めなし）
truncate_path() {
    local path="$1" max_width="$2"
    [ -z "$max_width" ] || [ "$max_width" -le 0 ] 2>/dev/null && { printf '%s' "$path"; return; }
    local len=${#path}
    [ "$len" -le "$max_width" ] && { printf '%s' "$path"; return; }
    # 最大幅から "…/" の2文字分を引いた長さで右側を取得
    local keep=$((max_width - 2))
    local suffix="${path:$((len - keep))}"
    # / 境界に揃える
    case "$suffix" in
        */*) suffix="${suffix#*/}"; printf '…/%s' "$suffix" ;;
        *) printf '…%s' "$suffix" ;;
    esac
}

# Usage API からデータ取得
# macOS Keychain から OAuth トークンを取得し、利用率エンドポイントを呼び出す
fetch_usage() {
    local creds token response
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
    token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken') || return 1
    [ -z "$token" ] || [ "$token" = "null" ] && return 1
    response=$(curl -s --max-time 3 "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" 2>/dev/null) || return 1
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        return 1
    fi
    echo "$response" > "$USAGE_CACHE"
}

# キャッシュ付きUsageデータ取得（TTL超過時のみAPI再取得）
get_usage_data() {
    local now cache_mtime age
    now=$(date "+%s")
    cache_mtime=0
    if [ -f "$USAGE_CACHE" ]; then
        cache_mtime=$(stat -f "%m" "$USAGE_CACHE" 2>/dev/null || echo "0")
    fi
    age=$((now - cache_mtime))
    if [ "$age" -ge "$USAGE_CACHE_TTL" ]; then
        fetch_usage
    fi
    if [ -f "$USAGE_CACHE" ]; then
        cat "$USAGE_CACHE"
    fi
}

# 使用率に応じた色（ペーシングターゲット基準）
# $1: 使用率(0-100)  $2: ペーシングターゲット(0-100, 省略可)
# ≥80% → 赤、ペース超過かつ12%以上 → オレンジ、それ以外 → デフォルト
color_for_pct() {
    local pct=$1 target=${2:-}
    if [ "$pct" -ge 80 ]; then
        printf '%s' $'\033[91m'
    elif [ -n "$target" ] && [ "$pct" -gt "$target" ] && [ "$pct" -ge 12 ]; then
        printf '%s' $'\033[38;5;208m'
    else
        printf '%s' $'\033[39m'
    fi
}

# コンテキスト使用率に応じた色（既存ロジック維持: <50% デフォルト、50-80% オレンジ、>80% 赤）
get_context_color() {
    local pct=$1
    if [ "$pct" -ge 80 ]; then
        echo "$COLOR_RED"
    elif [ "$pct" -ge 50 ]; then
        echo "$COLOR_ORANGE"
    else
        echo "$COLOR_DEFAULT"
    fi
}

# コンテキスト使用率に応じた色名（bar-renderer.ts 用）
# get_context_color() と同じ閾値（<50% デフォルト、50-80% オレンジ、≥80% 赤）
context_color_name() {
    local pct=$1
    if [ "$pct" -ge 80 ]; then echo "red"
    elif [ "$pct" -ge 50 ]; then echo "orange"
    else echo "default"
    fi
}

# 使用率に応じた色名（bar-renderer.ts 用）
# $1: 使用率(0-100)  $2: ペーシングターゲット(0-100, 省略可)
# color_for_pct() と同じロジックで色名を返す
color_name_for_pct() {
    local pct=$1 target=${2:-}
    if [ "$pct" -ge 80 ]; then
        echo "red"
    elif [ -n "$target" ] && [ "$pct" -gt "$target" ] && [ "$pct" -ge 12 ]; then
        echo "orange"
    else
        echo "default"
    fi
}

# ペーシングターゲット計算
# ウィンドウ内の経過時間の割合を0-100で返す
# $1: resets_at (UTC ISO 8601, 例: "2026-02-08T04:59:59.000000+00:00")
# $2: ウィンドウ秒数 (5hr=18000, 7d=604800)
calc_pacing_target() {
    local resets_at="$1"
    local window_secs="$2"
    [ -z "$resets_at" ] || [ "$resets_at" = "null" ] && return
    local trimmed="${resets_at%%.*}"
    local reset_epoch now_epoch elapsed
    reset_epoch=$(date -ujf "%Y-%m-%dT%H:%M:%S" "$trimmed" "+%s" 2>/dev/null) || return
    now_epoch=$(date "+%s")
    elapsed=$((window_secs - (reset_epoch - now_epoch)))
    [ "$elapsed" -lt 0 ] && elapsed=0
    [ "$elapsed" -gt "$window_secs" ] && elapsed=$window_secs
    echo $((elapsed * 100 / window_secs))
}

# リセットまでの残り時間をフォーマット
# 1日以上 → "4d"、1時間以上 → "3h"、1時間未満 → "42m"
format_remaining() {
    local resets_at="$1"
    local trimmed="${resets_at%%.*}"
    local reset_epoch now_epoch remaining
    reset_epoch=$(date -ujf "%Y-%m-%dT%H:%M:%S" "$trimmed" "+%s" 2>/dev/null) || return
    now_epoch=$(date "+%s")
    remaining=$((reset_epoch - now_epoch))
    [ "$remaining" -lt 0 ] && remaining=0
    if [ "$remaining" -ge 86400 ]; then
        echo "$((remaining / 86400))d"
    elif [ "$remaining" -ge 3600 ]; then
        echo "$((remaining / 3600))h"
    else
        echo "$((remaining / 60))m"
    fi
}

# メイン処理
main() {
    setup_icons
    setup_colors

    local term_width
    term_width=$(tput cols 2>/dev/null || echo "80")

    input=$(cat)

    # デバッグモード
    if [ "${DEBUG_STATUSLINE:-}" = "1" ]; then
        echo "=== INPUT JSON ===" >&2
        echo "$input" | jq '.' >&2 2>/dev/null || echo "$input" >&2
        echo "==================" >&2
    fi

    # 入力JSONからデータ取得
    model_display=$(echo "$input" | jq -r '.model.display_name // "Unknown"' 2>/dev/null)
    cwd=$(echo "$input" | jq -r '.cwd' 2>/dev/null)
    workspace_dir=$(echo "$input" | jq -r '.workspace.current_dir' 2>/dev/null)
    project=$(basename "$workspace_dir" 2>/dev/null)
    project_dir="$workspace_dir"

    # コンテキスト使用率（Claude Code の JSON から直接取得）
    context_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' 2>/dev/null)
    context_tokens=$(echo "$input" | jq -r '.context_window.used // 0' 2>/dev/null)
    context_window_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0' 2>/dev/null)

    # トークン数が取得できない場合はパーセンテージから概算
    if [ "$context_tokens" -le 0 ] 2>/dev/null && [ "$context_pct" -gt 0 ] 2>/dev/null; then
        context_tokens=$((context_pct * CONTEXT_MAX_TOKENS / 100))
    fi

    # 残りトークン数の計算（フォールバック順: size-used → size×残り% → 200000×残り%）
    remaining_tokens=0
    if [ "$context_pct" -gt 0 ] 2>/dev/null; then
        if [ "$context_window_size" -gt 0 ] 2>/dev/null && [ "$context_tokens" -gt 0 ] 2>/dev/null; then
            remaining_tokens=$((context_window_size - context_tokens))
        elif [ "$context_window_size" -gt 0 ] 2>/dev/null; then
            remaining_tokens=$((context_window_size * (100 - context_pct) / 100))
        else
            remaining_tokens=$((CONTEXT_MAX_TOKENS * (100 - context_pct) / 100))
        fi
        [ "$remaining_tokens" -lt 0 ] && remaining_tokens=0
    fi

    # Git情報
    branch=""
    if [ -n "$cwd" ]; then
        branch=$(cd "$cwd" 2>/dev/null && git branch --show-current 2>/dev/null)
    fi

    # Worktree検出
    is_worktree=false
    if [ -n "$branch" ] && [ -n "$cwd" ]; then
        git_common_dir=$(cd "$cwd" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd)
        git_dir=$(cd "$cwd" 2>/dev/null && cd "$(git rev-parse --git-dir 2>/dev/null)" 2>/dev/null && pwd)
        if [ -n "$git_common_dir" ] && [ -n "$git_dir" ] && [ "$git_common_dir" != "$git_dir" ]; then
            is_worktree=true
        fi
    fi

    # Git差分統計
    git_stats=""
    if [ -n "$branch" ] && [ -n "$cwd" ]; then
        stats=$(cd "$cwd" 2>/dev/null && git diff --shortstat 2>/dev/null)
        if [ -n "$stats" ]; then
            insertions=$(echo "$stats" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
            deletions=$(echo "$stats" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
            if [ "$insertions" != "0" ] || [ "$deletions" != "0" ]; then
                git_stats=$(printf ' %s+%s%s %s-%s%s' "$COLOR_GREEN" "$insertions" "$COLOR_RESET" "$COLOR_RED" "$deletions" "$COLOR_RESET")
            fi
        fi
    fi

    # === 1行目: モデル名 + コンテキスト + Usage ===
    line1=$(printf '%s%s %s%s' "$COLOR_ORANGE" "$ICON_TERMINAL" "$model_display" "$COLOR_DEFAULT")

    # コンテキスト表示の準備（バーは後でbunバッチ呼び出し後に追加）
    ctx_bar=""
    ctx_color_nm=""
    remaining_display=""
    if [ "$context_pct" -gt 0 ] 2>/dev/null; then
        # 残りトークン数のフォーマット
        if [ "$remaining_tokens" -gt 0 ] 2>/dev/null; then
            if [ "$remaining_tokens" -ge 1000000 ]; then
                remaining_display=$(echo "$remaining_tokens" | awk '{printf "%.1fM", $1/1000000}')
            elif [ "$remaining_tokens" -ge 1000 ]; then
                remaining_display=$(echo "$remaining_tokens" | awk '{printf "%.1fK", $1/1000}')
            else
                remaining_display="$remaining_tokens"
            fi
        fi
        ctx_color=$(get_context_color "$context_pct")
        ctx_color_nm=$(context_color_name "$context_pct")
    fi

    # Usage APIデータ取得
    usage_data=$(get_usage_data)
    five_valid=false; seven_valid=false
    five_bar=""; seven_bar=""
    if [ -n "$usage_data" ]; then
        # データ抽出
        five_hr_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' 2>/dev/null | awk '{printf "%d", $1}')
        five_hr_reset=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
        seven_day_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' 2>/dev/null | awk '{printf "%d", $1}')
        seven_day_reset=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)

        # 各枠の計算（色・ターゲット・リセット時刻）
        five_target="" five_color="" five_color_name="" five_reset_str=""
        if [ -n "$five_hr_pct" ] && [ "$five_hr_pct" != "null" ]; then
            five_valid=true
            five_target=$(calc_pacing_target "$five_hr_reset" 18000)
            five_color=$(color_for_pct "$five_hr_pct" "$five_target")
            five_color_name=$(color_name_for_pct "$five_hr_pct" "$five_target")
            if [ -n "$five_hr_reset" ] && [ "$five_hr_reset" != "null" ]; then
                five_reset_str=$(format_remaining "$five_hr_reset")
            fi
        fi

        seven_target="" seven_color="" seven_color_name="" seven_reset_str=""
        if [ -n "$seven_day_pct" ] && [ "$seven_day_pct" != "null" ]; then
            seven_valid=true
            seven_target=$(calc_pacing_target "$seven_day_reset" 604800)
            seven_color=$(color_for_pct "$seven_day_pct" "$seven_target")
            seven_color_name=$(color_name_for_pct "$seven_day_pct" "$seven_target")
            if [ -n "$seven_day_reset" ] && [ "$seven_day_reset" != "null" ]; then
                seven_reset_str=$(format_remaining "$seven_day_reset")
            fi
        fi
    fi

    # バーを1回のbun呼び出しでまとめて描画（コンテキスト + Usage）
    bar_args=()
    ctx_bar_requested=false
    if [ -n "$ctx_color_nm" ]; then
        ctx_bar_requested=true
        bar_args+=("$context_pct" "10" "-1" "$ctx_color_nm")
    fi
    if $five_valid; then
        $ctx_bar_requested && bar_args+=("--")
        bar_args+=("$five_hr_pct" "10" "${five_target:--1}" "$five_color_name")
    fi
    if $seven_valid; then
        { $ctx_bar_requested || $five_valid; } && bar_args+=("--")
        bar_args+=("$seven_day_pct" "10" "${seven_target:--1}" "$seven_color_name")
    fi

    if [ ${#bar_args[@]} -gt 0 ]; then
        bar_output=$(bun run "$BAR_RENDERER" "${bar_args[@]}" 2>/dev/null)
        _rest="$bar_output"
        if $ctx_bar_requested; then ctx_bar="${_rest%%$'\n'*}"; _rest="${_rest#*$'\n'}"; fi
        if $five_valid; then five_bar="${_rest%%$'\n'*}"; _rest="${_rest#*$'\n'}"; fi
        if $seven_valid; then seven_bar="${_rest%%$'\n'*}"; fi
    fi

    # コンテキスト → line1
    if [ "$context_pct" -gt 0 ] 2>/dev/null; then
        if [ -n "$ctx_bar" ]; then
            if [ -n "$remaining_display" ]; then
                line1="${line1}  ${ctx_color}${ICON_CONTEXT}  ${context_pct}%${COLOR_DEFAULT} ${ctx_bar} ${ctx_color}${remaining_display}${COLOR_DEFAULT}"
            else
                line1="${line1}  ${ctx_color}${ICON_CONTEXT}  ${context_pct}%${COLOR_DEFAULT} ${ctx_bar}"
            fi
        else
            # bunが利用不可の場合のフォールバック
            if [ -n "$remaining_display" ]; then
                line1="${line1}  ${ctx_color}${ICON_CONTEXT}  ${context_pct}% ${remaining_display}${COLOR_DEFAULT}"
            else
                line1="${line1}  ${ctx_color}${ICON_CONTEXT}  ${context_pct}%${COLOR_DEFAULT}"
            fi
        fi
    fi

    # Usage 5hr/7day → line1
    if $five_valid; then
        if [ -n "$five_reset_str" ]; then
            line1="${line1}  ${five_color}${ICON_5HR}  ${five_hr_pct}% ${five_bar}${COLOR_DEFAULT} ${five_reset_str}"
        else
            line1="${line1}  ${five_color}${ICON_5HR}  ${five_hr_pct}% ${five_bar}${COLOR_DEFAULT}"
        fi
    fi
    if $seven_valid; then
        if [ -n "$seven_reset_str" ]; then
            line1="${line1}  ${seven_color}${ICON_7DAY}  ${seven_day_pct}% ${seven_bar}${COLOR_DEFAULT} ${seven_reset_str}"
        else
            line1="${line1}  ${seven_color}${ICON_7DAY}  ${seven_day_pct}% ${seven_bar}${COLOR_DEFAULT}"
        fi
    fi

    # 1行目出力
    printf "%s\n" "$line1"

    # === 2行目: Git情報（git リポジトリの場合のみ） ===
    if [ -n "$branch" ]; then
        if $is_worktree; then
            # WT: GIT + BLUE(リポ名) + LEAF + GREEN(ブランチ) + stats
            local repo_dir repo_name
            repo_dir=$(cd "$git_common_dir/.." 2>/dev/null && pwd)
            repo_name=$(basename "$repo_dir")
            printf '%s%s %s%s  %s%s  %s%s%s\n' \
                "$COLOR_BLUE" "$ICON_GIT" \
                "$repo_name" "$COLOR_DEFAULT" \
                "$COLOR_BRIGHT_GREEN" "$ICON_LEAF" \
                "$branch" "$COLOR_DEFAULT" \
                "$git_stats"
        else
            # 通常 git: GIT + BLUE(プロジェクト名) + TAG + PINK(ブランチ) + stats
            printf '%s%s %s%s  %s%s  %s%s%s\n' \
                "$COLOR_BLUE" "$ICON_GIT" \
                "$project" "$COLOR_DEFAULT" \
                "$COLOR_PINK" "$ICON_TAG" \
                "$branch" "$COLOR_DEFAULT" \
                "$git_stats"
        fi
    fi

    # === 最終行: フルパス（DIM、フォルダアイコン付き、幅制限） ===
    if [ -n "$project_dir" ]; then
        local path_display
        path_display=$(truncate_path "$(format_dir_path "$project_dir")" "$((term_width - 3))")
        printf '%s%s  %s%s' "$COLOR_DIM" "$ICON_FOLDER" "$path_display" "$COLOR_DEFAULT"
    fi
}

# スクリプトを実行
main "$@"
