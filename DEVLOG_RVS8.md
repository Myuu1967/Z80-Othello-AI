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
                 └─ RVS8_MM1_MOB.ASM  ← 現行最新
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

## 候補機能 (未着手)

| 機能 | 概要 | 備考 |
|---|---|---|
| 2手先読み | depth-2 minimax | 計算量 ≈ depth-1の64倍 → α-β必須 |
| α-β 枝刈り | 16bit α/β 値をスタック管理 | depth-2 以上に不可欠 |
| 安定石評価 | 角から連続する石を加点 | 算出コスト高 |
| 終盤完全読み | 残り≤12手で完全 minimax | 終盤は合法手が絞られ高速 |
| 盤面重み合計差 | Σweight(AI石) - Σweight(相手石) | 既存の16bit演算で対応可 |
