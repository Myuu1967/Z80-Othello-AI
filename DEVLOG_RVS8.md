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

---

## GA最適化結果・Z80テーブル反映 (2026-04-22)

### 最終ランキング（精密トーナメント 50ゲーム/ペア）

| 順位 | 勝数/500 | パラメータ |
|------|---------|-----------|
| 1位 | 119勝 | [128, 3, 17, 30, 1, 36, 15, 18, 29, 1] ← 優勝 |
| 2位 | 99勝 | [82, 1, 49, 34, 1, 15, 5, 20, 20, 1] |
| 3位 | 99勝 | [84, 1, 1, 34, 1, 15, 5, 28, 17, 1] |
| 4位 | 84勝 | [120, 5, 30, 25, 1, 15, 15, 20, 20, 18] |
| 5位 | 80勝 | [120, 5, 30, 25, 1, 15, 15, 20, 20, 18] |

### V1からの主な変化

| 名前 | V1 | GA優勝 | 差 | 考察 |
|------|-----|--------|-----|------|
| corner | 120 | **128** | +8 | 角の価値を上昇 |
| c_sq | 5 | **3** | -2 | Cマス(角隣辺)はさらに低下 |
| edge_near | 30 | **17** | -13 | 辺(C1/A3)は思ったより低い |
| edge_ctr | 25 | **30** | +5 | 辺中央(D1/A4)は上昇 |
| x_sq | 1 | **1** | 0 | Xマス変化なし |
| near_x | 15 | **36** | +21 | C2/B3 が大幅上昇（最大の変化） |
| inner_edge | 15 | **15** | 0 | 変化なし |
| inner | 20 | **18** | -2 | 微減 |
| inner2 | 20 | **29** | +9 | D3/C4 が上昇 |
| center | 18 | **1** | -17 | 中央4マスが大幅低下 |

### 最適化済みテーブル（MM2_AB_D3.ASM に反映済み）

```
;       A    B    C    D    E    F    G    H
DEFB  128,   3,  17,  30,  30,  17,   3, 128  ; 1
DEFB    3,   1,  36,  15,  15,  36,   1,   3  ; 2
DEFB   17,  36,  18,  29,  29,  18,  36,  17  ; 3
DEFB   30,  15,  29,   1,   1,  29,  15,  30  ; 4
DEFB   30,  15,  29,   1,   1,  29,  15,  30  ; 5
DEFB   17,  36,  18,  29,  29,  18,  36,  17  ; 6
DEFB    3,   1,  36,  15,  15,  36,   1,   3  ; 7
DEFB  128,   3,  17,  30,  30,  17,   3, 128  ; 8
```

POS_ORDER（ムーブオーダリング用）も新テーブルの重み順に更新済み。

### 次のTODO

1. **実機アセンブル・動作確認**（新POS_WEIGHTテーブルで正常動作するか）
2. **D3_THRESHOLD=25 の実機計測**（新テーブルでの処理時間確認）

---

## MM2_AB_D3.ASM GA最適化テーブル 実機確認 (2026-04-22)

GA最適化済み POS_WEIGHT テーブル・POS_ORDER 更新版を実機で動作確認。

| 項目 | 結果 |
|------|------|
| 先手（黒）での動作 | ✓ 正常 |
| 後手（白）での動作 | ✓ 正常 |
| 異常終了・フリーズ | なし |

処理時間: 先手・後手ともに4秒以下。大会用バージョンとして確定。

---

## ROM単独起動化 作業開始 (2026-04-22)

### 背景・目的

モニタROM不要で電源ON直後からオセロが起動するよう、ROM 0000H からの単独起動版を作成する。
ハードウェア: **TMPZ84C015-BF10**（Z80 CPU + SIO/CTC/PIO 内蔵）
外部クロック: 約20MHz → 内部CGC（クロック発生回路）で1/2 → CPU/CTC は10MHz動作

### 作成ファイル

`asm/MM2_AB_ROM.ASM` — MM2_AB_D3.ASM をベースにROM起動対応

- ORG 0000H に JP START のリセットベクタ
- ORG 8000H に RAM変数（BOARD, BOARD_SAVEx, 各ワーク変数）
- BOARD_INIT はROM内に定数として配置
- GO_QUIT で RST 00H（0000H へのリセット）

### InitCTC3 / InitSIOA 初期化順序の判明

モニタROM（AKI-80MONI_ROM.HEX）を解析し、0191H付近に初期化ルーティンを確認:

```
0191: LD HL, 01A8H   ; SIOA_INIT_TBL
0194: LD B, 9
0196: LD C, 19H      ; SIOA CTL port
0198: OTIR           ; SIOAを先に初期化（レジスタ設定のみ、クロック不要）
019A: LD A, 17H
019C: OUT (13H), A   ; CTC3 コントロールワード（タイマーモード/プリスケーラ/16）
019E: LD A, 04H
01A0: OUT (13H), A   ; CTC3 時定数=4 → タイマー起動
01A2: RET

01A8: 18 04 44 03 C1 05 6A 01 00  ; SIOA_INIT_TBL（9バイト）
```

**重要な発見:**
- モニタは SIOA初期化(OTIR) → CTC3起動 の順
- SIOAのレジスタ設定はクロック不要なので先でも可
- ボーレートクロックの計算: 10MHz / 16(プリスケーラ) / 4(TC) = 156,250Hz → x16モードで ≈9765bps（9600bpsとして使用）
- CTC3ポートアドレス: 13H ✓、制御ワード: 17H ✓、時定数: 04H ✓

### 現状（調査中）

`SIOA_TEST.ASM`（最小限のSIOAテスト、CRLFループ送信）を書き込んだが TeraTerm に何も表示されない。

考えられる原因:
- CGC /2 の影響でボーレート計算のどこかがずれている可能性
- TMPZ84C015固有の初期化が必要な可能性（ポート33H/37Hへのモニタ初期化コードの意味未解明）
- ハードウェア配線・ROM書き込み確認が必要

### SIOA_TEST.ASM の構成

```asm
START:
    LD  SP, 0FFF0H
    DI
    CALL InitCTC3    ; CTC3起動（タイマー mode, /16, TC=4）
    CALL InitSIOA    ; SIOA設定（x16, 8N1, Tx/Rx有効）
MAIN:
    LD  HL, MSG      ; "\r\nSIOA OK\r\n"
    (送信ループ)
    (約1秒ディレイ)
    JP  MAIN

PutChar:
    (TxRDY=RR0 bit2 待ち → OUT (18H), A)
```

**MM2_AB_D3.ASM（D3_THRESHOLD=25、GA最適化テーブル）を大会用バージョンとして確定。**

---

## AT28C256 ピン非互換問題の調査 (2026-04-23)

### 症状

SIOA_TEST.ASM / PIOA_TEST.ASM を AT28C256 に書き込んでも TeraTerm 無反応・LED 無反応。
モニタROM（27C256）では正常動作。

### 原因

27C256 と AT28C256 はピン配置が**非互換**。

| ピン | 27C256 | AT28C256 |
|------|--------|----------|
| 1番  | VPP（通常運転時 VCC） | **A14** |
| 27番 | **A14** | WE#（書込制御） |

Super AKI-80 のソケットは 27C256 用に設計されているため:
- ソケット1番 → VCC（27C256 の VPP 用）
- ソケット27番 → Z80 の A14

AT28C256 を挿すと:
- **A14（ピン1）= VCC = 常に HIGH** → EEPROM は常に上位16KB を参照
- **WE#（ピン27）= Z80 A14 = 0**（ROM空間 0000H〜7FFFH アクセス時）

AT28C256 は OE#=LOW かつ WE#=LOW の同時状態が禁止のため、Z80 が ROM を読もうとするたびにチップがデータを出力しない。

### 試したこと

- PPI0/PPI1 初期化追加（モニタROM 0090H 相当）→ 効果なし
- EEPROM オフセット 4000H への書き込み → 効果なし（WE# 問題は残る）

### 解決策（未実施）

AT28C256 のピン2本をソケットから浮かせて配線し直す:

- **ピン1（A14）** → ソケットから抜いて **GND に接続**（A14=0固定、下位16KB使用）
- **ピン27（WE#）** → ソケットから抜いて **VCC に接続**（常に読み出しモード）

その後 EEPROM オフセット **0000H** にコードを書き込む。

コードは 16KB 未満なので下位16KB（0000H〜3FFFH）で十分。

### 方針変更 (2026-04-23)

AT28C256 のピン改造は作業コストが高いため却下。
**27C256 EPROM（UV消去型）を使用する方針に変更。**
イレーサー・ライターは手元にある。気が向いたタイミングで消去・書き込みを実施予定。

---

## 次期改良計画 (2026-04-23)

ROM起動化を一時保留し、オセロ AIの改良に着手する方針に決定。

### 未実装の α-β 枝刈り（速度改善・D3_THRESHOLD拡大が目標）

現在の枝刈り実装状況:

| レベル | 関数 | cutoff | 状態 |
|--------|------|--------|------|
| leaf OPP | ID3_LOOP | α-cutoff: OBS3_BEST >= D3_AI_ALPHA | ✅ 実装済み |
| ply3 AI | AiBestScore_d3 | β-cutoff: D3_AI_BEST >= OBS2_MIN_AI | ✅ 実装済み |
| ply2 OPP | OppBestScore_d3 | β-cutoff: OBS2_MIN_AI が下がりすぎ → AIset早期終了 | ❌ **未実装** |
| ply2 OPP | OppBestScore_d2 | 同上（depth-2パス） | ❌ **未実装** |

#### OppBestScore_d3 の β-cutoff 概要

```
条件: POS_WEIGHT[ai_pos] + OBS2_MIN_AI + 128(最大mobility) ≤ AI_BEST_SCORE
      → この AIの手は既存ベストを超えられない → OPP探索を早期終了
```

- `AI_BEST_SCORE` が 16bit なので Z80 での実装に工夫が必要
- `AI_BEST_SCORE` の最大値は 503（0x1F7）なので high byte は 0 か 1 のみ
- 実装方針: AIset 内で呼び出し前に 8bit 閾値 `D3_OPP_BETA` を計算して渡す

### 改良ロードマップ更新 (2026-04-23)

**OppBestScore_d2 の β-cutoff を優先することに決定。**
理由: depth-2 パスはゲーム前半〜中盤（空き≥25、約35手分）で使われるため影響が大きい。
depth-3 側（OppBestScore_d3）は空き<25の終盤のみ → 後回し。

| 順序 | 内容 | 期待効果 | 難度 |
|------|------|---------|------|
| **1** | **OppBestScore_d2 β-cutoff 実装（次の作業）** | **序盤〜中盤の速度↑ → D3_THRESHOLD 拡大** | **中** |
| 2 | OppBestScore_d3 β-cutoff 実装 | 終盤速度↑ | 中 |
| 3 | 実機計測・D3_THRESHOLD 調整 | 4秒以内の最大値を確認 | 低 |
| 4 | 終盤完全読み（SearchFull）復活 | 強さ↑ | 低（既存コードあり） |
| 5 | GA再最適化（depth-3で学習） | 強さ↑ | 低（Python側） |

### OppBestScore_d2 β-cutoff 実装設計 (2026-04-23)

#### フェーズ別 mob_stable 最大値

depth-2 パスでは終盤フェーズ（空き<12）は到達しない（常にdepth-3）。

| フェーズ | mob最大 | stable最大 | 合計 |
|---------|--------|-----------|------|
| 序盤 (×12/×30) | 128×12=1536 | 16×30=480 | **2016** |
| 中盤 (×8/×50)  | 128×8=1024  | 16×50=800 | **1824** |
| 終盤 | depth-3パスのみ | — | — |

#### β-cutoff 条件

```
mm_score = POS_W[ai_pos] + OBS2_MIN_AI + mob_stable_term
cutoff 条件: POS_W + OBS2_MIN_AI + mob_stable_max ≤ AI_BEST_SCORE
→ OBS2_MIN_AI ≤ AI_BEST_SCORE - POS_W - mob_stable_max  (= OD2_BETA)
```

`OD2_BETA` が負または 0 の場合は無効（`OD2_BETA=0` = disabled 扱い）。
`OD2_BETA` が 256以上の場合は「この AI 手は絶対に既存ベストを超えられない」→ AI手ごとスキップ。

#### 実装2ステップ

**Step A: AIset 側（呼び出し前）**
- `POS_WEIGHT[B,C]` を先読みして `AMM_POS_W` に保存（後の重複ルックアップも削除）
- `OD2_BETA = AI_BEST_SCORE - AMM_POS_W - MOB_STABLE_MAX` (16bit計算)
  - 負 → `OD2_BETA=0`（disabled）
  - >255 → AI手をスキップ（`JP AMM_NEXTCOL`）
  - 1..255 → `OD2_BETA` に保存

**Step B: OppBestScore_d2 内（OBS2_MIN_AI 更新直後）**
```asm
; β-cutoff: OBS2_MIN_AI ≤ OD2_BETA → この AI 手は既存ベスト超えられない
LD   A,(OD2_BETA)
OR   A
JR   Z,OD2_NO_BETA   ; OD2_BETA=0 → disabled
LD   B,A             ; B = OD2_BETA
LD   A,(OBS2_MIN_AI)
CP   B               ; OBS2_MIN_AI - OD2_BETA
JR   C,OD2_END       ; < → cutoff
JR   Z,OD2_END       ; = → cutoff
OD2_NO_BETA:
```

#### コンスタント版 → フェーズ別への切り替え

初期実装: `MOB_STABLE_MAX = 2016`（定数）
フェーズ別改良: `D2_MOB_MAX` (16bit変数) を GAME_PHASE に基づき AIset 先頭で設定 → **1行変更のみ**

```asm
; GAME_PHASE 設定直後に追加
LD   HL,2016
LD   A,(GAME_PHASE)
CP   1
JR   NZ,AEV_SET_BETA_MAX
LD   HL,1824           ; 中盤
AEV_SET_BETA_MAX:
LD   (D2_MOB_MAX),HL
```

---

## MM2_AB_BCUT.ASM 実装完了 (2026-04-23)

`MM2_AB_D3.ASM` をベースに `MM2_AB_BCUT.ASM` を作成し、OppBestScore_d2 β-cutoff を実装。

### 変更内容

| 箇所 | 内容 |
|------|------|
| ヘッダー | β-cutoff 説明・日付追加 |
| EQU | `D2_MOB_MAX EQU 2016`（序盤基準の保守的最大値） |
| RAM変数 | `AMM_POS_W`（POS_WEIGHTキャッシュ）・`OD2_BETA`（β閾値）追加 |
| AIset pre-filter | `JP Z,AMM_NEXTCOL` 直後に挿入。POS_WEIGHT先読み→OD2_BETA計算→OD2_BETA>255ならAI手スキップ |
| AIset POS_W参照 | 後段の12命令ルックアップを `LD A,(AMM_POS_W)` 1命令に置換（副次的な高速化） |
| OppBestScore_d2 | `OBS2_MIN_AI` 更新直後にβ-cutoffチェック追加（OBS2_MIN_AI≤OD2_BETAでOD2_ENDへ） |

### 実装詳細

**AIset pre-filter（OD2_BETA計算）:**
```
OD2_BETA = AI_BEST_SCORE - AMM_POS_W - D2_MOB_MAX (16bit)
  負 → OD2_BETA=0 (disabled)
  >255 → この AI 手をスキップ (JP AMM_NEXTCOL)
  1..255 → OD2_BETA に保存
```

**OppBestScore_d2 β-cutoffチェック（OBS2_MIN_AI更新直後）:**
```asm
LD   A,(OD2_BETA)
OR   A
JR   Z,OD2_RESTORE   ; disabled
LD   B,A
LD   A,(OBS2_MIN_AI)
CP   B
JR   C,OD2_END       ; < → cutoff
JR   Z,OD2_END       ; = → cutoff
```

### ファイル系譜

```
MM2_AB_D3.ASM  ← 大会用確定版
  └─ MM2_AB_BCUT.ASM  ← β-cutoff実装（アセンブル・実機確認待ち）
```

### アセンブル確認 (2026-04-23)

アセンブル通過確認済み。①（pre-filter）②（OppBestScore_d2内チェック）とも実装済み。

### 実機動作確認 (2026-04-23)

- 先手・後手ともに正常にゲーム終了を確認 ✓
- **D3_THRESHOLD=25 のまま**: depth-3 に移行した局面で 5〜6秒かかる場面あり

### 考察・次の方針

D2 β-cutoff 実装後も、depth-3 パス（OppBestScore_d3）の処理時間が長い局面が存在する。
D3_THRESHOLD を 30 に上げるには **OppBestScore_d3 側の β-cutoff** が必要。

### 次のTODO

1. **OppBestScore_d3 β-cutoff 実装** → `MM2_AB_BCUT.ASM` に追加（or 新ファイル）
2. 実機で処理時間計測・D3_THRESHOLD 調整
3. 問題なければフェーズ別 D2_MOB_MAX（1行変更）で追加改善

---

## 5/3凍結・5/9大会 ロードマップ (2026-04-24)

大会: 2026-05-09 / 機能凍結: 2026-05-03 / 予備: 2026-05-05

| 期間 | 作業 | 備考 |
|------|------|------|
| 4/24〜4/25 | OppBestScore_d3 β-cutoff 実装・実機確認 | 速度改善の最優先 |
| 4/26 | D3_THRESHOLD 調整・実機計測（25→30以上を狙う） | β-cutoff効果を確認 |
| 4/27 | 評価値表示（Z80 SIOA出力＋Pico表示） | 表示フォーマットは実装時に決定 |
| 4/28〜4/29 | EPROM（27C256）単独起動動作確認 + 投了/中断処理（Z80+Pico） | 来週前半 |
| 4/30〜5/1 | Pico棋譜記録・過去盤面ログ保存機能 | 来週後半 |
| 5/2 | GA再最適化（depth-3で夜間学習）・終盤完全読み復活（余裕次第） | — |
| 5/3 | **全機能凍結・最終動作確認** | 以降は設定調整のみ |

### 新規追加項目（来週中に実施）

#### EPROM（27C256）単独起動動作確認
- MM2_AB_D3.ASM（またはBCUT版）を27C256に焼いてモニタROMと差し替え
- 電源ON直後からオセロが起動することを確認
- InitSIOA / PIOA / PIOB 初期化が正しく機能するか確認

#### 投了/中断処理（Z80側）
- ゲーム中にスイッチ（SW4 等）入力で中断
- SIOA にも中断コマンド（例: 'q' 以外のキー）を用意
- 中断後は初期画面（先後手選択）に戻る
- Pico側も中断を受け取りLCD表示をリセット

#### Pico棋譜記録・過去盤面ログ
- 対局中の全着手をPicoのフラッシュ（LittleFS）に記録
- 盤面スナップショット（各ターン後の64マス状態）もログに残す
- 既存の `replay_log('/replay.txt')` 機能と連携させる方向で検討

---

## OppBestScore_d3 β-cutoff 実装 (2026-04-24)

`MM2_AB_BCUT.ASM` に OppBestScore_d3 の β-cutoff を追加。同時に OppBestScore_d2 の潜在的なスタックバグも修正。

### 変更内容

#### OppBestScore_d3 β-cutoff（新規）

`AiBestScore_d3` 呼び出し後、`OBS2_MIN_AI` を更新した直後に挿入:

```asm
        ; β-cutoff: OBS2_MIN_AI <= OD2_BETA → AIset はこの AI 手を採用しない
        LD   A,(OD2_BETA)
        OR   A
        JR   Z,OD3_RESTORE   ; OD2_BETA=0 → disabled
        LD   B,A             ; B = OD2_BETA
        LD   A,(OBS2_MIN_AI)
        CP   B               ; OBS2_MIN_AI - OD2_BETA
        JR   C,OD3_BCUT      ; OBS2_MIN_AI < OD2_BETA → β-cutoff
        JR   Z,OD3_BCUT      ; OBS2_MIN_AI = OD2_BETA → β-cutoff

OD3_BCUT:
        LD   HL,BOARD_SAVE2
        CALL RestoreBoard    ; ← 先にボード復元
        POP  BC              ; ← スタック整合
        JP   OD3_END
```

`OD2_BETA` は AIset の pre-filter で計算済みのため d2/d3 で共有。

#### OppBestScore_d2 スタックバグ修正

**バグの内容:** β-cutoff 発火時に `JR C/Z, OD2_END` で直接 OD2_END へジャンプしていたが、
このパスでは `SaveBoard/ApplyMove` 前の `PUSH BC` に対する `POP BC` がスキップされ、
スタックが1段ずれた状態で `RET` が実行されるためクラッシュの可能性があった。

**実際の影響:** `OD2_BETA > 0` になるには `AI_BEST_SCORE > AMM_POS_W + 2016` が必要で、
実用的な mm_score の範囲内では発火しにくく、テストでは問題が表面化しなかった。

**修正:** `JR C/Z, OD2_END` を `JR C/Z, OD2_BCUT` に変更し、`OD2_BCUT` で
`RestoreBoard + POP BC` を実行してから `JP OD2_END` する安全なパスを追加。

```asm
OD2_BCUT:
        LD   HL,BOARD_SAVE2
        CALL RestoreBoard
        POP  BC
        JP   OD2_END
```

### 期待効果

depth-3 パス（空き < 25）で OPP が十分悪い応手を見つけた時点で OPP 外ループを
打ち切れるため、5〜6秒かかっていた局面が短縮される見込み。

### 次のTODO

1. **アセンブル・実機確認**（先手・後手ともに正常動作を確認）
2. **処理時間計測**（PIOA D7 → Pico 計測、D3_THRESHOLD=25 で改善幅を確認）
3. **D3_THRESHOLD 調整**（25 → 30 以上を狙う）

---

## MM2_AB_BCUT.ASM 実機確認・β-cutoff 無効問題の分析 (2026-04-24)

### 実機テスト結果

動作不具合なし。ただし **AI が以前より弱く見える**（角を相手に渡す手を打つ）報告あり。

### 原因分析: β-cutoff が dead code

β-cutoff が実際には一度も発火していないことが判明。

**OD2_BETA の計算式:**

```
OD2_BETA = AI_BEST_SCORE - AMM_POS_W - D2_MOB_MAX
```

| 変数 | 値 | 備考 |
|---|---|---|
| AI_BEST_SCORE (max) | ≈ 1935 | depth-3 が有効な中盤以降の実測上限 |
| AMM_POS_W (min) | 1 | Xマス（POS_WEIGHT最小値） |
| D2_MOB_MAX | 2016 | EQU定数（序盤基準の保守的最大値） |

`1935 - 1 - 2016 = -82` → 負値 → 16bit 演算で 0 以下とみなし OD2_BETA=0 → **β-cutoff 無効化**

`D2_MOB_MAX = 2016` は序盤（フリップ最大 64 × mob 最大 32 ≒ 2016）の理論値。しかし depth-3
が有効になる中盤以降の実際の上限は約 1552。この乖離により常に OD2_BETA ≤ 0 となる。

### AI が弱く見える原因

β-cutoff が dead code のため、BCUT.ASM の探索結果は D3.ASM と **数学的に同一**。  
弱さの原因は以下のいずれか（または複合）：

1. D3.ASM との比較で統計的ゆらぎ（対局数不足）
2. GA最適化 POS_WEIGHT が depth-2 向けに最適化されており depth-3 では最善でない
3. 偶然の一致（角を渡した手が実際に最善だった可能性）

### 修正方針

`D2_MOB_MAX EQU 2016` → `D2_MOB_MAX EQU 1600` に変更することで β-cutoff が有効になる。

**修正後の期待値:**
- `1935 - 1 - 1600 = 334` → OD2_BETA > 0 → β-cutoff が発火する局面が存在
- depth-3 の処理時間短縮 → D3_THRESHOLD を安全に引き上げ可能

### D3_THRESHOLD 引き上げの前提条件

「閾値を上げれば強くなる」は正しいが、速度改善なしに閾値を上げると処理時間が悪化する。

| 状態 | depth-3 最大処理時間 | D3_THRESHOLD=25 | D3_THRESHOLD=30 |
|---|---|---|---|
| 現在（β-cutoff 無効） | 5〜6 秒 | 一部で 4 秒超え | さらに悪化 |
| D2_MOB_MAX=1600（β-cutoff 有効） | 要計測 | 要計測 | 多分 OK |

**正しい順序:**

1. `D2_MOB_MAX EQU 1600` に変更してアセンブル
2. 実機で処理時間計測（D3_THRESHOLD=25 のまま）
3. 4 秒以内を確認できたら `D3_THRESHOLD` を 30 以上に引き上げ
4. 再度処理時間計測・動作確認

---

## リファクタリング計画 (2026-04-24)

### 背景

D2_MOB_MAX=1600 変更後の実機計測で依然 5 秒の局面が発生。  
コードの複雑さがバグ・チューニング困難の根本原因と判断し、大会前にリファクタリングを実施する。

- 大会: 2026-05-09
- 凍結目標: 2026-05-06（バッファ3日）
- 作業可能日数: 約13日

### 判明した追加問題

α-cutoff（AMM_BETA_SKIP）も同じ問題を抱えていることが判明。

```
ply1 の AMM_BETA_SKIP 条件: OD2_BETA > 255 → AI の手をスキップ
```

`OD2_BETA = AI_BEST_SCORE - AMM_POS_W - D2_MOB_MAX` で計算されるため、  
D2_MOB_MAX が大きすぎると α-cutoff も発火しない（β-cutoff と完全に同一の問題）。

### リファクタリング ステップ（大項目）

| # | 内容 | 工数目安 |
|---|---|---|
| Step1 | **α-β カットオフ値の計算見直し** — `D2_MOB_MAX`→`MOB_STABLE_CAP` リネーム＋正しい上限値計算。α/β 両方に反映 | 1〜2日 |
| Step2 | **変数名・コメント整理** — 4-plyツリー構造をコードで明示、変数名を意味明確に | 1〜2日 |
| Step3 | **D3_THRESHOLD 調整** — Step1 の速度改善確認後に設定（25→30 を狙う） | 半日 |
| Step4 | **総合テスト** — 複数局＋処理時間計測 | 1〜2日 |

### オセロ基礎構造について

実機対局で盤面操作・反転・合法手判定・石数計数は問題なし確認済み。  
リファクタリングはAIロジック（α-β探索）部分のみに集中できる。

---

## リファクタリング方針の詳細決定 (2026-04-25)

### ファイル系譜方針

`MM2_AB_BCUT.ASM` をベースに、ステップごとに番号付きファイルを作成する方式を採用。

```
MM2_AB_BCUT.ASM  ← 触らない（現行の動作確認済み版）
  └─ RFCT000.ASM  ← 変数名・ラベル名・関数名リネームのみ（ロジック変更なし）
       └─ RFCT001.ASM  ← カットオフ定数値をフェーズ別に分割
            └─ RFCT002.ASM  ← AMM_BETA_SKIP 閾値修正 + フェーズ別分岐追加
                 └─ RFCT003.ASM  ← D3_THRESHOLD 調整・総合テスト版
```

各ファイルはアセンブル通過後に git commit する。バグ混入時に一世代前に戻せる。

### RFCT000 で決定した命名規則

#### 変数名（DEFBラベル）

| 旧 | 新 | 意味 |
|---|---|---|
| `AMM_IDX` | `P1_IDX` | ply1 AIループインデックス |
| `OD2_IDX` | `P2_IDX` | ply2 OPPループインデックス（d2/d3共用） |
| `ID2_IDX` | `P3_IDX` | ply3 AIループインデックス |
| `LD3_IDX` | `LF_IDX` | leaf OPPループインデックス |
| `OBS2_MIN_AI` | `P2_ALPHA` | OPP ply2 の α 値 |
| `OD2_BETA` | `P1_BETA` | AI ply1 の β 閾値（d2/d3共用） |
| `OBS_BEST` | `P2_INNER_BEST` | OppBestScore_d2 内ループ一時最善値 |
| `D3_AI_BEST` | `P3_BEST` | ply3 AI最善スコア |
| `D3_AI_ALPHA` | `LF_ALPHA` | leaf の α 閾値 |
| `OBS3_BEST` | `LF_BEST` | leaf OPP最善スコア |
| `AMM_POS_W` | `P1_POS_W` | ply1 AI位置重みキャッシュ |
| `D2_MOB_MAX` | `MOB_STABLE_CAP` | mob_stable項の上限（RFCT001でフェーズ別分割） |

#### ラベル名（JP/JR飛び先）

| 旧 | 新 | 対象 |
|---|---|---|
| `AMM_LOOP/NEXTCOL/END` | `P1_LOOP/P1_NEXT/P1_END` | AIset外ループ |
| `AMM_BETA_SKIP/DONE/DISABLE` | `P1_BSKIP/P1_BDONE/P1_BDIS` | AIsetプリフィルタ |
| `OD2_LOOP/NEXTCOL/END/BCUT` | `P2_LOOP/P2_NEXT/P2_END/P2_BCUT` | OppBestScore_d2 |
| `ID2_LOOP/NEXT/END` | `P2I_LOOP/P2I_NEXT/P2I_END` | OppBestScore_d2内ループ |
| `OD3_LOOP/NEXTCOL/END/BCUT` | `P2D3_LOOP/P2D3_NEXT/P2D3_END/P2D3_BCUT` | OppBestScore_d3 |
| `AB_D3_LOOP/NEXT/END/POP` | `P3_LOOP/P3_NEXT/P3_END/P3_POP` | AiBestScore_d3 |
| `ID3_L/NEXT/END` | `LF_LOOP/LF_NEXT/LF_END` | ID3_LOOP |

#### 関数名（CALLで呼ぶラベル）

| 旧 | 新 |
|---|---|
| `OppBestScore_d2` | `Ply2Best_D2` |
| `OppBestScore_d3` | `Ply2Best_D3` |
| `AiBestScore_d3` | `Ply3Best` |
| `ID3_LOOP` | `LeafEval` |

### RFCT001 で追加する定数

```asm
MOB_STABLE_CAP_EARLY EQU 1872  ; 96×12 + 24×30
MOB_STABLE_CAP_MID   EQU 1968  ; 96×8  + 24×50
MOB_STABLE_CAP_LATE  EQU 1104  ; 96×4  + 24×30
OBS_SCORE_MAX        EQU  192  ; POS_WEIGHT_MAX(128) + FLIPS_MAX(64)
```

根拠: mob_diff+64 max=96（合法手上限32+64）、stable_diff+8 max=24（AI_STABLE≦16実用上限）

---

## RFCT000 前準備・追加決定事項 (2026-04-25)

### 調査で判明したこと

- 新しい名前（P1_IDX 等）はファイル内に存在しない → 衝突なし、`replace_all` で安全
- `OppBestScore`（depth-1版、1085行）がどこからも `CALL` されていないデッドコードと判明
  - `OBS_BEST`・`OBS_COUNT` を d2 版と共用していたが、削除しても d2/d3 に影響なし

### ラベル表に追加した漏れ分（2026-04-25 承認）

| 旧ラベル | 新ラベル | 対象 |
|---------|---------|------|
| `AEV_EARLY` | `P1_PHASE_EARLY` | AIset フェーズ判定（序盤） |
| `AEV_MID` | `P1_PHASE_MID` | AIset フェーズ判定（中盤） |
| `AEV_SET_PHASE` | `P1_PHASE_LATE` | AIset フェーズ判定（終盤/LATE） |
| `AMM_SET_DEPTH` | `P1_SET_DEPTH` | AIset depth選択 |
| `AMM_CALL_D2` | `P1_CALL_D2` | OppBestScore_d2 呼び出し分岐 |
| `AMM_AFTER_OBS` | `P1_AFTER_OBS` | OppBestScore 呼び出し後 |
| `OD2_RETURN` | `P2_RETURN` | OppBestScore_d2 戻り処理 |
| `OD3_RETURN` | `P2D3_RETURN` | OppBestScore_d3 戻り処理 |

### RFCT000 で実施すること（確定）

- `OppBestScore`（depth-1版）を削除（デッドコード）
- 上記全ラベル・変数・関数名をリネーム
- ロジック・計算は一切変更しない

### リファクタの範囲・方針（2026-04-25 確定）

以下について検討し、**大会前は着手しない**と決定：

**評価値の定義統一**（255補数を繰り返す視点反転構造の整理）
- 全探索関数の計算ロジック書き直しが必要
- `SearchFull`（negamax方式）との整合が複雑
- バグ混入リスクが高い → **大会後の課題**

**minimax 構造の抜本的見直し**
- 探索構造（4-plyツリー・各関数の役割）は正しく動いている
- 触る必要なし → **現計画（RFCT000〜003）で十分**

**α-β カットオフの「効いていなかった」問題**
- 構造的な問題ではなく定数の計算ミス（D2_MOB_MAX が大きすぎた）
- RFCT001（定数値修正）・RFCT002（閾値修正）で対処済み → **追加作業不要**

---

## RFCT000.ASM アセンブル成功 (2026-04-25)

変数名・ラベル名・関数名リネーム + OppBestScore(depth-1 デッドコード)削除を実施。
アセンブルエラーなし。実機動作確認は RFCT001〜003 完了後に一括実施予定。

### 実施内容

- 変数 12個リネーム（D3_AI_BEST→P3_BEST、OBS2_MIN_AI→P2_ALPHA 等）
- ラベル 35個以上リネーム（P1_/P2_/P3_/LF_ プレフィックス体系）
- 関数 4個リネーム（OppBestScore_d2→Ply2Best_D2、OppBestScore_d3→Ply2Best_D3 等）
- OppBestScore（depth-1版, 約65行）削除：どこからも CALL されないデッドコード

### 次ステップ

RFCT001: MOB_STABLE_CAP をフェーズ別3定数に分割・正しい上限値に修正

---

## RFCT001.ASM アセンブル成功 (2026-04-25)

MOB_STABLE_CAP をフェーズ別3定数に分割し、正しい上限値を設定。アセンブルエラーなし。

### 実施内容

- `MOB_STABLE_CAP EQU 1600`（単一定数）を削除
- フェーズ別3定数を追加：
  - `MOB_STABLE_CAP_EARLY EQU 1872` (96×12 + 24×30: 序盤 mob_w=12/stable_w=30)
  - `MOB_STABLE_CAP_MID   EQU 1968` (96×8 + 24×50: 中盤 mob_w=8/stable_w=50)
  - `MOB_STABLE_CAP_LATE  EQU 1104` (96×4 + 24×30: 終盤 mob_w=4/stable_w=30)
- `OBS_SCORE_MAX EQU 192` 追加（RFCT002 の AMM_BETA_SKIP 閾値修正で使用予定）
- AIset pre-filter を GAME_PHASE に基づくフェーズ別 CAP 選択に更新
  - P1_CAP_MID / P1_CAP_LATE / P1_CAP_DONE ラベルを追加

### 根拠

- mob_diff+64 max ≈ 96（合法手上限約32手 + 64）
- stable_diff+8 max ≈ 24（AI安定石上限16石 – OPP=0）
- 旧 MOB_STABLE_CAP=1600 は ad-hoc 値（中盤以降の実測上限の近似）
- 新値は評価式の重みと実際の最大値から正確に算出

### 次ステップ

RFCT002: AMM_BETA_SKIP 閾値修正 + フェーズ別分岐追加

---

## RFCT002.ASM アセンブル成功 (2026-04-25)

P1_BSKIP 閾値修正（depth-2 専用 OBS_SCORE_MAX チェック追加）と Ply2Best_D2 の P2_ALPHA 初期値修正を実施。アセンブルエラーなし。

### 実施内容

**① Ply2Best_D2: P2_ALPHA 初期値を OBS_SCORE_MAX(192) に変更**

- 変更前: `LD A,0FFH` (255)
- 変更後: `LD A,OBS_SCORE_MAX` (192)
- 効果: 内側 AI ループの α-cutoff (`P2_INNER_BEST >= P2_ALPHA`) が有効化
  - P2_INNER_BEST = POS_WEIGHT + flips ≤ 128 + 64 = 192 = OBS_SCORE_MAX が上限
  - 旧値 255 では α-cutoff が絶対に発火しなかった
  - 新値 192 では AI が最大スコアの応手を見つけた時点でその OPP 手の内ループ終了

**② AIset pre-filter: P1_BSKIP に depth-2 専用 OBS_SCORE_MAX 閾値を追加**

- 変更前: H≠0 (P1_BETA ≥ 256) のみスキップ
- 変更後: depth-2 かつ P1_BETA ≥ OBS_SCORE_MAX(192) でもスキップ
  - depth-3 は P3_BEST = 255 - LF_BEST ∈ [63, 255] が 192 超え可能なため旧条件のまま
  - `LD A,(USE_DEPTH3); OR A; JR NZ,P1_BSTORE` で depth-2/3 を分岐

### 動作論理

depth-2 時の P1_BSKIP 正当性:
- max mm_score (OPP有手) = P1_POS_W + P2_ALPHA_max + MOB_STABLE_CAP = P1_POS_W + 192 + CAP
- P1_BETA ≥ 192 ⟺ AI_BEST_SCORE ≥ P1_POS_W + CAP + 192 = max mm_score → スキップ安全

発火例 (MID phase, MOB_STABLE_CAP_MID=1968):
- コーナー(P1_POS_W=128) が AI_BEST_SCORE=2288(最大値) の手を発見済みの場合:
  - 別コーナー(P1_POS_W=128): P1_BETA = 2288 - 128 - 1968 = 192 ≥ 192 → スキップ ✓
  - X マス(P1_POS_W=1): P1_BETA = 2288 - 1 - 1968 = 319 > 255 → スキップ ✓
  - C マス(P1_POS_W=3): P1_BETA = 2288 - 3 - 1968 = 317 > 255 → スキップ ✓

### 次ステップ

RFCT003: D3_THRESHOLD 調整・評価値表示追加

---

## RFCT002.ASM 実機テスト (2026-04-25)

- 着手の正確さ: 正常
- 処理時間: 残り25手付近で1回 4秒超え（depth-3 発動直後、探索量が最大になる局面）
- 強さ: 先手・後手各1局でユーザーが勝利（AI は弱い）

→ D3_THRESHOLD=25 では境界付近で時間超過リスクあり。20 に下げる方針へ。

---

## RFCT003.ASM アセンブル成功 (2026-04-25)

D3_THRESHOLD を 20 に変更し、評価値の PC 表示（SIOA 出力）を追加。アセンブルエラーなし。

### 実施内容

**① D3_THRESHOLD: 25 → 20**

- RFCT002 実機テストで残り25手付近に1回 4秒超えが発生
- 残り20手以下なら探索幅が減少し安定して制限時間内に収まると判断
- `D3_THRESHOLD EQU 25` → `EQU 20`

**② 評価値の PC（TeraTerm）表示**

- AIset の着手出力直後に `"Eval:XXXX\r\n"` を SIOA へ出力
- `AI_BEST_SCORE`（16bit, 0〜約2100）を PrintDec4 で10進表示
- `MSG_EVAL: DEFM "Eval:",0` を文字列テーブルに追加
- `PrintDec4` ルーチンを新規追加（leading zero 抑制、最低1桁出力）

TeraTerm での表示例:
```
AI moves to C4
Eval:1423
X:22 O:12
```

**③ Pico 側（gameDisplay.py）は今回変更なし**

- `"Eval:XXXX"` 行はパーサー未対応のため無視される
- 動作確認後に対応予定

### PrintDec4 アルゴリズム

HL を 1000→100→10 の順に繰り返し引き算し、商(桁)を出力する。
leading zero は B フラグ（0=抑制, FFH=出力済み）で管理。一の位は常に出力。

### 次ステップ

実機テストで評価値表示と処理時間を確認。
Pico 側（gameDisplay.py）への評価値表示対応。

---

## RFCT003.ASM 実機テスト・追加実装 (2026-04-25)

### 評価値表示確認

- TeraTerm: `Eval:XXXX` が毎ターン表示される（2手目で約 1000）
- Pico LCD: 5行目に `Eval:XXXX` が表示、人間の手でも消えないことを確認
- gameDisplay.py の `row_idx==0` 受信時に `eval_text` をクリアしていたバグを修正（盤面更新ごとに消える問題）

### 対局中断機能追加（PB5 / SW5）

PB5 (PIOB bit5) の H→L で対局を中断し、リトライ画面に戻る機能を追加。

**Z80 (RFCT003.ASM) 変更点:**

| 変更箇所 | 内容 |
|---|---|
| `SW_ABORT EQU 20H` | PB5 ビット定数追加 |
| `MSG_ABORT` | `"Game aborted.\r\n"` メッセージ追加 |
| `WaitSwPress` | `AND 1FH` → `AND 3FH`（PB5 を検出対象に） |
| `SWP_LOOP` | WaitSwPress 直後に `BIT 5,E; JP NZ,GAME_ABORTED` 追加 |
| `MAIN_LOOP` 先頭 | ターン間の PB5 チェック（デバウンス付き）追加 |
| `GAME_ABORTED:` | `LD SP,0FFF0H`（スタッククリア）→ MSG_ABORT → `JP GO_ASK` |

AI 計算中は割り込み不可（タイトループのため）。AI 手番が終わった後に検出される。

**Pico (gameDisplay.py) 変更点:**

- `"Game aborted."` 受信時: `move_text="ABORTED"`, `retry_mode=True`, `eval_text=""` → LCD リトライ画面へ

**動作確認:**

- PB5 押下で PC・Pico 両方にリトライメッセージが表示されることを確認

### 次ステップ

AI の弱さ改善（Python 側での評価関数チューニング → Z80 移植）または終盤完全読み (AIset_EG) のフリーズ原因調査。

---

## benchmark_vs.py 実行結果・AI強化方針決定 (2026-04-26)

### benchmark_vs.py 結果（n_pairs=10, 各20局）

| セット | 結果 |
|--------|------|
| V1/d2 vs V2/d2 | **V2/d2: 16勝/20 (80%)** |
| V1/d2 vs V1/d3 | V1/d3: 11勝 + Draw4 (55%) |
| V1/d2 vs V2/d3 | **V2/d3: 19勝/20 (95%)** |

### 考察

- AI 強化の主因は **深さよりも負値テーブル（V2）**
- depth-3 だけでは 55% 止まりだが V2/d2 で 80% → 負値が効く
- 現 Z80 は byte(0-255) 制約のため V2 の -40（Xマス）、-20（Cマス）を直接使えない
- → **符号付き POS_WEIGHT を Z80 に実装する**方針に決定

### GA 再最適化（depth-3, 負値あり）実行開始

`optimize_weights.py` を以下のように更新し、実行開始（2026-04-26）：

| 変更点 | 旧 | 新 |
|--------|----|----|
| DEPTH | 2 | **3** |
| N_GAMES | 10 | 5 |
| GENERATIONS | 50 | 30 |
| N_GAMES_FINAL | 50 | 20 |
| ベースライン | V1_PARAMS | **V2_PARAMS** |
| 探索範囲 | max(1, ...) | max(-60, ...) — **負値許容** |
| 初期集団 | V1 + random | **V2 + GA_D2 + random** |

所要時間目安: GA本体 ≈ 2.2時間、最終トーナメント ≈ 30分

---

## RFCT100.ASM 設計決定 (2026-04-26)

RFCT003.ASM の AI コアを**再構築**する新ファイル。
ファイル系譜的には RFCT003 からの分岐（RFCT00x シリーズとは別ライン）。

### 背景

- 現行の 4 段分割ループ（AIset / Ply2Best_D2 / D3 / Ply3Best / LeafEval）は
  byte 制約の積み上げで設計されており、符号付き POS_WEIGHT の導入が困難
- 「depth-1 から作り直す」方針で **再帰 negamax** に全面置き換え

### 変えない部分（共通インフラ）

ゲーム制御・I/O・盤面操作・合法手判定・プレイヤー入力・終盤完全読み（SearchFull 等）はすべて流用。

### 置き換える部分（AI コア）

| 旧 | 新 |
|----|-----|
| Ply2Best_D2 / D3 / Ply3Best / LeafEval | `NegaMax`（再帰）に統合 |
| LeafEval（POS_WEIGHT+flipsのみ） | `EvalLeaf`（64マス走査・符号付き pos_diff） |
| AIset（4段ループ） | `AIset`（NegaMax ラッパー） |
| POS_WEIGHT（正値のみ） | **符号付きバイト**（V2値を初期値、GA結果で更新） |

### スコア型

**符号付き 16-bit 統一**（Python negamax と同じ）

実用スコア範囲: pos_diff ≈ ±1300, mob×12 ≈ ±384, stable×50 ≈ ±400 → 合計 ±2100 程度

### 定数

```asm
NM_SCORE_MIN    EQU  0FF01H   ; -255 相当（初期 alpha 値）
; フェーズ閾値・D3_THRESHOLD は流用
```

### 変数

```asm
NM_TOTAL_DEPTH: DEFB 0    ; 総探索深さ (2 or 3)
NM_CALL_DEPTH:  DEFB 0    ; 現在再帰深さ (0=AIset直下)
NM_ALPHA_TBL:   DEFS 8    ; alpha[depth] 16bit × 4
NM_LOOP_IDX:    DEFS 4    ; POS_ORDERインデックス (depth 0..3)
NM_HAS_MOVE:    DEFS 4    ; 合法手フラグ (depth 0..3)
NM_ROOT_SCORE:  DEFW 0    ; AI視点最善スコア (符号付き16bit)
NM_ROOT_POS:    DEFB 0FFH ; 最善手オフセット (FFH=未発見)
EV_POS_DIFF:    DEFW 0    ; EvalLeaf pos_diff (符号付き16bit)
EV_SIDE:        DEFB 0    ; EvalLeaf 対象 side
```

削除: `P2_INNER_BEST, OBS_COUNT, P2_ALPHA, P1_BETA, P3_BEST, LF_ALPHA, LF_BEST, P1_IDX, P2_IDX, P3_IDX, LF_IDX, P1_POS_W, USE_DEPTH3, AI_BEST_SCORE, AI_BEST_ROW, AI_BEST_COL`

### 関数

| 関数名 | 役割 | 入力 | 出力 |
|--------|------|------|------|
| `AIset` | ルート探索・最善手着手 | — | BOARD更新 |
| `NegaMax` | 再帰 α-β 探索 | D=side | HL=符号付き16bitスコア |
| `EvalLeaf` | 葉ノード評価（64マス走査） | D=side | HL=符号付き16bitスコア |
| `NM_GetSaveBuf` | NM_CALL_DEPTH → バッファアドレス | — | HL=addr |

### 探索構造（疑似コード）

```
AIset:
  NM_ROOT_SCORE = NM_SCORE_MIN
  NM_TOTAL_DEPTH = 2 or 3
  for each pos in POS_ORDER:
    SaveBoard(BOARD_SAVE1) → ApplyMove(AiSide, pos)
    NM_CALL_DEPTH=0 / NM_ALPHA_TBL[0]=NM_SCORE_MIN
    score = NegaMax(D=HumSide)
    RestoreBoard(BOARD_SAVE1)
    if score > NM_ROOT_SCORE: update

NegaMax(D=side):
  d = NM_CALL_DEPTH
  if (NM_TOTAL_DEPTH - d) == 0: return EvalLeaf(D=side)
  save_buf = NM_GetSaveBuf()   ; BOARD_SAVE2/3/EG_SAVES[n]
  NM_HAS_MOVE[d]=0 / NM_ALPHA_TBL[d]=NM_SCORE_MIN
  for each pos in POS_ORDER:
    SaveBoard(save_buf) → ApplyMove(side, pos)
    NM_CALL_DEPTH=d+1 / NM_ALPHA_TBL[d+1]=NM_SCORE_MIN
    child = NegaMax(D=3-side)
    NM_CALL_DEPTH=d
    score = -child             ; negamax 反転
    RestoreBoard(save_buf)
    if score > NM_ALPHA_TBL[d]: NM_ALPHA_TBL[d]=score
    if d>0 and NM_ALPHA_TBL[d] >= -NM_ALPHA_TBL[d-1]: break (β-cutoff)
  if NM_HAS_MOVE[d]==0:
    if HasAnyLegalMove(3-side)==0: return terminal_score(side)
    return -NegaMax(D=3-side)  ; PASS (depth 消費しない)
  return NM_ALPHA_TBL[d]

EvalLeaf(D=side):
  pos_diff=0
  for sq in 0..63:
    sign_ext(POS_WEIGHT[sq]) を side/opp で加減算
  mob_diff  = CountMobility(side) - CountMobility(3-side)
  stable_diff = CountStable(side) - CountStable(3-side)
  return pos_diff + mob_diff×mob_w + stable_diff×stable_w  (フェーズ別重み)
```

### 設計上の決定事項

1. **PASS の depth 消費なし** — Python negamax と同じ。強制手なので depth を消費しない
2. **terminal_score** — `CountStones` で石差 × 大きな係数（200 程度）を返し、通常評価スコアと区別する
3. **α-β のルート alpha** — AIset ループが `NM_ROOT_SCORE` として機能。各 NegaMax 呼び出しに `-NM_ROOT_SCORE` を beta として渡す代わりに、AIset 内でスコア更新後に次手の alpha 値を NM_ALPHA_TBL[0] に書き込む

### 次のTODO

1. RFCT100.ASM 実装（depth-1 EvalLeaf → NegaMax depth-1 → depth-2 → depth-3 の順で確認）
2. GA 結果が出たら POS_WEIGHT を更新
3. 実機確認・処理時間計測

---

## RFCT100.ASM Step1/7: ファイル土台作成 (2026-04-26)

### 実施内容

| 変更 | 内容 |
|------|------|
| ヘッダー | RFCT100 説明・設計概要に全面更新 |
| POS_WEIGHT | 符号付き V2 値に変更（角=+120, Xマス=-40, Cマス=-20, near_x=-5, 辺=+20 等） |
| POS_ORDER | V2 重み降順に更新（120→20→15→10→5→3→1→-5→-20→-40） |
| 定数追加 | `NM_SCORE_MIN EQU 0FF01H` (-255, 初期 alpha 値) |
| 変数削除 | 旧AIワーク変数 16個削除（AI_BEST_SCORE/ROW/COL, P2_ALPHA, P1_BETA, P1_POS_W, P1/P2/P3/LF_IDX, P3_BEST, LF_ALPHA/BEST, USE_DEPTH3, OBS_COUNT, P2_INNER_BEST） |
| 変数追加 | NM_TOTAL_DEPTH, NM_CALL_DEPTH, NM_ALPHA_TBL(8B), NM_HAS_MOVE(4B), NM_ROOT_SCORE, NM_ROOT_POS, EV_POS_DIFF, EV_SIDE |
| AIコア削除 | Ply2Best_D2, Ply2Best_D3, Ply3Best, LeafEval, AIset (旧) を全削除 |
| AIset スタブ | `DEFM "RFCT100 AIset stub"` を出力して RET するだけの仮実装 |
| 復元 | CountMobility, CountEmpty, CountStable, EG_GetSaveAddr (削除ブロックに含まれていたため) |

### 変数定義（新）

```asm
NM_TOTAL_DEPTH: DEFB 0     ; 総探索深さ (2 or 3)
NM_CALL_DEPTH:  DEFB 0     ; 現在の再帰深さ (0=AIset直下)
NM_ALPHA_TBL:   DEFS 8     ; alpha[depth] 符号付き16bit x 4
NM_HAS_MOVE:    DEFS 4     ; 合法手発見フラグ (depth 0..3)
NM_ROOT_SCORE:  DEFW 0     ; AIset: ルートベストスコア (符号付き16bit)
NM_ROOT_POS:    DEFB 0FFH  ; AIset: 最善手 offset (FFH=未発見)
EV_POS_DIFF:    DEFW 0     ; EvalLeaf: pos_diff 作業用
EV_SIDE:        DEFB 0     ; EvalLeaf: 評価対象 side
```

### 次のステップ

Step 2/7: NM_GetSaveBuf + EvalLeaf (pos_diff のみ) → アセンブル確認

---

## RFCT100.ASM Step2/7: NM_GetSaveBuf + EvalLeaf (2026-04-26)

### 実施内容

#### NM_GetSaveBuf
AIset は BOARD_SAVE1 を使うため depth=0 から BOARD_SAVE2 を割り当て。

| NM_CALL_DEPTH | バッファ |
|---|---|
| 0 | BOARD_SAVE2 |
| 1 | BOARD_SAVE3 |
| N≥2 | BOARD_EG_SAVES + (N-2)×64 |

#### EvalLeaf (pos_diff のみ)
- IX=BOARD / IY=POS_WEIGHT ポインタを同期インクリメントして64マス走査
- `LD E,(IY+0)` + BIT7 判定で符号拡張 → DE (16bit signed)
- 自石: `ADD HL,DE` / 相手石: `AND A; SBC HL,DE`
- mob_diff / stable_diff は Step 7/7 で追加

### 次のステップ

Step 3/7: AIset スタブを depth-1 固定の実動版に置き換え → 実機確認

---

## RFCT100.ASM Step3/7: AIset depth-1 実動版 (2026-04-26)

### 実施内容

| 変更 | 内容 |
|------|------|
| 変数追加 | `AS_IDX: DEFB 0`（POS_ORDER ループインデックス）、`AS_OFFSET: DEFB 0`（着手 offset 一時保存） |
| AIset 置き換え | スタブを depth-1 固定の実動版に全面置き換え |

### AIset depth-1 動作フロー

```
CountEmpty → EMPTY_CACHE 保存
NM_ROOT_SCORE = NM_SCORE_MIN (-255) / NM_ROOT_POS = FFH
SaveBoard(BOARD_SAVE1)

for AS_IDX in 0..63:
  offset = POS_ORDER[AS_IDX]
  CountAllFlips(AiSide, row, col) → A
  if A == 0: next   ; 非合法手
  RestoreBoard(BOARD_SAVE1)
  ApplyMove(AiSide, row, col)
  EvalLeaf(D=AiSide) → HL (符号付き16bit)
  if HL > NM_ROOT_SCORE:
    NM_ROOT_SCORE = HL / NM_ROOT_POS = offset
  RestoreBoard(BOARD_SAVE1)

RestoreBoard(BOARD_SAVE1) → ApplyMove(NM_ROOT_POS)
"AI moves to XY\r\n" 出力
"Eval:YYYY\r\n" 出力
```

### 符号付き 16bit 比較の実装

```asm
; HL = score, DE = best_score (A経由ロード)
PUSH HL
AND  A
SBC  HL,DE        ; HL = score - best (flags 使用)
POP  HL           ; HL = score 復元 (POP は flags 変更しない)
JP   M,skip       ; score < best → skip
JR   Z,skip       ; equal → skip
; score > best → update
```

### DE ロードの制約対応

Z80 は `LD DE,(nn)` が非対応のため A 経由で 2 バイトロード:
```asm
LD   A,(NM_ROOT_SCORE)
LD   E,A
LD   A,(NM_ROOT_SCORE+1)
LD   D,A
```

### 次のステップ

Step 4/7: NegaMax 最小実装（depth=1 で EvalLeaf 呼び出し）→ AIset から NegaMax を呼ぶ形に変更

---

## RFCT100.ASM Step4/7: NegaMax 最小実装 (2026-04-26)

### 実施内容

| 変更 | 内容 |
|------|------|
| AIset 初期化 | `NM_TOTAL_DEPTH=0, NM_CALL_DEPTH=0` 追加（depth-1: 残り深さ=0） |
| AIset ループ | `CALL EvalLeaf(AiSide)` → `CALL NegaMax(HumSide)` + 符号反転 |
| NegaMax 追加 | EvalLeaf 直後に新規追加。leaf 判定 + NM_RECURSE stub |

### NegaMax 動作 (Step 4 時点)

```
NegaMax(D=side):
  if NM_TOTAL_DEPTH == NM_CALL_DEPTH:  ; remaining == 0
    return EvalLeaf(D=side)
  else:
    [NM_RECURSE - Step 5 で実装、現在は EvalLeaf の仮実装]
```

### 符号反転（negamax の核心）

```asm
CALL NegaMax        ; HL = score (HumSide 視点)
EX   DE,HL
LD   HL,0
AND  A
SBC  HL,DE          ; HL = 0 - DE = -score (AiSide 視点)
```

### 動作確認

NM_TOTAL_DEPTH=0, NM_CALL_DEPTH=0 のため常に leaf → EvalLeaf。
Step 3 と動作等価（アセンブル確認のみ）。

### 次のステップ

Step 5/7: NM_RECURSE を本実装（POS_ORDER ループ + 再帰 + α 更新）

---

## RFCT100.ASM Step5/7: NM_RECURSE 本実装 (2026-04-26)

### 実施内容

| 変更 | 内容 |
|------|------|
| NegaMax コメント | Step 4 → Step 5 更新 |
| NM_RECURSE | POS_ORDER ループ + 再帰 + α更新の完全実装 |

### NM_RECURSE 動作フロー

```
NM_RECURSE(D=side):
  NM_SIDE_TBL[depth] = side
  NM_IDX_TBL[depth] = 0
  NM_HAS_MOVE[depth] = 0
  NM_ALPHA_TBL[depth] = NM_SCORE_MIN (FF01H)
  SaveBoard(NM_GetSaveBuf(depth))

  for idx in 0..63:
    offset = POS_ORDER[idx]
    D = NM_SIDE_TBL[depth]   ← B,C設定前に先ロード
    B,C = row,col(offset)
    CountAllFlips(D,B,C) → A
    if A == 0: continue

    NM_HAS_MOVE[depth] = 1
    RestoreBoard
    recompute offset from NM_IDX_TBL[depth]
    ApplyMove(side, row, col)
    D = opponent(side)
    NM_CALL_DEPTH++
    CALL NegaMax(D)           → HL = opponent score
    NM_CALL_DEPTH--
    HL = -HL                  ← negamax 符号反転
    if HL > NM_ALPHA_TBL[depth]: update (IX=&alpha, LD (IX+0),L /(IX+1),H)
    RestoreBoard

  if NM_HAS_MOVE[depth] == 0: return EvalLeaf(side)
  return NM_ALPHA_TBL[depth]
```

### 設計ポイント

- **D ロード順序**: CountAllFlips 前に `LD E,A; LD D,0; ADD HL,DE` で NM_SIDE_TBL[depth] をロード (B,C を消費しない)
- **offset 再取得**: CountAllFlips 破壊後は NM_IDX_TBL[depth] から POS_ORDER を再引き
- **alpha 更新**: `PUSH HL; POP IX` で &alpha[depth] を IX に退避、`LD (IX+0),L/(IX+1),H` で書き込み
- **NM_CALL_DEPTH**: 再帰呼び出し前後で ++ / -- して深さを管理
- **合法手なし**: NM_HAS_MOVE == 0 → EvalLeaf (PASS/terminal 簡易処理)

### 動作確認

NM_TOTAL_DEPTH=0 のまま (Step 6 で変更) → NegaMax は常に leaf → Step 3/4 と等価。
アセンブル確認のみ。

### 次のステップ

Step 6/7: AIset で NM_TOTAL_DEPTH=1 (depth-2) / 2 (depth-3) を設定

---

## RFCT100.ASM Step6/7: AIset depth-2/3 切り替え + 重みテーブル D2/D3 切替 (2026-04-27)

### 実施内容

| 変更 | 内容 |
|------|------|
| AIset コメント | Step 3 → Step 6 更新 |
| NM_TOTAL_DEPTH 設定 | 固定0 → EMPTY_CACHE と D3_THRESHOLD(=20) で分岐 |
| NM_SCORE_MIN | -512 (0xFE00) → -2048 (0xF800)。GA_D2signed の最大絶対値±1168 に対応。比較オーバーフロー確認: 1168-(-2048)=3216 < 32767 ✓ |
| POS_WEIGHT_D3 | 旧 POS_WEIGHT ラベルをリネーム。データ変更なし |
| POS_WEIGHT_D2 | GA_D2signed 優勝テーブル追加 (depth-2 signed tournament 1位, 101/560勝) |
| POS_ORDER_D3 | 旧 POS_ORDER ラベルをリネーム |
| POS_ORDER_D2 | GA_D2signed 重み降順 offset テーブル追加 |
| EQU エイリアス | `POS_WEIGHT EQU POS_WEIGHT_D2` / `POS_ORDER EQU POS_ORDER_D2`（1行変更で切替） |
| NM_ALPHA_TBL init | hi バイト 0xFE → 0xF8 (-2048 に合わせて更新) |

### depth 切り替えロジック

```asm
        LD   A,(EMPTY_CACHE)
        CP   D3_THRESHOLD       ; carry if empty < 20
        JR   NC,AS_DEPTH2
        LD   A,2                ; 空き < 20  → depth-3 (TOTAL_DEPTH=2)
        JR   AS_SET_DEPTH
AS_DEPTH2:
        LD   A,1                ; 空き >= 20 → depth-2 (TOTAL_DEPTH=1)
AS_SET_DEPTH:
        LD   (NM_TOTAL_DEPTH),A
```

### GA_D2signed テーブル

```
POS_WEIGHT_D2:
;       A    B    C    D    E    F    G    H
DEFB  114,  -5, -16,  -7,  -7, -16,  -5, 114  ; 1
DEFB   -5, -54, -16,   7,   7, -16, -54,  -5  ; 2
DEFB  -16, -16,   6,   2,   2,   6, -16, -16  ; 3
DEFB   -7,   7,   2, -12, -12,   2,   7,  -7  ; 4-5
DEFB  -16, -16,   6,   2,   2,   6, -16, -16  ; 6
DEFB   -5, -54, -16,   7,   7, -16, -54,  -5  ; 7
DEFB  114,  -5, -16,  -7,  -7, -16,  -5, 114  ; 8
```

tournament 結果: D2signed 1位 (101/560勝) > D3 (55/560勝)。コーナー重視・隅渡し防止が改善。

### 動作確認

アセンブル確認後、実機で depth-2/3 動作および D2signed 重みの効果を確認予定。

### 次のステップ

Step 7/7: EvalLeaf に mob/stable 項追加

---

## RFCT100.ASM Step7/7: EvalLeaf mob/stable 追加 (2026-04-26)

### 実施内容

EvalLeaf を pos_diff のみから 3 項評価に拡張。

### 評価式

```
score = pos_diff
      + (mob_ai - mob_opp) * mob_w
      + (stable_ai - stable_opp) * stable_w

フェーズ (EMPTY_CACHE で判定):
  EARLY (>=44): mob_w=12, stable_w=30
  MID   (>=12): mob_w=8,  stable_w=50
  LATE  (< 12): mob_w=4,  stable_w=30
```

### 実装ポイント

| 処理 | 実装 |
|------|------|
| mob_ai 保存 | `PUSH AF; ... POP DE` でD=mob_ai取得 |
| mob_opp 後の mob_diff | `LD A,D; SUB C; BIT7 → sign-extend → HL` |
| *12 | `ADD HL,HL` x2 + PUSH + `ADD HL,HL` + POP DE + ADD |
| *8  | `ADD HL,HL` x3 |
| *4  | `ADD HL,HL` x2 |
| *30 | `ADD HL,HL` → PUSH → x4 → POP DE → `SBC HL,DE` |
| *50 | PUSH *2 + PUSH *16 + *32 + POP*16 + ADD + POP*2 + ADD |
| EV_POS_DIFF 加算 | `EX DE,HL; LD HL,(EV_POS_DIFF); ADD HL,DE` |
| stable 取得 | mob と同パターン (`PUSH AF; ... POP DE`) |

### アセンブル

アセンブルエラーなし（2026-04-26 確認）。実機テスト待ち。

### RFCT100 実装完了 (Step 1〜7/7)

全 Step の実装が完了。主な動作確認項目:
- depth-2/3 切り替え (D3_THRESHOLD=20)
- negamax スコア符号 (AI有利 → 正値)
- 評価値表示 `Eval:YYYY`
- 実機での処理時間計測

---

## RFCT100.ASM POS_WEIGHT GA_D3更新 (2026-04-26)

### 実施内容

GA最適化（depth-3, 30世代, 約208分）の優勝テーブルを RFCT100.ASM に反映。

| 変更箇所 | 内容 |
|----------|------|
| `POS_WEIGHT` | V2ベースライン → GA_D3優勝値 |
| `POS_ORDER` | V2重み順 → GA_D3重み降順 |
| `OBS_SCORE_MAX` | 192 → 130（max 66+64） |

### GA_D3 最終ランキング

| 順位 | 勝数/300 | パラメータ |
|------|---------|-----------|
| **1位** | 68 | `[66, -32, -1, 44, -45, 22, 1, 10, 23, -29]` ← 採用 |
| 2位 | 58 | V2ベースライン |
| 3位 | 55 | 世代10個体 |

### 新テーブル特徴

- corner=66（V2=120より低め）、edge_ctr=+44（大幅上昇）
- x_sq=-45（強く禁止）、center=-29（中央を強く嫌う）
- near_x=+22（V2=-5から逆転、正値）

---

## GA_D2 signed 最適化計画 (2026-04-26)

### 背景

GA_D3 優勝値（depth-3 最適化）を RFCT100 の depth-2 フェーズにも使用しているが、
評価関数は探索深さに依存するため、depth-2 専用の signed 重みが存在する可能性がある。

**深さと評価関数の関係:**
- depth-3 は 3 手先まで読めるため、静的評価が荒くても補正できる
- depth-2 は 2 手分の情報を 1 つのスコアで表現する必要がある
- 実際に GA_D2（正値のみ）は corner=128 と高く、GA_D3 は corner=66 と低い
  → 深さが増すと「角は自然に取れる」ので評価で高くしなくてよい

### 実施内容

`optimize_weights_d2signed.py` を新規作成。

| 項目 | GA_D3（前回） | GA_D2signed（今回） |
|------|--------------|---------------------|
| `DEPTH` | 3 | **2** |
| `RANDOM_SEED` | 42 | 123 |
| 初期集団 | V2 + GA_D2 + randoms | V2 + GA_D2 + **GA_D3** + randoms |
| 殿堂初期値 | V2 のみ | V2 + GA_D2 + GA_D3 |
| 比較表 | V2/GA_D2/V1 | V2/GA_D2/**GA_D3**/V1 |

### 期待所要時間

depth-2 は depth-3 より高速なため 30 世代 + トーナメントで **70〜100 分**見込み。
（GA_D3 実績: 208 分）

### 実行コマンド

```
cd F:\ClaudeCode\Z80-Othello\python
python optimize_weights_d2signed.py > ga_d2signed_result.txt 2>&1
```

### 結果の活用方針

- GA_D2signed 優勝 > GA_D3 (depth-2 対戦): depth-2 フェーズ用に差し替え検討
- GA_D2signed 優勝 ≦ GA_D3 (depth-2 対戦): GA_D3 のまま維持
- RFCT100 は depth-2/3 で同一テーブルを使用。将来的にフェーズ別テーブルも選択肢。

---

## GA_D2signed 最適化結果 (2026-04-27)

### 結果概要

30世代 + 最終トーナメント（8個体 × 28ペア × 20ゲーム = 560ゲーム）完了。所要時間 約38.4分。

### 最終ランキング

| 順位 | 勝数/560 | パラメータ |
|------|---------|-----------|
| **1位** | **101** | `[114, -5, -16, -7, -54, -16, 7, 6, 2, -12]` ← **優勝** |
| 2位 | 98 | `[128, -36, -16, 2, -60, -16, -3, 11, 2, -1]` |
| 3位 | 81 | `[127, -16, -16, 10, -46, -5, 7, 6, 7, 3]` |
| 5位 | 55 | V2 |
| 6位 | 55 | GA_D3（現RFCT100使用中） |
| 8位 | 37 | GA_D2（旧版） |

### 優勝テーブル（Z80 DEFB 形式）

```asm
  ;     A   B   C   D   E   F   G   H
  DEFB  114,  -5, -16,  -7,  -7, -16,  -5, 114  ; 1
  DEFB   -5, -54, -16,   7,   7, -16, -54,  -5  ; 2
  DEFB  -16, -16,   6,   2,   2,   6, -16, -16  ; 3
  DEFB   -7,   7,   2, -12, -12,   2,   7,  -7  ; 4
  DEFB   -7,   7,   2, -12, -12,   2,   7,  -7  ; 5
  DEFB  -16, -16,   6,   2,   2,   6, -16, -16  ; 6
  DEFB   -5, -54, -16,   7,   7, -16, -54,  -5  ; 7
  DEFB  114,  -5, -16,  -7,  -7, -16,  -5, 114  ; 8
```

### 各マス種別の値比較

| マス種別 | GA_D2signed | V2 | GA_D2 | GA_D3 |
|----------|------------|-----|-------|-------|
| corner   | 114 | 120 | 128 | 66 |
| c_sq     | -5  | -20 | 3   | -32 |
| edge_near| -16 | 20  | 17  | -1 |
| edge_ctr | -7  | 10  | 30  | 44 |
| x_sq     | -54 | -40 | 1   | -45 |
| near_x   | -16 | -5  | 36  | 22 |
| inner_edge| 7  | 1   | 15  | 1 |
| inner    | 6   | 15  | 18  | 10 |
| inner2   | 2   | 5   | 29  | 23 |
| center   | -12 | 3   | 1   | -29 |

### 活用方針

GA_D2signed 優勝値は depth-2 専用最適化で GA_D3 より大幅に優秀（101勝 vs 55勝）。
RFCT100 の POS_WEIGHT への反映は実機確認後に検討。

---

## RFCT100.ASM 段階的デバッグ (2026-04-27)

### Step3 実機確認 ✓

`git checkout 474e676 -- asm/RFCT100.ASM` で Step3（depth-1 AIset 実動版）に戻し、
実機確認 → 正常動作確認。

### Step4 復元・不具合発見

`git checkout 2fb9688 -- asm/RFCT100.ASM` で Step4（NegaMax 最小実装）に進めて実機確認。

**不具合症状：**
- AI の手が PC 画面に表示されない（Pico 側には人間の手のエコーが表示されていた）
- AI が H2 などの明らかな合法手を打たない
- 盤面スコア（X:41 O:19 等）が AI ターン前後で変化しない

**原因：`NM_SCORE_MIN = 0FF01H (-255)` が不十分**

V2 重みには負値（角隣=-20、Xマス=-40 等）が含まれるため、AI が劣勢な局面では
合法手を打った後の EvalLeaf スコアが -255 を下回りうる。

例（X:41 O:19 の局面）：
- H2 に打った場合のスコア: -352 < -255 → 「ベスト更新なし」扱いでスキップ
- G7 に打った場合のスコア: -292 < -255 → 同様にスキップ

全合法手がスキップされると `NM_ROOT_POS = 0FFH` のまま → `AS_END` で `RET Z` →
AIset が何も打たずに戻り、DoTurn 側もパス処理せずターンが移る。

**修正：**

```asm
; 変更前
NM_SCORE_MIN    EQU  0FF01H ; -255

; 変更後
NM_SCORE_MIN    EQU  08001H ; -32767 (-INF 相当)
```

V2 重みの全マス合計は約 +480 なので、理論的な最低スコアは約 -480。
-32767 に設定することでどんな劣勢局面でも正しく合法手を評価できる。

**副次的発見：PrintDec4 は符号なし専用**

`PrintDec4` は 0〜9999 のみ対応。負値の `NM_ROOT_SCORE` を渡すと文字化けする。
AI が劣勢局面では Eval 表示が崩れる。→ 符号付き対応は後回し。

### NM_SCORE_MIN 再修正 (0x8001 → 0xFE00)

0x8001 (-32767) は正値スコアとの比較でオーバーフローが発生することが判明。

```
SBC HL,DE  ; HL = score - best
JP M,...   ; 符号ビットで判定
```

`score - NM_SCORE_MIN` が 32767 を超えると符号ビットが誤って立ち、正値スコアもスキップされる。

例: score=16, best=-32767 → 16-(-32767)=32783=0x800F → 符号ビット=1 → 誤スキップ

**正しい NM_SCORE_MIN の範囲：**
- V2 全重み合計 = ±480 → min score ≈ -480
- NM_SCORE_MIN < -480（全合法手が必ず初期値を上回る）
- NM_SCORE_MIN > -32287（比較オーバーフロー防止: score_max - NM_SCORE_MIN ≤ 32767）

→ `0xFE00H = -512` に再設定。

### PrintSigned 追加（負評価値の表示対応）

`PrintDec4` は符号なし (0〜9999) 専用だったため、負の `NM_ROOT_SCORE` を渡すと文字化け。

`PrintSigned` を新規追加：
1. 符号ビット確認 (`BIT 7,H`)
2. 負なら `'-'` 出力 → 2の補数で絶対値化 (`SBC HL,DE` with HL=0)
3. `PrintDec4` を呼び出し

Eval 出力を `CALL PrintDec4` → `CALL PrintSigned` に差し替え。

### 次のステップ

Step4（NM_SCORE_MIN = -512, PrintSigned 対応済み）をアセンブル → 実機確認。
正常動作確認後に Step5（NM_RECURSE 本実装）へ進む。

---

## RFCT100.ASM Step7/7: EvalLeaf mob/stable 追加 (2026-04-27)

### 背景

実機確認で pos_diff のみ（Step2）の EvalLeaf では評価が正しく機能しないことが判明。
- コーナーを誘い取りされる / 辺を取った直後に隣接する悪手を打つなど典型的な劣悪手が頻発
- GA_D2signed テーブルはモビリティ・安定石を含む Python 評価関数で最適化されており、
  pos_diff 単独で動かしても重みが意図通りに機能しない

### 実装内容

EvalLeaf を pos_diff のみ → 3項評価に拡張。

```
score = pos_diff
      + (mob_ai - mob_opp) × mob_w
      + (stable_ai - stable_opp) × stable_w
```

| フェーズ (EMPTY_CACHE) | mob_w | stable_w |
|----------------------|-------|----------|
| EARLY (>= 44)        | 12    | 30       |
| MID   (>= 12)        | 8     | 50       |
| LATE  (<  12)        | 4     | 30       |

### 実装ポイント

- mob_ai/stable_ai 保存: `PUSH AF` → 2回目の CountMobility/CountStable 後に `POP DE` で D=mob_ai
- ×12 = ×8 + ×4 (PUSH/POP を使って 2段シフトを合算)
- ×30 = ×32 - ×2 (SBC HL,DE)
- ×50 = ×32 + ×16 + ×2 (PUSH ×2/PUSH ×16/×32/POP×16+ADD/POP×2+ADD)
- GAME_PHASE 変数は未設定のため EMPTY_CACHE を直接参照して判定
- PUSH/POP バランス: mob×12・stable×50 いずれも全パスでスタック平衡

### 次のステップ

アセンブル → 実機確認 (depth-2/3 動作・処理時間・評価値の妥当性)

---

## RFCT100.ASM 実機確認 + NM_SCORE_MIN バグ修正 (2026-04-28)

### 実機確認結果

- 処理時間: 最大 **約8秒**（depth-3 で α-β なしのため遅い）
- depth-2 評価: **おかしく見える**（実際より高い正値が続く）
- depth-3 移行時: **評価が急にマイナスへ**（ユーザーの盤面感覚とは合致）

### d2 評価のおかしさの原因分析

**コードロジックのバグはなし**。原因は 2 つ。

#### 原因1: NM_SCORE_MIN 不足（バグ）

Step7 で EvalLeaf に mob/stable 項を追加した際、スコアレンジが拡大したが NM_SCORE_MIN を更新していなかった。

```
max |score| = pos_diff(±1168) + mob×8(±240) + stable×50(±1200) = ±2608
NM_SCORE_MIN = -2048 (旧値)  ← -2608 < -2048 のスコアが発生しうる
```

**問題**: AIset の NM_ROOT_SCORE 初期値が -2048 のため、スコアが -2049 以下になった合法手はすべてスキップされる。全合法手が -2048 以下の極端な劣勢局面では AI が一手も指せず「合法手なし」扱いでパスしてしまう。

**修正**: NM_SCORE_MIN を -4096 (0xF000H) に変更。
- 変更ファイル: `RFCT100.ASM` 2箇所
  - `NM_SCORE_MIN EQU 0F800H` → `EQU 0F000H`
  - NM_ALPHA_TBL 初期化 hi バイト `0F8H` → `0F0H`
- 比較演算のオーバーフロー確認: max(score - NM_SCORE_MIN) = 2608 - (-4096) = 6704 < 32767 ✓

#### 原因2: ホライゾン効果（仕様）

POS_WEIGHT_D2 はコーナー=+114 以外の大半のマスが小さい値（±2〜±16）。
コーナーなし局面では pos_diff ≈ 0 となり、mob/stable 項（mob×8 + stable×50）が評価を支配する。

```
例: mob_diff=+5, stable_diff=+2 → Eval = 0 + 40 + 100 = +140
  （Human が次手でコーナーを取れる局面でも d2 では見えない）
```

depth-2 では 2手先しか読めないため、3手目の脅威（Human がコーナーを取れる手順）が見えず、過剰に楽観的な評価になる。depth-3 切り替え時の急落はこの「深読みによる正しい評価」が表れたもので、バグではない。

### 次のステップ

- **アセンブル → 実機確認** (NM_SCORE_MIN 修正後)
- **TODO #24: α-β 枝刈り追加** — 8秒問題の解消（NM_RECURSE に β カットオフ実装）

---

## RFCT100.ASM EvalLeaf 評価バランス修正 (2026-04-28)

### 問題

EvalLeaf の mob/stable ウェイトが大きすぎ、pos_diff（位置重み）が支配されていた。

| 項目 | 旧ウェイト | 典型寄与 | 問題 |
|------|-----------|---------|------|
| pos_diff | ×1 | ±100〜250 | 基準 |
| mob_diff (MID) | ×8 | ±40 | 小 |
| stable_diff (MID) | ×50 | ±200 | pos_diff を超える |

### 修正内容

EvalLeaf の mob_w / stable_w を再設計。pos_diff が全スコアの 60〜70% を占める比率を目標に設定。

| フェーズ | mob_w (旧) | mob_w (新) | stable_w (旧) | stable_w (新) |
|---------|-----------|-----------|--------------|--------------|
| EARLY (>=44) | ×12 | **×3** | ×30 | **×8** |
| MID (12-44)  | ×8  | **×3** | ×50 | **×12** |
| LATE (<12)   | EL_LATE (stone_diff×100+stable×30) — 変更なし |

### 実装変更

- **EL_MOBPOS**: フェーズ分岐を削除し EARLY/MID 共通 ×3（`DE=×1コピー, ADD HL,HL, ADD HL,DE`）に簡略化
- **EL_STBPOS**: `EL_STB8`（EARLY:×8=3シフト）/ MID:×12=×8+×4 に変更
- 不要になったデッドコード（EL_MOB4/EL_MOB12/EL_STB30 分岐）を削除

### overflow 確認

- max|score| (EARLY/MID): pos_diff ±1168 + mob×3 ±96 + stable×12 ±144 = **±1408**
- NM_SCORE_MIN = -8192: 1408+8192=9600 < 32767 ✓（LATE の 6880 が支配値のまま）

### アセンブル

エラーなし。実機確認待ち。

---

## RFCT100.ASM EvalLeaf mob/stable ウェイト 1/2 に再調整 (2026-04-28)

### 問題

実機確認で depth-2 フェーズにて隅を相手に渡す手が頻発。depth-3 評価値は適正。
原因: depth-2 ホライゾン効果 + mob/stable がまだ pos_diff に対して相対的に大きい。

### 変更内容

前回（mob×3/stable×8-12）をさらに 1/2 に削減。

| フェーズ | mob_w (変更前) | mob_w (変更後) | stable_w (変更前) | stable_w (変更後) |
|---------|--------------|--------------|-----------------|-----------------|
| EARLY   | ×3           | **×1**       | ×8              | **×4**          |
| MID     | ×3           | **×1**       | ×12             | **×6**          |
| LATE    | EL_LATE (変更なし) |

mob_w=1 は乗算なし（mob_diff をそのまま加算）。EL_MOBPOS の計算コードを削除。

### overflow 確認

- max|score|: pos_diff ±1168 + mob×1 ±32 + stable×6 ±96 = **±1296**
- NM_SCORE_MIN = -8192: 1296+8192=9488 < 32767 ✓

---

## RFCT100.ASM EvalLeaf mob_w 1→2 に変更 (2026-04-28)

mob_w を 1（乗算なし）から 2（×2）に変更。stable_w は据え置き。

| フェーズ | mob_w | stable_w |
|---------|-------|---------|
| EARLY   | **×2** | ×4 |
| MID     | **×2** | ×6 |

---

## optimize_weights_rfct100.py 作成 (2026-04-28)

現在の RFCT100 評価関数（mob×2, stable×4/6）に完全一致する GA スクリプトを新規作成。

### 評価関数の差し替え

`oth.eval_board` をモンキーパッチで差し替え:
```
EARLY (empty>=44): pos_diff + mob_diff*2 + stable_diff*4
MID   (empty>=12): pos_diff + mob_diff*2 + stable_diff*6
LATE  (empty<12 ): stone_diff*100 + stable_diff*30  (旧来と同一)
```

### 設定

| 項目 | 値 |
|------|-----|
| DEPTH | 2 |
| GENERATIONS | 30 |
| POP_SIZE | 20 |
| N_GAMES / N_GAMES_FINAL | 5 / 20 |
| 初期集団 | GA_D2S(現RFCT100) + GA_D3 + V2 + ランダム |
| ベースライン | GA_D2S_PARAMS (現RFCT100使用中) |

### 実行コマンド

```
cd python
python optimize_weights_rfct100.py > ga_rfct100_result.txt 2>&1
```

---

## GA_RFCT100 最適化結果・Z80テーブル反映 (2026-04-29)

### 最終ランキング（精密トーナメント 20ゲーム/ペア、12個体、1320ゲーム）

| 順位 | 勝数/1320 | 備考 |
|------|---------|------|
| **1位** | **153勝** | `[157, -12, 2, 5, -49, -16, -4, -19, -15, -24]` ← 採用 |
| 2位 | 130勝 | `[159, -9, -10, 19, -60, -26, -6, -14, -12, -24]` |
| 3位 | 118勝 | GA_D2S（旧RFCT100使用） |
| 12位 | 46勝 | GA_D3（depth-3評価は depth-2 フェーズに不適） |

### 優勝テーブル特徴

| マス種別 | 優勝 | 旧GA_D2S | 変化 |
|----------|------|---------|------|
| corner | 157 | 114 | **+43** ↑ |
| inner_edge | -4 | 7 | **-11** ↓ 逆転 |
| inner | -19 | 6 | **-25** ↓ |
| inner2 | -15 | 2 | **-17** ↓ |
| center | -24 | -12 | **-12** ↓ |
| edge_near | 2 | -16 | +18 |
| near_x | -16 | -16 | 0 |

コーナー大幅上昇・内陸マス全面負値化が主な変化。所要時間 約35.7分 + トーナメント 約15.9分。

### Z80 反映済み

`RFCT100.ASM`: `POS_WEIGHT_D2` / `POS_ORDER_D2` を優勝テーブルに更新（2026-04-29）。
