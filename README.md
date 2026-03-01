# claude-statusline

Claude Code の statusline にモデル名・コンテキスト使用率・Usage API 利用率を表示するスクリプト。

## 表示例

```
* Opus 4.6    29%  ██▉░░░░░░░ 142.2K    58% ███▍│░░░░░ 2h    5% ▎│░░░░░░░░░ 6d
[WT] my-project on git feature/auth +10 -5
```

### 1行目

| セクション | 説明 |
|-----------|------|
| `* Opus 4.6` | 使用中のモデル名 |
| `29% ██▉░░░░░░░ 142.2K` | コンテキスト使用率（%・バー・残りトークン数） |
| `58% ███▍│░░░░░ 2h` | 5時間枠の Usage 利用率（`│` はペーシングターゲット） |
| `5% ▎│░░░░░░░░░ 6d` | 7日枠の Usage 利用率 |

### 2行目

| セクション | 説明 |
|-----------|------|
| `[WT]` | Git Worktree 内の場合に表示 |
| `my-project` | プロジェクト名 |
| `git feature/auth` | 現在のブランチ |
| `+10 -5` | 未コミットの差分（挿入/削除行数） |

### バー表示

背景色 + eighth-block 遷移セル（▏▎▍▌▋▊▉）で **10セル × 8段階 = 80段階** の高解像度表示。ペーシングターゲット位置に `│` マーカーを描画します。

### 色ロジック

**コンテキスト使用率:**
- デフォルト色: 50% 未満
- オレンジ: 50〜80%
- 赤: 80% 以上

**Usage 利用率（5時間/7日）:**
- デフォルト色: 通常
- オレンジ: ペーシングターゲット超過 かつ 12% 以上
- 赤: 80% 以上

## 前提条件

- **macOS**（Keychain / BSD date / BSD stat に依存）
- **Claude Code**（statusline 機能を使用）
- **bun**（高解像度バー描画に必要）
- **jq**（JSON パース）
- **Nerd Font**（アイコン表示する場合。なくても動作可能）

## インストール

```bash
git clone <repository-url> ~/src/claude-statusline
cd ~/src/claude-statusline
bash install.sh
```

インストーラーが以下を行います:

1. `~/.claude/` に `statusline-handler.sh` と `bar-renderer.ts` のシンボリックリンクを作成
2. `settings.json` への設定追加方法を表示

### settings.json の設定

`~/.claude/settings.json` に以下を追加してください:

```json
{
  "statusLine": {
    "type": "command",
    "command": "cat | bash ~/.claude/statusline-handler.sh"
  }
}
```

設定後、Claude Code を再起動すると statusline が表示されます。

## 動作確認

```bash
echo '{"model":{"display_name":"Opus 4.6"},"session_id":"test","cwd":"/tmp","context_window":{"used_percentage":29}}' | bash ~/.claude/statusline-handler.sh
```

## カスタマイズ

### アイコン

`statusline-handler.sh` 内の `setup_icons()` でアイコン文字を変更できます:

```bash
setup_icons() {
    ICON_TERMINAL="*"        # モデル名の前
    ICON_TREE="[WT]"         # Worktree表示
    ICON_CONTEXT=$'\xef\x80\xad'   # コンテキスト (nf-fa-book)
    ICON_5HR=$'\xef\x80\x97'       # 5時間枠 (nf-fa-clock_o)
    ICON_7DAY=$'\xef\x81\xb3'      # 7日枠 (nf-fa-calendar)
}
```

Nerd Font を使わない場合はプレーンテキストに置き換えてください:

```bash
ICON_CONTEXT="CTX"
ICON_5HR="5h"
ICON_7DAY="7d"
```

### バー幅

バーのセル幅はデフォルトで 10 セルです。`statusline-handler.sh` 内の `bar_args` で変更できます。例えば 15 セル幅にする場合:

```bash
bar_args+=("$context_pct" "15" "-1" "$ctx_color_nm")
```

### 色

`bar-renderer.ts` 内の `FILLED` / `EMPTY` / `MARKER` で xterm-256 色番号を変更できます:

```typescript
const FILLED: Record<ColorName, number> = {
  default: 60,  // 落ち着いたブルーパープル
  orange: 130,  // 暖色系アンバー
  red: 131,     // 暖色系レッド
};
const EMPTY = 236;    // 暗いグレー背景
const MARKER = 174;   // 淡ピンクのペーシングマーカー
```

### デバッグ

入力 JSON と内部状態を確認するには:

```bash
DEBUG_STATUSLINE=1 echo '...' | bash ~/.claude/statusline-handler.sh
```

### 色の無効化

```bash
NO_COLOR=1 echo '...' | bash ~/.claude/statusline-handler.sh
```

## 仕組み

1. Claude Code が statusline コマンドとして本スクリプトを呼び出し、stdin に JSON を渡す
2. JSON からモデル名・コンテキスト使用率・CWD を取得
3. macOS Keychain から OAuth トークンを取得し、Anthropic Usage API を呼び出す（60秒キャッシュ）
4. `bar-renderer.ts`（bun で実行）がバー文字列を生成
5. 2行の ANSI エスケープ付きテキストを stdout に出力

## ファイル構成

```
claude-statusline/
├── README.md                # このファイル
├── statusline-handler.sh    # メインスクリプト
├── bar-renderer.ts          # 高解像度バーレンダラー（bun実行）
└── install.sh               # インストーラー
```

## 制限事項

- **macOS 専用**: `security` コマンド（Keychain）、BSD `date`、BSD `stat` に依存しています
- **bun 依存**: 高解像度バー表示に bun ランタイムが必要です（bun なしでもテキスト表示にフォールバック）
