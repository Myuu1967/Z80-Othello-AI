# RVS8 オセロ AI 開発ログ

対象ハード: Super AKI-80 (Z80)  
シリアル: SIOA DAT=18h CTL=19h  
PIOA: DATA=1CH CMD=1DH / PIOB: DATA=1EH CMD=1FH  
作業日: 2026-04-01 ～

---

## 運用ルール

- 新しいASMファイルが動作確認できたとき / バグ修正の原因・対策が確定したとき / 設計方針変更時にログ更新
- ログ更新・動作確認・作業終了のタイミングで git コミット
- コミットメッセージ形式: `[ファイル名] 変更内容の概要`

---

## ファイル系譜

```
RVS8_GREEDY.ASM
  └─ RVS8_POSWEIGHT.ASM
       └─ RVS8_MINIMAX1.ASM
            └─ RVS8_MINIMAX1_16.ASM
                 └─ RVS8_MM1_MOB.ASM
                      └─ RVS8_PIOSW.ASM  ← 現行最新
```

---

## 各ファイルの概要

| ファイル | AI戦略 | 評価式 | 状態 |
|---|---|---|---|
| RVS8_GREEDY.ASM | Greedy | flip_count | ✓ |
| RVS8_POSWEIGHT.ASM | 位置評価 | POS_WEIGHT + flip_count | ✓ |
| RVS8_MINIMAX1.ASM | Minimax depth-1 | (weight>>1) + ((255-opp)>>1) | ✓ バグ修正済 |
| RVS8_MINIMAX1_16.ASM | Minimax depth-1 16bit | weight + (255-opp) | ✓ |
| RVS8_MM1_MOB.ASM | Minimax depth-1 16bit+Mob | weight + (255-opp) + (ai_mob-opp_mob+64) | ✓ |
| RVS8_PIOSW.ASM | 同上 + PIObスイッチ入力 | 同上 | ✓ 現行最新 |

---

## POS_WEIGHT テーブル

```
;       A    B    C    D    E    F    G    H
DEFB  120,  15,  40,  35,  35,  40,  15, 120  ; 1
DEFB   15,   5,  20,  20,  20,  20,   5,  15  ; 2
DEFB   40,  20,  25,  25,  25,  25,  20,  40  ; 3
DEFB   35,  20,  25,  22,  22,  25,  20,  35  ; 4-5
DEFB   40,  20,  25,  25,  25,  25,  20,  40  ; 6
DEFB   15,   5,  20,  20,  20,  20,   5,  15  ; 7
DEFB  120,  15,  40,  35,  35,  40,  15, 120  ; 8
```

角=120, Xマス=5（最低値だが絶対禁止ではない）

---

## mm_score 評価式 (MOB版)

```
mm_score = POS_WEIGHT[ai_pos]        (5〜120)
         + (255 - opp_best)          (相手抑制: 0〜255)
         + (ai_mob - opp_mob + 64)   (モビリティ差: 0〜128)
```

スコア範囲: 5〜503 (16bit)。`+64` は ai_mob-opp_mob の負値によるアンダーフロー防止。

---

## AIset の構造 (RVS8_MM1_MOB.ASM)

`DoTurn` の `DT_DoAI` (line 1551) から `CALL AIset` で呼ばれる。

```
AIset:
  ├── 初期化 (AI_BEST_SCORE=0, AI_BEST_ROW=FFH)
  ├── 64マス走査ループ  ← 処理の大半
  │     CountAllFlips → SaveBoard → ApplyMove
  │     → OppBestScore (OBS_COUNT に相手合法手数)
  │     → CountMobility (AI_MOB_COUNT に AI合法手数)
  │     → RestoreBoard → mm_score計算 → ベスト更新
  ├── ベスト手を ApplyMove で着手
  └── "AI moves to XX" 表示
```

---

## 主なバグ修正記録

### PUSH BC の位置 (MINIMAX1)

`ApplyMove` が B,C を破壊するため順序が重要:

```asm
PUSH BC          ; ← ApplyMove より前
CALL SaveBoard
CALL ApplyMove   ; B,C 破壊
CALL OppBestScore
CALL RestoreBoard
POP BC           ; ← RestoreBoard より後
```

誤った順序だと同一手を無限ループで処理し続ける。

### OppBestScore → CountMobility 間の PUSH AF

`CountMobility` が A を破壊するため `PUSH AF / POP AF` が必須。

---

## ゲームループ

```
START → PrintBoard → DecideFirstTurn
MAIN_LOOP:
  DoTurn → PrintBoard → PrintCounts → IsBoardFull → MAIN_LOOP
  └── GameOver → ShowWinner → r:Retry / q:Quit
```

`DecideFirstTurn`: Z80 の R レジスタ LSB で先攻/後攻をランダム決定。

---

## 計測インフラ開発経緯

### CTC 方式 (失敗・破棄)

| 試行 | 結果 | 原因 |
|---|---|---|
| CTC 割り込み版 (IM1/38H) | 失敗 | 38H が ROM 領域 |
| CTC ポーリング版 (CH0, 29H) | 失敗 | 全カウント 0 |

→ **Super AKI-80 では CTC 利用不可と確定**

### ソフトウェアカウンタ (SOFT_MEASURE_TIME.ASM)

`COUNTER` ルーティンでループ回数を計上（実機で SWTIME=25600 を確認）。  
分岐依存でTstate数が可変なため実時間への換算精度が不十分。単体では計測手段として成立しない。

---

## Raspberry Pi Pico 外部計測システム (2026-04-08)

### システム構成

```
Z80 (RVS8_MM1_MOB.ASM)
  ├── SIOA (18H) ──┬──→ PC ターミナル（既存）
  │                └──→ Pico UART（信号線分岐）→ LCD 盤面描画
  └── PIOA D7 ─────────→ Pico GPIO15 → AI 処理時間計測
```

スイッチ入力は Z80 PIO 経由に移管予定（現在は Pico 側）。

### MT_PICO.ASM (Z80側トリガ出力)

- `StartTimer`: PIOA を出力モード設定 → D7 HIGH（計測開始）
- `StopTimer`:  PIOA D7 LOW（計測終了）
- `DummyWork`:  DE=0 からデクリメント 65536回ループ（検証用）
  - 1ループ ≈ 42T = 4.2μs → 期待値 ≈ 275ms

### measureTimeWithZ80.py (Pico側)

GPIO15 の HIGH/LOW エッジを `ticks_us()` で計測。LED で計測中を視覚確認。

```python
def measure_once():
    while signal.value() == 0: pass
    t_start = time.ticks_us()
    while signal.value() == 1: pass
    t_end = time.ticks_us()
    elapsed = time.ticks_diff(t_end, t_start)
    str_time = f"処理時間: {elapsed} μs  ({elapsed/1000:.3f} ms)"
    print(str_time)
    return elapsed

def measure_average(count=10):  # 複数回計測して平均・最小・最大・ばらつきを表示
```

### DummyWork 計測結果

| 実測値 | 理論値 | 差分の原因 |
|---|---|---|
| ≈290ms | ≈275ms | StartTimer 後に PrintString("Measuring...") が計測に含まれる（≈15ms）|

PrintString を StartTimer 前に移動すれば理論値に近づく（未修正）。

---

## LCD GUI プロトタイプ (testOthelloGUI.py, 2026-04-08)

ST7789 (240×320) SPI + 5方向スイッチ (GPIO 9-13)。

| 機能 | 状態 |
|---|---|
| 8×8グリッド + A-H/1-8ラベル描画 | ✓ |
| 初期配置4石 | ✓ |
| ステータス行表示 | ✓ |
| 5方向スイッチでカーソル移動 | ✓ |
| Enter で石を置く | ✓ (toggle のみ) |

**注:** `madctl(0x88)` の影響で黒白が補色表示（緑は正常）。オセロロジック未実装。

---

## RVS8_MM1_MOB.ASM への PIO D7 計測組み込み (2026-04-08)

`DT_DoAI`（line 1550）の前後に挿入：

```asm
DT_DoAI:
    PUSH AF
    LD   A,00001111B
    OUT  (PIOA_CMD),A       ; PIOA 出力モード
    LD   A,80H
    OUT  (PIOA_DATA),A      ; D7 HIGH ← 計測開始
    POP  AF

    CALL AIset

    PUSH AF
    LD   A,0
    OUT  (PIOA_DATA),A      ; D7 LOW ← 計測終了
    POP  AF

    JR   DT_SwitchReturn0
```

`AIset` 内部ではなく呼び出し元に挿入することでコードへの影響を最小化。  
PrintString（"AI moves to XX"）も計測に含まれるが誤差は微小。

---

## uart&Display.py 修正・動作確認 (2026-04-08)

旧バージョンの既知バグ2点を修正し、動作確認済み。

### 修正内容

1. `time.ticks_us()` → `utime.ticks_us()` / `utime.ticks_diff()` に統一（インポートが `utime` のため）
2. `elapsed = measure_once()` で戻り値を受け取り `// 1000` で ms 整数変換→ `f"Time:{elapsed:d}ms"` で LCD 表示

### メインループの動作

```
while True:
    receive_data() → UART受信があればLCDに表示
    sleep(0.1)
    measure_once() → GPIO15 HIGH/LOWエッジ計測 → LCD に "Time:XXXms" 表示
```

---

## AI処理時間 実測結果 (2026-04-08)

対象: `RVS8_MM1_MOB.ASM` の `AIset`（depth-1 minimax + モビリティ）

| 局面 | 処理時間 |
|---|---|
| 合法手が多い（序盤〜中盤） | ≈ 700 ms |
| 合法手が少ない（終盤など） | ≈ 200 ms |

計測方法: PIOA D7 → Pico GPIO15 → `uart&Display.py` で LCD 表示

**考察:** 64マス走査 × 相手合法手カウント（OppBestScore）が支配的。  
depth-2 にするには α-β 枝刈りが必須。

---

## uart_board.py / boardDisplay.py 開発 (2026-04-08)

### uart_board.py
UART受信行を解析して盤面配列を構築するパーサー単体テスト用ファイル。  
先頭が`1`〜`8`の行のみ `split()` で解析。動作確認済み。

### boardDisplay.py
`testOthelloGUI.py` をベースに UART盤面パーサーを統合した LCD表示ファイル。

**機能:**
- 盤面背景（緑）・グリッド線・A-H/1-8 ラベル描画
- UART受信ごとに該当行の石を即時更新（全消去なし・行単位で描画）
- X石（黒）/ O石（白）/ 空白（緑で消去）
- スコア行 (`X:06 O:12`) → 盤面下に表示
- AI手行 (`AI moves to XX`) → 強調色で表示

**色対応 (madctl(0x88) 補色補正):**
| 定数 | 画面上の色 | 用途 |
|---|---|---|
| `st7789.MAGENTA` | 緑 | 盤面背景 |
| `st7789.WHITE` | 黒 | X石・グリッド・文字 |
| `st7789.BLACK` | 白 | O石・画面背景 |
| `st7789.YELLOW` | シアン | AI手テキスト強調 |

---

## boardDisplay.py 動作確認 (2026-04-08)

`boardDisplay.py` を実機で確認、正常動作を確認済み。

表示内容（ステータスエリア）:
```
X:06 O:12          ← スコア
AI moves to C8     ← AI手（シアン強調）
Time:687ms         ← 処理時間（ノンブロッキング計測）
```

---

## PIOB スイッチ入力移管 (2026-04-09)

新ファイル: `RVS8_PIOSW.ASM`（`RVS8_MM1_MOB.ASM` をベースに作成）

### 変更内容

| 追加要素 | 内容 |
|---|---|
| `PIOB_DATA=1EH, PIOB_CMD=1FH` | PIOB ポート定義 |
| `SW_UP/DOWN/LEFT/RIGHT/ENTER` | スイッチビット定数 (01H〜10H) |
| `PLR_COL, PLR_ROW` | カーソル変数 |
| `InitPIOB` | PIOB を Mode3 全ビット入力で初期化 |
| `Debounce` | ≈20ms ソフトウェア遅延 |
| `WaitSwPress` | 押下→デバウンス→離し待ち→bitmask 返却 |
| `SW_PlayerMove` | スイッチ入力プレイヤー手ルーティン |

### スイッチ割り当て

| スイッチ | PIO ピン | 役割 |
|---|---|---|
| SW0 | PB0 | 上（行--） |
| SW1 | PB1 | 下（行++） |
| SW2 | PB2 | 左（列--） |
| SW3 | PB3 | 右（列++） |
| SW4 | PB4 | Enter（確定） |

アクティブLOW（押す=0）を `CPL` で反転して処理。  
bitmask は `E` レジスタに退避し、カーソル移動中の A 上書きを回避。

### 動作フロー

```
SW_PlayerMove:
  ガイドメッセージ表示
  カーソル A1 に初期化
  ループ:
    \rMove: XX 表示
    WaitSwPress → bitmask を E に退避
    SW4? → SWP_ENTER
    SW0-3? → カーソル移動（0-7 ラップ）
    → ループ
  SWP_ENTER:
    B=行, C=列 → IsLegalMove → ApplyMove
    違法 → メッセージ表示 → ループ
```

旧 `PlayerMove`（SIOA キーボード入力版）はデバッグ用としてファイル内に保持。

---

## RVS8_PIOSW.ASM 実機調整 (2026-04-09)

### 表示更新方式の変更

カーソル位置表示を `\r` + フル再描画 → **BS×2 + 位置2文字上書き** に変更。

- `SWP_REPRINT` ラベルを新設（初期表示・違法手後のフル再描画）
- スイッチ操作後は `SWP_UPD` で `BS BS col row` のみ出力
- 違法手後は `SWP_REPRINT` に飛んで新行に再表示

### スイッチ割り当て変更（実機配置に合わせ）

PB0↔PB2、PB1↔PB3 を入れ替え:

| ピン | 役割 |
|------|------|
| PB0  | 左（列--） |
| PB2  | 上（行--） |
| PB3  | 下（行++） |
| PB4  | Enter |
| PB1  | 右（列++） |

### トラブルシュート記録

- **PB1 不良と誤判断** → 原因はブレッドボード不良。新ブレッドボードで PB1 正常動作確認。
- **全SW無反応** → `WaitSwPress` の `WSP_RELEASE` ループ詰まりが原因。PB0/PB5 が未配線でフローティングLOWとなり「常時押下」と誤認。AND マスクを `1CH`（PB2/3/4のみ）に絞り診断 → 原因特定後 `1FH` に戻す。
- **Mode1 試行** → Z80 PIO Mode1 はストローブラッチ方式のため IN 命令でのポーリング不可。Mode3 に戻す。

### Debounce 短縮

≈20ms (B=79) → **≈15ms (B=59)** に短縮。動作確認済み。

### 最終スイッチ配置（動作確認済み）

| ピン | ビット | 役割 |
|------|--------|------|
| PB0  | bit0   | 左（列--） |
| PB1  | bit1   | 右（列++） |
| PB2  | bit2   | 上（行--） |
| PB3  | bit3   | 下（行++） |
| PB4  | bit4   | Enter |

AND マスク: `1FH`（bit0〜4）

---

## gameDisplay.py 作成 (2026-04-10)

`boardDisplay.py` を全面的に整理・改良した新ファイル。

### 主な変更点

| 項目 | boardDisplay.py | gameDisplay.py |
|------|----------------|----------------|
| スコア表示 | テキストのみ `X:04 O:04` | テキスト + 石アイコン（塗りつぶし円）を追加 |
| AI手表示 | あり | あり（シアン強調） |
| 人の手表示 | `Move: XX` をリアルタイム追跡 | `You: XX` 表示 |
| ステータスエリア | 3行 | 4行（ST_Y_SCORE/MOVE/TIME/HUMAN） |
| GAME OVER | 部分対応 | `GAME OVER` + 勝者行 + リトライ対応 |

### ステータスエリアレイアウト (Y座標)

```
ST_Y_SCORE = 236  : [●]04  [○]04   ← 石アイコン付きスコア
ST_Y_MOVE  = 254  : AI moves to C8  ← シアン
ST_Y_TIME  = 272  : Time:687ms
ST_Y_HUMAN = 290  : You: D4         ← 赤
```

### draw_status() の石アイコン

```python
tft.fill_circle(14, ST_Y_SCORE, STONE_R, COL_STONE_X)   # X石（黒）
tft.fill_circle(72, ST_Y_SCORE, STONE_R, COL_STONE_O)   # O石（白）
tft.circle(72, ST_Y_SCORE, STONE_R, COL_STONE_X)        # O石の輪郭
```

---

## gameDisplay.py 追加改良 (2026-04-10)

### Pico起動時カーソル追跡 (BS BSパターン対応)

`feed_byte()` に BS×2 検出を追加。  
Pico起動時に Z80 がすでに `WaitSwPress` でブロック中の場合、初回の `Move: XX` を受け取れないが、  
スイッチ操作後の `BS BS col row` パターンを検出してカーソルモードに入ることで1キー操作後から表示が追従する。

```python
if b == 0x08 and len(_sbuf) > 0 and _sbuf[-1] == 0x08:
    _in_cursor = True   # BS BS → カーソル更新モードへ
```

### プレイヤー色アイコン表示 (4行目)

Z80 の色通知行をパースして `player_stone` を確定し、4行目左端に自分の石色アイコンを表示。

```
Z80出力: "You go first. You are BLACK (X)."  → player_stone = 'X'
         "AI goes first. You are WHITE (O)." → player_stone = 'O'
```

- テキスト `You: D4` は x=26 から描画
- x=14 に自分の色の塗りつぶし円（白石は輪郭線も追加）

### リトライ/終了プロンプト表示 (5行目)

終局時の `r:Retry or q:Quit ?` 行を受信すると `retry_mode = True` になり 5行目を表示。  
新しい盤面の先頭行を受信すると自動クリア。

```
ST_Y_RETRY = 308  : [シアン●]:Retry   [赤●]:Quit
```

| 変数 | 値 | タイミング |
|------|----|-----------|
| `retry_mode = True` | `r:Retry` 行受信時 | GAME OVER → プロンプト表示 |
| `retry_mode = False` | 新盤面 row_idx==0 受信時 | 新ゲーム開始 |

### ステータスエリア最終レイアウト (5行)

```
ST_Y_SCORE = 236  : [●]04  [○]04
ST_Y_MOVE  = 254  : AI moves to C8   (シアン)
ST_Y_TIME  = 272  : Time:687ms
ST_Y_HUMAN = 290  : [自色●] You: D4  (赤)
ST_Y_RETRY = 308  : [シアン●]:Retry  [赤●]:Quit  (retry_mode時のみ)
```

`fill_rect` の高さを 88→92px に拡張（228+92=320、画面下端まで）。

---

## RVS8_PIOSW.ASM: GO_WAIT を SIOA/PIOB 並行ポーリングに変更 (2026-04-10)

終局の `r:Retry or q:Quit ?` プロンプトで PIOB スイッチ（PB0/PB2）も受け付けるよう修正。

### 変更箇所: GO_WAIT (GameOver ルーティン内)

旧: `CALL GetChar`（SIOA のみ、ブロッキング）  
新: SIOA と PIOB を交互にポーリング（ノンブロッキング）

```asm
GO_WAIT:
  SIOA RDRF ビット確認 → データあり → GO_SIOA（既存の文字受信処理）
  PIOB AND 05H 確認    → PB0/PB2 押下検出
    デバウンス → 離し待ち → A='r' or 'q' → PutChar → GO_CHK
GO_SIOA:
  IN A,(SIOA_DAT) → PutChar → 大文字→小文字変換 → GO_CHK
```

### スイッチ割り当て (GO_WAIT 専用)

| ピン | ビット | 動作 |
|------|--------|------|
| PB0  | bit0   | 'r' → リトライ |
| PB2  | bit2   | 'q' → 終了 |

`PutChar` でエコーするため Pico 側でも文字を受信でき、表示更新に利用可能。

---

## 次回やること

1. ~~`RVS8_MM1_MOB.ASM` でAI 1ターンの処理時間を実測~~ ✓ 完了
2. ~~`boardDisplay.py` を実機で動作確認~~ ✓ 完了
3. ~~スイッチ入力を Z80 PIO 経由に移管~~ ✓ 完了 (`RVS8_PIOSW.ASM`)
4. ~~`RVS8_PIOSW.ASM` を実機でアセンブル・動作確認~~ ✓ 完了
5. ~~`boardDisplay.py` の描画部分の調整・改善~~ ✓ 完了 (`gameDisplay.py`)
6. ~~`RVS8_PIOSW.ASM` GO_WAIT 変更を実機でアセンブル・動作確認~~ ✓ 完了
7. `gameDisplay.py` 勝者行を石アイコン付きで表示
   - `"BLACK(X) wins"` → [黒●] `BLACK wins`（4行目、x=26 テキスト + x=14 黒石アイコン）
   - `"WHITE(O) wins"` → [白○] `WHITE wins`（4行目、x=26 テキスト + x=14 白石アイコン）
   - `"Draw"` はアイコンなしでそのまま表示
8. ~~`gameDisplay.py` 5行目リトライ表示のタイミング修正~~ ✓ 完了
   - **原因**: `MSG_RETRYQ` 末尾に `\n` がなく行パーサーが解析できない
   - **対策**: 勝者行（`wins` / `DRAW`）受信時に `retry_mode = True` をセット（プロンプト到着を待たない）
   - `r:Retry` ハンドラは死んだコードのため削除

---

## RVS8_PIOSW.ASM GO_WAIT 実機確認 (2026-04-10)

- GAME OVER 後に `r:Retry or q:Quit ?` 表示 ✓
- SIOA キーボードから `r` / `q` 入力でリトライ・終了 ✓
- PIOB スイッチから操作 ✓
  - PB0 → `r`（リトライ）
  - PB2 → `q`（終了）
  - PB1・PB3 → 無反応（意図通り）
- Pico `gameDisplay.py` でリトライ表示（5行目）が勝者行と同時に表示 ✓

### 未確認項目

- DRAW（引き分け）時の表示
- PASS 連続2回による終局

→ 4×4 バージョンで意図的に再現しやすいため、そちらで改良版を作成予定

---

## ドキュメント整備 (2026-04-11)

- `CLAUDE.md` 更新: 現行ファイルを `RVS8_PIOSW.ASM` に修正、PIOB仕様追記
- PIOポートアドレス誤記を訂正
  - 旧: PIOA CMD=0CH DATA=0DH（誤）
  - 正: PIOA DATA=1CH CMD=1DH / PIOB DATA=1EH CMD=1FH
  - ASMコード自体は最初から正しく記述されており動作への影響なし
- `DEVLOG_RVS8.md` ファイル系譜に `RVS8_PIOSW.ASM` を追記

---

## gameDisplay.py ログ再生機能追加 (2026-04-11)

Z80実機なしで表示テストができるログ再生機能を追加。

### 変更内容

- 行処理ブロックを `process_line(line)` 関数に切り出し（UART・ログ再生で共用）
- `replay_log(filename, line_delay_ms=400)` 追加
  - Pico フラッシュ上の `/replay.txt` を行単位で再生
  - ファイルなければ何もしない（通常運用への影響ゼロ）
  - MicroPython の LittleFS ファイルシステムで動作確認予定

---

## RVS8_MM2_AB.ASM 作成 (2026-04-11)

`RVS8_PIOSW.ASM` をベースに depth-2 minimax + α-β 枝刈りの準備ファイルを作成。

### ファイル系譜更新

```
RVS8_MM1_MOB.ASM
  └─ RVS8_PIOSW.ASM  (現行・PIObスイッチ入力)
       └─ RVS8_MM2_AB.ASM  (depth-2準備・以降はこちらで開発)
```

### SaveBoard/RestoreBoard 2スロット化（案B: HLパラメータ渡し）

| 変更点 | 内容 |
|---|---|
| `BOARD_SAVE` → `BOARD_SAVE1`+`BOARD_SAVE2` | 各64バイト、計128バイト |
| `SaveBoard`: HL=保存先 | `EX DE,HL` → `LD HL,BOARD` → `LDIR` |
| `RestoreBoard`: HL=復元元 | `LD DE,BOARD` → `LDIR` |
| `AIset` 呼び出し箇所 | `LD HL,BOARD_SAVE1` を前置 |

depth-3以上はバッファ追加のみで対応可能。

### OppBestScore コメント整備

- フロー各ブロックにラベル説明追記
- depth-2改造方針: `CountAllFlips` → `SaveBoard(SAVE2)/ApplyMove/評価/RestoreBoard` に拡張する箇所を明示
- α-β挿入ポイント: `OBS_BEST` 更新直後に `<<< β-CUTOFF HERE` とマーク
  - 条件: `(255 - OBS_BEST) <= alpha` なら `OBS_END` へジャンプ
- `OBS_END` ラベル追加（早期脱出先）

---

## 次回やること

1. ~~`RVS8_MM2_AB.ASM` を実機でアセンブル・動作確認（RVS8_PIOSWと同等動作のはず）~~ ✓ 完了
2. ~~`gameDisplay.py` 勝者行を石アイコン付きで表示~~ ✓ 完了
   - `"BLACK(X) wins"` → [黒●] `BLACK wins`（4行目）
   - `"WHITE(O) wins"` → [白○] `WHITE wins`（4行目）
   - `"Draw"` はアイコンなしそのまま
3. ~~`gameDisplay.py` ログ再生機能の動作確認（`/replay.txt` を用意）~~ ✓ 完了
4. ~~`OppBestScore_d2` 実装（BOARD_SAVE2使用・実際に着手して評価）~~ ✓ 完了
5. α-β 枝刈り実装

---

## RVS8_MM2_AB.ASM 実機動作確認 (2026-04-12)

実機アセンブル・動作確認済み。RVS8_PIOSW.ASM と同等動作を確認。

---

## gameDisplay.py 勝者行アイコン表示 (2026-04-12)

`winner_stone` 変数を追加し、勝者確定時に石アイコンを4行目に表示。

### 変更内容

- `winner_stone = None` を変数追加
- `process_line`: `'wins' in line` で `BLACK`/`WHITE` を判定し `human_text` を短縮・`winner_stone` をセット
  - `"BLACK(X) wins"` → `human_text="BLACK wins"`, `winner_stone='X'`
  - `"WHITE(O) wins"` → `human_text="WHITE wins"`, `winner_stone='O'`
  - `"DRAW"` → `winner_stone=None`（アイコンなし）
- `draw_status`: `retry_mode` 中はアイコン種別を `winner_stone` で決定（それ以外は `player_stone`）
- リトライ・新ゲーム開始時に `winner_stone = None` リセット

---

## 先後手選択機能追加 (2026-04-12)

### Z80側 (RVS8_MM2_AB.ASM)

`DecideFirstTurn` をランダム決定からスイッチ選択に変更。

- メッセージ: `"Choose: SW0=1st(X) SW2=2nd(O)"`
- SW0(bit0) → 先手(黒/X) / SW2(bit2) → 後手(白/O)
- SIOA キーボード: `'1'`=先手 / `'2'`=後手（デバッグ用）
- PIOB マスク: `05H`（bit0・bit2のみ検出）
- 選択後に `NEWLINE` を出力してから色通知メッセージを表示

### Pico側 (gameDisplay.py)

`Choose:` 行受信時に選択UI を ST_Y_SCORE 行に表示。

- `choose_mode` 変数追加（True=選択中）
- [シアン●]:1st(X)　[赤●]:2nd(O) をアイコン付きで表示
- `You are BLACK/WHITE` 受信で `choose_mode = False`（通常スコア表示に戻る）
- リトライ・新ゲーム開始時にもリセット

---

## OppBestScore_d2 実装・実機確認 (2026-04-12)

depth-2 minimax を実装。`OppBestScore` の代替として `AIset` から呼び出す。

### 実装内容

- 変数追加: `OBS2_MIN_AI`（AI最善スコアの最小値）
- `OppBestScore_d2`: 相手の各合法手に対して BOARD_SAVE2 へ保存 → ApplyMove → AI応手探索 → 復元
  - inner loop: AI の全合法手で `max(POS_WEIGHT+flips)` を求める
  - 相手は AI最善スコアを最小化する手を選ぶ (minimax)
  - 返り値: `opp_best = 255 - min_j(ai_best_j)`
- `AIset`: `CALL OppBestScore` → `CALL OppBestScore_d2` に切り替え

### 実測処理時間 (depth-2, α-β なし)

| 局面 | 処理時間 |
|------|----------|
| 最大（複雑局面） | ≈ 6 秒 |

理論上 depth-1 の最大64倍 (≈45秒) だが、実際の盤面では合法手が少なく
外/内ループの有効反復が絞られるため大幅に速い。
→ α-β 枝刈りでさらなる高速化が期待できる。

---

## AKI-80 モニタ ROM 解析 (2026-04-14)

28C256 EEPROM 入手を機に、オセロ完成後に ROM ブート化することを計画。
モニタ ROM (`AKI-80MONI_ROM.HEX`) を Intel HEX デコードして大枠を解析した。

### ROM マップ概要

| アドレス | 内容 |
|---|---|
| 0000H | リセットベクタ: `JP 0080H` |
| 0030H | RST30H: `JP 02F4H`（デバッガ BP） |
| 0066H | NMI ベクタ: `JP 013AH` |
| 0080H | コールドスタート（PIOA/PIOB 初期化 → SP=FCE0H → JP 0D00H） |
| 0100H | ウォームスタート（SIOA 初期化含む） |
| **0196H** | **InitSIOA ルーティン**（OTIR + CTC baud rate 設定） |
| **01A8H** | **SIOA 初期化 9バイトテーブル** |
| 01B0H-0CFFh | モニタ本体（コマンドパーサ・メモリ操作） |
| 0D00H-18FFh | メインループ・拡張コマンド・I/O処理 |
| 1CC0H-1DDEh | 文字列定数・エラーメッセージ |
| 1D60H- | 起動メッセージ "Start Z80 remote basic Ver.1.0 made by System Load...since 1992." |
| 1DE0H-7FFFh | FF（未使用） |

### SIOA 初期化コード（0196H）

ROM ブート化に必要な最重要情報。モニタの 0196H をそのまま再現すれば動く。

```asm
InitSIOA:
    LD   HL, SIOA_INIT_TBL
    LD   B,  9
    LD   C,  19H            ; SIOA_CTL
    OTIR                    ; 9バイトを一気に送信
    LD   A,  17H
    OUT  (13H), A           ; ボーレートクロック設定（port 13H）
    LD   A,  04H
    OUT  (13H), A           ; 時定数 → 9600bps
    RET

SIOA_INIT_TBL:
    DEFB 18H    ; WR0: チャンネルリセット
    DEFB 04H    ; WR0: WR4 選択
    DEFB 44H    ; WR4: x16クロック, 1ストップ, パリティなし
    DEFB 03H    ; WR0: WR3 選択
    DEFB 0C1H   ; WR3: 受信有効, 8bit
    DEFB 05H    ; WR0: WR5 選択
    DEFB 6AH    ; WR5: 送信有効, 8bit, RTS
    DEFB 01H    ; WR0: WR1 選択
    DEFB 00H    ; WR1: 割り込みなし
```

### ROM ブート化の方針

1. `ORG 0000H`（コード・読み取り専用データ）
2. `ORG 8000H`（変数・DEFS のみ）
3. 先頭に `InitSIOA` を追加（上記コード）
4. SP・PIOA・PIOB 初期化は既存コードで済んでいる
5. HEX の 0000H-7FFFH 範囲を 28C256 に書き込む

### 備考

- モニタの SP = 0FCE0H、オセロ現行は 0FFF0H → どちらも問題なし
- port 13H はモニタでも baud rate 設定に使用している
- 実際のコードは 0x0000〜0x1DE0 程度、32KB EEPROM に余裕で収まる

---

## gameDisplay.py Choose画面 GAME OVER残留バグ修正 (2026-04-14)

### 症状
リトライ後の先後手選択画面（Choose:）の2行目に "GAME OVER" が残り続ける。

### 原因（2点）
1. Z80 が 'r' を改行なしでエコー後すぐ "Choose:..." を送信するため、Pico のバッファが `rChoose: SW0=...` になり `startswith('Choose:')` にマッチしなかった
2. Choose: ハンドラ内で `move_text` をクリアしていなかった

### 修正
```python
# 修正前
elif line.startswith('Choose:'):
    choose_mode = True

# 修正後
elif 'Choose:' in line:
    choose_mode = True
    move_text   = ""
    human_text  = ""
```

実機確認済み：Choose画面の "GAME OVER" 消去・先後手選択正常動作 ✓

---

## α-β 枝刈り実装 (2026-04-14)

### 実装箇所

`OppBestScore_d2` の内側ループ (`ID2_ROW/ID2_COL`) に α-cutoff を追加。

### 枝刈り条件

```
OBS_BEST (現在の AI 最善スコア) >= OBS2_MIN_AI (α値 = これまでの相手最善)
```

相手は AI スコアを最小化したいので、AI が α 値以上のスコアを出せる相手手は採用されない。
→ その時点で内側ループを `ID2_END` へジャンプして打ち切る。

### 追加コード (RVS8_MM2_AB.ASM)

```asm
        LD   (HL),A             ; inner best 更新 (OBS_BEST)
        ; α-cutoff: OBS_BEST >= OBS2_MIN_AI → 相手はこの手を選ばない → inner終了
        LD   HL,OBS2_MIN_AI
        CP   (HL)               ; OBS_BEST vs OBS2_MIN_AI (α)
        JR   NC,ID2_END         ; OBS_BEST >= α → 枝刈り

ID2_NEXT:
        ...
ID2_END:
        ; inner loop 完了 (正常終了 or α-cutoff)
```

### ロジック検証

- `OBS2_MIN_AI` 初期値 = FFH → 1回目の外側手は必ず完全探索
- 枝刈り後、`ID2_END` 以降の `OBS2_MIN_AI` 更新ロジックで `JR NC, OD2_RESTORE` が発火し、OBS2_MIN_AI は正しく更新されない（= 枝刈りは安全）
- `OBS2_MIN_AI = 0` の場合、以降のすべての外側手の内側ループは最初の合法手で即打ち切り

### 実機確認結果 (2026-04-14)

| 版 | 最大処理時間 |
|----|------------|
| depth-1 (RVS8_PIOSW) | ≈ 700 ms |
| depth-2 α-β なし (RVS8_MM2_AB) | ≈ 6 秒 |
| depth-2 α-β あり (RVS8_MM2_AB) | **≈ 2 秒以下** |

約3倍の高速化を確認。強さも体感で向上（同じ評価式・同じ探索深さ、手順の差による）。

---

## POS_WEIGHTテーブル改善 (2026-04-14)

オセロ理論に基づき64バイトテーブルを改訂。計算量ゼロの強化。

### 変更内容

| マス分類 | 旧値 | 新値 | 理由 |
|---|---|---|---|
| 角 (A1/H1/A8/H8) | 120 | 120 | 変更なし |
| Xマス (B2/G2/B7/G7) | 5 | **1** | 角を相手に渡す最悪手、ほぼ禁止 |
| Cマス (B1/A2/G1/H2 etc.) | 15 | **5** | 角隣、相手に角を渡しやすい |
| 辺中央 (C1-F1 etc.) | 40 | **30** | 良い手だが過大評価を修正 |
| B列/2行内側 | 20 | **15** | Cマス近傍で危険 |
| 中央 | 22-25 | **18-20** | 微調整 |

### 新テーブル

```
;       A    B    C    D    E    F    G    H
DEFB  120,   5,  30,  25,  25,  30,   5, 120  ; 1
DEFB    5,   1,  15,  15,  15,  15,   1,   5  ; 2
DEFB   30,  15,  20,  20,  20,  20,  15,  30  ; 3
DEFB   25,  15,  20,  18,  18,  20,  15,  25  ; 4-5
DEFB   30,  15,  20,  20,  20,  20,  15,  30  ; 6
DEFB    5,   1,  15,  15,  15,  15,   1,   5  ; 7
DEFB  120,   5,  30,  25,  25,  30,   5, 120  ; 8
```

max score = 120 + 64 = 184 < 256（byte-safe 維持）

---

## gameDisplay.py AI PASS / YOU PASS 表示追加 (2026-04-14)

Z80が送る "AI PASS\r\n" / "YOU PASS\r\n" のハンドラを追加。
- "AI PASS" → ST_Y_MOVE に "AI PASS" 表示
- "YOU PASS" → ST_Y_HUMAN に "YOU PASS" 表示

---

## 候補機能 (未着手)

| 機能 | 概要 | 備考 |
|---|---|---|
| 評価関数の重み付け | w1×位置 + w2×相手抑制 + w3×モビリティ | ソフト乗算ルーチンが必要 |
| POS_WEIGHTテーブル蒸留 | PC側DLで学習した価値をZ80用64バイトテーブルに圧縮 | 現行テーブルは人手設計 |
| 序盤定石 | 序盤N手を定石テーブルから選択、minimax省略 | 処理時間ゼロ化・強さ向上 |
| 終盤重み変更 | 残り石数に応じて評価式の重みを切り替え | 序盤=モビリティ重視、終盤=位置重視など |
| 安定石評価 | 角から連続する石を加点 | 算出コスト高 |
| 盤面重み合計差 | Σweight(AI石) - Σweight(相手石) | 既存の16bit演算で対応可 |

---

## MM2_AB_EG.ASM 設計・実装計画 (2026-04-15)

RVS8_MM2_AB.ASM を全読みし、終盤完全読み実装の設計を完了した。
新ファイル名を `MM2_AB_EG.ASM` に決定（RVS8_ プレフィックス廃止）。

### ファイル名の意味
`MM2` = MiniMax depth-2 / `AB` = Alpha-Beta / `EG` = EndGame 完全読み

### ファイル系譜更新
```
RVS8_MM2_AB.ASM  ← 現行最新（実機確認済み）
  └─ MM2_AB_EG.ASM  ← 次の作業（設計完了・実装前）
```

### 実装方針

空きマス数が `ENDGAME_THRESHOLD`（初期値=8）以下になったとき、
ヒューリスティック評価（depth-2 α-β）から終盤完全読みに切り替える。

終盤完全読み: negamax で全読み → AI石数 - 相手石数で評価（符号付き -64〜+64）

### 追加要素

| 追加要素 | 内容 |
|---|---|
| `CountEmpty` | 空きマス数 → A を返す |
| `ENDGAME_THRESHOLD EQU 8` | 切り替え閾値（実測後に 10 への拡張を検討） |
| `BOARD_EG_SAVES` | 完全読み用盤面スロット（8枚×64B = 512B） |
| `EG_GetSaveAddr` | EG_DEPTH → バッファアドレス計算 |
| `SearchFull` | negamax 完全読み再帰（α-β は処理時間計測後に追加） |
| `AIset_EG` | 終盤外ループ（SearchFull でスコア計算） |
| `SF_SIDE_TMP` | SearchFull 内 side 一時保存変数 |
| `DT_DoAI` 変更 | CountEmpty → 閾値判定 → AIset / AIset_EG 分岐 |

### 実装 7 ステップ

1. ファイル作成・土台準備（定数・変数・BOARD_EG_SAVES 追加）
2. `CountEmpty` + `EG_GetSaveAddr`（ユーティリティ関数・実機表示確認）
3. `SearchFull`（negamax、α-β なし版）
4. `AIset_EG`（外ループ）
5. `DT_DoAI` 切り替え + 初回実機確認・処理時間計測  ← 最初のゴール
6. `SearchFull` に α-β 追加（処理時間次第）
7. 閾値調整・DEVLOG 更新・git コミット

### 実装プロンプト保存先

`F:\ClaudeCode\Z80-Othello\MM2_AB_EG_実装プロンプト.txt`

---

## MM2_AB_EG.ASM 実装・バグ修正 (2026-04-16)

### 実装完了

`MM2_AB_EG.ASM` を完成させ、アセンブル通過を確認。

追加・変更内容:
- `CountEmpty` / `EG_GetSaveAddr` / `SearchFull` (negamax) / `AIset_EG` / `BOARD_EG_SAVES` / `SF_ALPHA_TBL`
- `DT_DoAI` に `CountEmpty → CP 9 → AIset_EG / AIset 分岐` を追加
- `SearchFull` に α-β 枝刈りを追加（`SF_ALPHA_TBL[10]` を depth別 alpha テーブルとして使用）

### バグ修正一覧

#### 1. SearchFull 終端評価の正負逆転

`AiSide` で石差を計算していたため、偶数深さでスコアの正負が逆転。  
negamax の原則に従い `SF_SIDE_TMP`（現在の手番プレイヤー）を使うよう修正。

#### 2. BOARD_SAVE1 衝突

`AIset_EG` が `BOARD_SAVE1` を使用しているにも関わらず、`EG_DEPTH=0` のまま `SearchFull` を呼んでいたため、`SearchFull(depth=0)` も `BOARD_SAVE1` を上書きしていた。  
→ `AIset_EG` 内の `EG_DEPTH` 初期値を `0` → `1` に変更（`SearchFull` は depth=1 から BOARD_SAVE2 を使用）

#### 3. NEG(80H) オーバーフロー → α-β 不正動作

`SF_ALPHA_TBL[0]` の初期値に `80H`（-128）を使うと `NEG(80H) = 80H`（Z80 NEG 命令の例外: -128 のみオーバーフロー）となり、beta が +INF のつもりが -INF になってしまう。  
**現象**: AI が負けている局面（相手スコアが正）で枝刈りが全く効かず 5 分超のハング。  

修正:
- 全ての `-INF` 初期値を `80H` → `81H` (-127) に変更 → `NEG(81H) = 7FH = +127` ✓
- `AIset_EG` 外ループで `SF_ALPHA_TBL[0] = EG_BESTSCORE`（固定 80H でなく現在の AI ベストスコア）に設定  
  → depth=1 の beta = -EG_BESTSCORE として正しい α-β が機能する

#### 4. Z80 アセンブラ非対応命令の修正

クラシック Z80 アセンブラは以下の命令をサポートしない:

| 問題の命令 | 修正後 |
|---|---|
| `LD IXL,A` / `SUB IXL` | D レジスタ経由 `LD D,A; SUB D` |
| `LD B,(SF_SIDE_TMP)` | `LD A,(SF_SIDE_TMP); LD B,A` |
| `LD (EG_BESTROW),B` | `LD A,B; LD (EG_BESTROW),A` |
| `LD (EG_BESTCOL),C` | `LD A,C; LD (EG_BESTCOL),A` |
| `SUB (SF_SIDE_TMP)` | `LD B,A; LD A,3; SUB B` |

**Z80 の制約**: `LD r,(nn)` / `LD (nn),r` は A レジスタのみ。`IXL`/`IXH` は多くのアセンブラで非対応。

### α-β 設計

```
SF_ALPHA_TBL[D] = depth D の現在ベストスコア (alpha)
beta[D]         = -SF_ALPHA_TBL[D-1]  (親の alpha を反転)

cutoff 条件: alpha[D] - beta[D] >= 0
  つまり: alpha[D] + SF_ALPHA_TBL[D-1] >= 0

AIset_EG 外ループとの接続:
  AI が良い手を見つけるたびに SF_ALPHA_TBL[0] = EG_BESTSCORE を更新
  → 次の候補手の SearchFull(depth=1) で beta が絞られ枝刈りが増加
```

### 処理時間（実機計測待ち）

空き 8 マスでハングが発生していたため、現在の α-β 修正後に再計測予定。

---

## MM2_AB_EG.ASM バグ修正・閾値調整 (2026-04-17)

### 閾値調整

`ENDGAME_THRESHOLD` を段階的に削減。

| 値 | 結果 |
|----|------|
| 8 | ハング（数分以上） |
| 4 | 約5分かかる（α-β バグにより実質全探索） |
| **2** | **現行値。2! = 2ノード、即時** |

### バグ① AIset_EG の EG_BESTSCORE 上書き問題

**症状:** 閾値4で約5分かかる（α-β が実質無効）。

**原因:** `AIset_EG` 外ループが `SearchFull` 呼び出し前後で `EG_BESTSCORE` を退避・復元していなかった。
`SearchFull` は内部の `SF_HasMove` 先頭で `EG_BESTSCORE = 81H` にリセットし、その後更新する。
戻ってきたとき `EG_BESTSCORE` は「相手 depth=1 での最善値」になっており、AIset_EG 自身の累積ベストではなくなっていた。

```
AIset_EG: EG_BESTSCORE = +5 (1手目のAI最善)
  → SearchFull 呼び出し
    内部: EG_BESTSCORE = 81H → 処理 → 相手最善 -3 に更新
  → 戻る
AIset_EG: EG_BESTSCORE を読む → -3 (間違い!)
  SF_ALPHA_TBL[0] = -3 → α-β の閾値が狂う → 枝刈り無効化
```

**影響:** `SF_ALPHA_TBL[0]`（α-β の alpha 値）も誤った値で設定され、枝刈りがほぼ効かなくなる。

**修正:** `SearchFull` 呼び出しの直前に `PUSH AF`、RestoreBoard 後 `POP AF / LD (EG_BESTSCORE),A` を追加。

```asm
        LD   A,(EG_BESTSCORE)
        LD   (SF_ALPHA_TBL),A
        PUSH AF                 ; ← 追加: EG_BESTSCORE を退避
        ...
        CALL SearchFull
        NEG
        LD   E,A

        CALL RestoreBoard
        POP  AF                 ; ← 追加: EG_BESTSCORE を復元
        LD   (EG_BESTSCORE),A
        POP  BC
```

**補足:** `SearchFull` 内部の再帰呼び出し（`SF_HasMove` ループ）では既に同パターンの PUSH/POP が実装されており正常。抜けていたのは `AIset_EG` の外ループのみ。

### バグ② SF_HasMove の EG_BESTSCORE 初期値 80H

**原因:** `SF_HasMove` が `EG_BESTSCORE = 80H` で初期化していた。
子スコアが正値（+1〜+64）の場合、符号付き比較 `E - 80H` がオーバーフローして負に見え、更新がスキップされる。
結果として EG_BESTSCORE が 80H のまま SearchFull が返り、呼び出し元で `NEG(80H) = 80H`（Z80の-128オーバーフロー）が発生。

**修正:** `80H → 81H`（AIset_EG・SF_ALPHA_TBL と同一方針に統一）

```asm
; 修正前
LD   A,80H
LD   (EG_BESTSCORE),A   ; ベスト = -128

; 修正後
LD   A,81H
LD   (EG_BESTSCORE),A   ; ベスト = -127 (80H は NEG でオーバーフロー → 使わない)
```

### バッファ設計の確認

`EG_GetSaveAddr` による depth 別バッファ割り当ての動作を確認。
深い再帰が浅いバッファを上書きすることはない（各 depth が専用スロットを使用）。

| depth | バッファ |
|-------|---------|
| 0 | BOARD_SAVE1 (AIset_EG が直接使用) |
| 1 | BOARD_SAVE2 |
| 2 | BOARD_EG_SAVES[0] |
| 3 | BOARD_EG_SAVES[1] |
| 4 | BOARD_EG_SAVES[2] |

閾値=2 なら depth 0〜3 で収まり、8スロット確保済みの範囲内で十分余裕がある。

### バグ③ AIset_EG / SearchFull 符号付き比較オーバーフロー

**症状:** 終盤でAIが手を指さず YOU PASS が無限ループ。

**原因:** `EG_BESTSCORE` の初期値 `81H`（-127 sentinel）と実スコアの比較がオーバーフロー。

- `SearchFull` が即終局（terminal）を経由して返った場合、`SF_HasMove` を通らないため `EG_BESTSCORE` は `81H` のまま
- 呼び出し元で `E - 81H` を符号付き減算すると、E が正値（例: +45 = 2DH）のとき `2DH - 81H = ACH = -84` となり JP M が発火 → 「新手 < ベスト」と誤判定してスキップ
- 結果: 全候補手がスキップされ `EG_BESTROW = FFH` のまま → AIset_EG は手を指さず無言でリターン → DoTurn は PASS 処理をしないまま次ターンへ → YOU PASS ループ

**修正内容:**

`SearchFull` の `SF_HasMove`:
- 比較前に `CP 81H; JR Z,SF_DO_UPDATE` を追加
- 初回（sentinel 値）は無条件採用、2回目以降のみ比較

`AIset_EG` の外ループ:
- `LD A,(EG_BESTROW); CP 0FFH; JR Z,AEGM_UPDATE` を追加
- `EG_BESTROW=FFH`（未発見）なら無条件採用、以降は符号付き比較

**根本的な原因:**  
有効スコア範囲 -64..+64（128通り）に対し、8bit符号付き減算は最大127しか扱えない。  
sentinel `81H`（-127）と正値スコア（例: +64）の差 = +191 → 8bitオーバーフロー → 符号が逆転。  
→「初回は比較しない」パターンで回避。2回目以降は実スコア同士の比較なので問題なし（差は最大±128だが実用範囲内）。

### 次のTODO

1. ~~**MM2_AB_EG.ASM 実機確認**（バグ修正3点・閾値=2で動作確認）~~ ✓ 完了
2. 閾値を 3〜4 に上げて処理時間を計測
3. PASS 連続2回・DRAW の動作テスト
4. ムーブオーダリング → depth-3 検討

---

## MM2_AB_EG.ASM 実機確認 (2026-04-17)

閾値=2 での動作確認完了。残り2手から終盤完全読みに切り替わり、正常に終局した。
PASS は発生しなかったため PASS 時の挙動は未確認。

### 確認結果

| 項目 | 結果 |
|------|------|
| 終盤切り替え（残り2手） | ✓ 正常動作 |
| negamax 完全読みで終局 | ✓ 正常終局 |
| α-β バグ修正効果 | ✓ ハングなし |
| PASS 時の挙動 | 未確認（今回 PASS なし） |

### 次のTODO

1. 閾値を 3〜4 に上げて処理時間を計測（PIOA D7 → Pico 計測）
2. PASS 連続2回・DRAW の動作テスト

---

## gameDisplay.py 連続PASS表示バグ修正 (2026-04-20)

### 症状
連続PASS2回でゲーム終了したとき、Pico画面の時間表示欄が空白のままで "Consec. PASS" が表示されなかった。

### 原因
`process_line()` の `global` 宣言に `time_text` が抜けており、ローカル変数への代入になっていた。

### 修正
`global score_text, move_text, human_text, ...` に `time_text` を追加。
合わせて `Game ended by consecutive passes.` 受信時に `time_text = "Consec. PASS"` をセットする処理を追加。

---

## gameDisplay.py DRAW表示バグ修正 (2026-04-20)

### 症状
DRAW時に Pico 画面に何も表示されなかった。

### 原因
`process_line()` の条件が `line == 'DRAW'`（大文字）だったが、Z80の `MSG_DRAW` は `"Draw"`（小文字d）を送出する。

### 修正
`line in ('DRAW', 'Draw')` に変更。

---

## MM2_AB_MO.ASM 実機確認 (2026-04-20)

- ムーブオーダリング効果により処理時間が大幅短縮（体感で明らかに高速化）
- 連続PASS2回でのゲーム終了・Consec. PASS 表示を実機確認
- DRAW 表示も実機確認済み

### 次のTODO

1. 処理時間を数値で計測（PIOA D7 → Pico 計測）
2. depth-3 実装の検討（処理時間次第）
3. ROM ブート化

---

## Phase 3-2: Python Phase2評価改善 Z80移植計画 (2026-04-20)

Python mm3_ab.py の Phase2評価（安定石・序盤/中盤/終盤切り替え）を
MM2_AB_MO.ASM をベースに段階的に移植する。

### 移植ステップ

| Step | 内容 | 状態 |
|------|------|------|
| Step 1 | CountEmpty による序盤/中盤/終盤の切り替え枠（評価式は現行のまま） | 🔲 |
| Step 2 | モビリティ差への乗算（mob_diff×8/12, シフト+加算） | 🔲 |
| Step 3 | 安定石カウント実装（コーナー＋辺の連続石） | 🔲 |
| Step 4 | stable_diff の重み付け（×30/50）を評価式に組み込み | 🔲 |

### Z80移植の制約

- 差分（my - opp）が負になる → 符号付き16bit演算が必要
- 係数は固定なので汎用乗算不要 → シフト+加算のインライン展開
- 安定石カウントを全ノードで呼ぶと重くなる → AIset最上位ノードのみで計算
- 終盤（空き<12）の stone_diff×100 は既存の終盤完全読み凍結中のため後回し

### 新ファイル
MM2_AB_MO.ASM をベースに MM2_AB_EV.ASM（EV=Evaluation）として作成予定。

---

## MM2_AB_EV.ASM 実機確認 (2026-04-20)

Step1〜4 全て完了・実機動作確認済み。

| Step | 内容 | 状態 |
|------|------|------|
| Step 1 | 序盤/中盤/終盤フェーズ切り替え枠 | ✅ |
| Step 2 | モビリティ差への乗算（×12/8/4） | ✅ |
| Step 3 | CountStable実装（コーナー＋辺の連続石） | ✅ |
| Step 4 | stable_diff重み付け（×30/50/30） | ✅ |

処理時間: 最大1秒以下（ムーブオーダリング効果で高速）

### 次のTODO（明日）

depth-3 Z80実装（MM2_AB_EV.ASM をベースに MM2_AB_D3.ASM として作成予定）

---

## MM2_AB_D3.ASM 実機確認 (2026-04-21)

MM2_AB_EV.ASM をベースに depth-3 を実装・実機動作確認済み。

### 実装内容

| ply | 関数 | 内容 |
|-----|------|------|
| ply1 | AIset | AI着手（BOARD_SAVE1）← 変更なし |
| ply2 | OppBestScore_d3 | OPP着手（BOARD_SAVE2）← d2を置換 |
| ply3 | AiBestScore_d3 | AI着手（BOARD_SAVE3）← 新規 |
| leaf | ID3_LOOP | OPP手をPOS_WEIGHT+flipsで推定 ← 新規 |

### α-β 枝刈り

- ID3_LOOP: `OBS3_BEST >= D3_AI_ALPHA` → α-cutoff
- AiBestScore_d3: `D3_AI_BEST >= OBS2_MIN_AI` → β-cutoff
- OppBestScore_d3側のβ-cutoffは未実装

### 処理時間

| 局面 | 処理時間 |
|------|----------|
| 最大 | 約12秒 |

フリーズなし・正常終局を確認。

### 次のTODO

- 処理時間 12秒は長い可能性あり → 高速化を検討
  - 選択肢A: OppBestScore_d3レベルのβ-cutoff追加
  - 選択肢B: 序盤はdepth-2・終盤でdepth-3 に切り替え ← 実装済み
  - 選択肢C: 現状のまま許容する

---

## MM2_AB_D3.ASM depth切り替え実装 (2026-04-21)

オセロ大会の制限時間4秒に対応するため、空きマス数で depth-2/3 を切り替える機能を追加。

### 実装内容

```
空きマス >= D3_THRESHOLD(=20) → depth-2（< 1秒、序盤〜中盤）
空きマス <  D3_THRESHOLD(=20) → depth-3（終盤、手数が絞られ速い）
```

- `D3_THRESHOLD EQU 20` 定数追加（1行変更で調整可能）
- `EMPTY_CACHE` / `USE_DEPTH3` 変数追加
- AIset 入口で CountEmpty 結果を保存し閾値判定
- AMM_LOOP で `USE_DEPTH3` に基づき OppBestScore_d2/d3 を切り替え
- OppBestScore_d2 を復元（depth-2 パス用）

### 実機確認結果 (2026-04-21)

先手・後手ともに全局面で処理時間 4秒以下を確認。**大会用バージョンとして確定。**

### 次のTODO

1. ROM ブート化（オセロ完成後）

---

## MM2_AB_D3.ASM D3_THRESHOLD 調整 (2026-04-21)

### 試行結果

| 閾値 | 結果 |
|------|------|
| 20 | 4秒以下 ✓（大会用確定） |
| 30 | 5秒超 ✗（30手前後から処理時間が増加） |
| 25 | 実機計測待ち（次回確認） |

### 現在の設定

`D3_THRESHOLD EQU 25`（空き < 25 → depth-3 / 空き >= 25 → depth-2）

### 大会について

- 参加者は自作CPU・自作アセンブラで製作したAIオセロを持ち寄る大会
- マインクラフトCPU（≈10Hz）・ロジックICCPU（≈100KHz）なども参加
- クロックが10倍遅いごとに持ち時間+8秒のハンデあり
- Z80 10MHzは高クロック側のため持ち時間ハンデは少ない
- 「実機で動くAIオセロを持参できること」自体が意義のある大会

---

## Python AI 速度計測・遺伝的アルゴリズム実装 (2026-04-21)

### benchmark.py 作成・計測結果

| depth | 1ゲームあたり | 1000ゲーム |
|-------|------------|-----------|
| depth-3 | 2.61秒 | 43.5分 |
| depth-2 | 0.67秒 | 11.1分 |

depth-3は重すぎるため、**学習はdepth-2で行う**方針に決定。

### optimize_weights.py 作成

遺伝的アルゴリズムで POS_WEIGHT テーブル（64マス）を最適化するスクリプト。

#### 設計方針

- オセロ盤の4重対称を利用し、64パラメータを**10パラメータに圧縮**して探索
- 評価: 現行V1テーブルのAIと depth-2 で N_GAMES=10 ゲーム対戦（先手・後手均等）
- 遺伝的操作: 一様交叉 + 突然変異（確率0.3、変化幅±15）
- 個体数=20、エリート=5、世代数=50、所要時間≈110分

#### 10パラメータの意味

| idx | 代表マス | 名前 | V1値 |
|-----|---------|------|------|
| 0 | A1 | corner | 120 |
| 1 | B1/A2 | c_sq | 5 |
| 2 | C1/A3 | edge_near | 30 |
| 3 | D1/A4 | edge_ctr | 25 |
| 4 | B2 | x_sq | 1 |
| 5 | C2/B3 | near_x | 15 |
| 6 | D2/B4 | inner_edge | 15 |
| 7 | C3 | inner | 20 |
| 8 | D3/C4 | inner2 | 20 |
| 9 | D4 | center | 18 |

#### 出力

完了後にZ80用DEFBテーブルをそのまま貼り付けられる形式で表示される。

### 実行開始

2026-04-21 夜に実行開始。結果は翌日確認予定。
