# RVS8 オセロ AI 開発ログ

対象ハード: Super AKI-80 (Z80)  
シリアル: SIOA DAT=18h CTL=19h  
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

## 次回やること

1. `RVS8_MM1_MOB.ASM` に PIO D7 計測を組み込み、AI 1ターンの処理時間を実測
2. Pico 側で SIOA データストリームをパースして LCD に盤面を描画
3. スイッチ入力を Z80 PIO 経由に移管

---

## 候補機能 (未着手)

| 機能 | 概要 | 備考 |
|---|---|---|
| 2手先読み | depth-2 minimax | 計算量 ≈ depth-1の64倍 → α-β必須 |
| α-β 枝刈り | 16bit α/β 値をスタック管理 | depth-2 以上に不可欠 |
| 安定石評価 | 角から連続する石を加点 | 算出コスト高 |
| 終盤完全読み | 残り≤12手で完全 minimax | 終盤は合法手が絞られ高速 |
| 盤面重み合計差 | Σweight(AI石) - Σweight(相手石) | 既存の16bit演算で対応可 |
