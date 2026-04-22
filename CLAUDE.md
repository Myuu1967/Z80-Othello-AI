# Z80 オセロ AI プロジェクト (RVS8)

## 実コードの場所
`F:\ClaudeCode\Z80-Othello\asm\` 以下を絶対パスで参照・編集する
（旧パス `F:\oke\Z80\ASM\オセロ\` は参照しない）

**現在の作業対象: `F:\ClaudeCode\Z80-Othello\asm\MM2_AB_D3.ASM`（実機確認済み・大会用調整中）**
ベースファイル: `F:\ClaudeCode\Z80-Othello\asm\MM2_AB_EV.ASM`

## 開発フロー（Python版を正とする）

AIロジックの変更は必ず **Python → 検証 → Z80移植** の順で行う。
Z80アセンブラで直接デバッグするより Python で先に確認する方がサイクルが速い。

```
1. python/othello_mm3_ab.py でロジックを変更・検証（A/Bテスト等）
2. 動作確認できたら asm/MM2_AB_EG.ASM に移植
3. アセンブル → 実機確認
```

### Python ↔ Z80 対応表

| Python (mm3_ab.py) | Z80 (MM2_AB_EG.ASM) | 備考 |
|---|---|---|
| `ai_choose_move()` | `AIset` / `AIset_EG` | 通常/終盤で切り替え |
| `negamax()` | `SearchFull` | 終盤完全読み |
| `eval_board()` | mm_score計算（AIset内） | 序盤/中盤/終盤切り替えは未移植 |
| `get_legal_moves_ordered()` | `CountAllFlips` ループ | Z80はPOS_WEIGHT順ソートなし |
| `apply_move()` | `ApplyMove` | Z80はB,C破壊に注意 |
| `count_flips()` | `CountAllFlips` | — |
| `count_mobility()` | `CountMobility` | Z80はAF破壊に注意 |
| `count_stable_stones()` | （未実装） | Phase2評価改善、Z80移植待ち |
| `POS_WEIGHT_V1` | `POS_WEIGHT` | Z80は正値のみ（byte制約） |
| `POS_WEIGHT_V2` | 移植不可（負値あり） | Python専用 |
| `EARLY_GAME` / `MID_GAME` 分岐 | （未実装） | Phase2評価改善、Z80移植待ち |

### Z80移植時の制約

- 評価値は **符号なし8bit (0-255)** が基本（depth-2通常探索）
- 負値・符号付き演算は終盤スコア（`SearchFull`）のみ使用可
- POS_WEIGHT_V2（負値テーブル）はZ80に移植できない → V1のまま維持
- `IXL`/`IXH` 非対応 → D/E レジスタで代替
- `LD r,(nn)` は A のみ有効

## ハードウェア仕様

| 項目 | 値 |
|---|---|
| CPU | Z80 (Super AKI-80) |
| クロック | 10MHz (1T = 0.1μs) |
| シリアル | SIOA: DAT=18H, CTL=19H |
| PIOA | DATA=1CH, CMD=1DH（D7: 計測トリガ出力） |
| PIOB | DATA=1EH, CMD=1FH（SW0-SW4: スイッチ入力, Mode3） |
| CTC | **利用不可**（Super AKI-80では動作しない） |

## 現行ファイル構成

```
RVS8_GREEDY.ASM
  └─ RVS8_POSWEIGHT.ASM
       └─ RVS8_MINIMAX1.ASM
            └─ RVS8_MINIMAX1_16.ASM
                 └─ RVS8_MM1_MOB.ASM
                      └─ RVS8_PIOSW.ASM  ← 実機確認済み
                           └─ RVS8_MM2_AB.ASM  ← 実機確認済み
                                └─ MM2_AB_EG.ASM  ← 現行作業中（アセンブル通過）
```

## 実装済み機能 (MM2_AB_EG.ASM) ← 現行最新

- Minimax depth-2 + α-β 枝刈り（OppBestScore_d2、α-cutoff実装済み）
- **終盤完全読み**: 空きマス ≤ ENDGAME_THRESHOLD(=2) で AIset_EG (negamax + α-β) に切り替え
- `SF_ALPHA_TBL[10]`: depth 別 alpha テーブルで negamax α-β 実装
- 先後手選択: SW0=先手(黒), SW2=後手(白)、SIOA '1'/'2' でも選択可
- SaveBoard/RestoreBoard: HL パラメータ渡し、BOARD_SAVE1/SAVE2/BOARD_EG_SAVES
- PIOB スイッチ入力（SW0-SW4, Mode3）
- PIOA D7 → Pico GPIO15 AI処理時間計測

## 評価式 (depth-2)

```
AIset の mm_score:
  mm_score = POS_WEIGHT[ai_pos]        (1〜120)
           + (255 - opp_best)          (相手抑制)
           + (ai_mob - opp_mob + 64)   (モビリティ差)

OppBestScore_d2 の opp_best:
  opp_best = 255 - min_j( max_k(POS_WEIGHT[k] + flips[k]) )
  相手は AI 最善スコアが最小になる手を選ぶ (minimax)
```

## POS_WEIGHT テーブル（GA最適化版 2026-04-22）

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

角=128, Xマス=1(禁止), Cマス=3, near_x(C2/B3)=36, 辺中央=30, 中央=1
max score = 128 + 64 flips = 192 < 256 (byte-safe)
```

## AI処理時間 実測値

| 版 | 最大処理時間 |
|----|------------|
| depth-1 (RVS8_PIOSW) | ≈ 700 ms |
| depth-2 α-β なし | ≈ 6 秒 |
| depth-2 α-β あり | **≈ 2 秒以下** |

## Pico 側 (gameDisplay.py) 実装済み機能

- 盤面描画 + UART受信 + ノンブロッキング処理時間計測
- 先後手選択画面: `Choose:` 受信で [シアン●]:1st(X) [赤●]:2nd(O) 表示
- AI手・人手・スコア・処理時間の5行ステータス表示
- GAME OVER + 勝者行（石アイコン付き）
- AI PASS / YOU PASS 表示
- リトライ表示（5行目）・新ゲーム自動リセット
- ログ再生: `replay_log('/replay.txt')`

## 既知の注意事項（MM2_AB_EG 追加分）

- `EG_DEPTH` は `AIset_EG` から呼ぶ際は **1** で初期化（0 は BOARD_SAVE1 衝突）
- α-β の -INF 初期値は **81H**（`NEG(80H) = 80H` オーバーフローの罠を避ける）
- `SF_ALPHA_TBL[0]` には `EG_BESTSCORE` を設定（固定 80H でなく AI ベストスコア）
- `LD r,(nn)` / `LD (nn),r` は A のみ有効（B,C 等は A 経由で代替）
- `IXL`/`IXH` はアセンブラ非対応 → D/E レジスタで代替

## 次のTODO（優先順）

1. **MM2_AB_D3.ASM 実機アセンブル・動作確認** — GA最適化テーブル反映済み（次回スタート地点）
2. **D3_THRESHOLD=25 を実機計測・確定** — 新テーブルでの処理時間確認（30では5秒超、25に変更済み）
3. ~~**optimize_weights.py の結果確認・Z80テーブル反映**~~ ✓ 完了（2026-04-22、near_x=36・center=1が主な変化）
4. ~~D3_THRESHOLD を大きくして depth-3 適用範囲を拡大~~ — 30試行→5秒超、25に変更済み
5. ~~**MM2_AB_D3.ASM 終盤 depth-3 の処理時間を実機計測**~~ ✓ 完了（先手・後手ともに4秒以下確認、大会用確定）
6. **終盤完全読み（AIset_EG/SearchFull）を一時凍結** — 閾値=1 でもフリーズ発生、原因不明のため保留
7. ~~PASS連続2回・DRAW の動作テスト~~ ✓ 完了（gameDisplay.py 修正済み）
8. ~~depth-3 実装~~ ✓ 完了（MM2_AB_D3.ASM、空き<20で depth-3 切り替え）
9. ROM ブート化（オセロ完成後）

## ROM ブート化計画（オセロ完成後）

28C256（32KB EEPROM）でモニタ ROM と差し替え、オセロ専用機として起動する予定。

### 構造変更方針

```asm
        ORG  0000H      ; ROM領域: コード・文字列・テーブル
        LD   SP, 0FFF0H
        CALL InitSIOA   ; ★追加必須
        ; ... PIOA/PIOB 初期化（既存）
        ; ... コード本体

        ORG  8000H      ; RAM領域: 変数のみ
BOARD:      DEFS 64
BOARD_SAVE1: DEFS 64
; ...
```

### SIOA 初期化コード（モニタ 0196H から解析）

```asm
InitSIOA:
    LD   HL, SIOA_INIT_TBL
    LD   B,  9
    LD   C,  19H        ; SIOA_CTL
    OTIR
    LD   A,  17H
    OUT  (13H), A       ; ボーレートクロック (port 13H)
    LD   A,  04H
    OUT  (13H), A       ; 時定数 → 9600bps
    RET

SIOA_INIT_TBL:
    DEFB 18H, 04H, 44H, 03H, 0C1H, 05H, 6AH, 01H, 00H
```

HEX の 0000H-7FFFH 範囲のみ 28C256 に書き込む。

---

## 既知の注意事項

- `ApplyMove` は B,C を破壊 → **PUSH BC は ApplyMove より前**
- `CountMobility` は A を破壊 → **PUSH AF / POP AF 必須**
- `CountAllFlips` は AF,BC,DE,HL,IX,IY を破壊 → 呼び出し元で PUSH BC / PUSH DE 必須
- CTC 使用不可 → 計測は Pico 外部計測システムを使用
- `OppBestScore_d2` 内側ループで D が上書きされる → OD2_COL 先頭で毎回 `LD A,(HumSide); LD D,A`

## 計測システム

```
Z80 PIOA D7 ──→ Pico GPIO15 → measureTimeWithZ80.py
Z80 SIOA  ──┬──→ PC ターミナル
            └──→ Pico UART → LCD盤面描画（gameDisplay.py・動作確認済み）
```

## Gitコミット

- コミットメッセージ形式: `[ファイル名] 変更内容の概要`
- ビルド成果物（.err .hex .lin .lst .sym）はコミットしない

## 関数リファレンス (MM2_AB_EG.ASM)

### シリアル / IO

| 関数 | 入力 | 出力 | 破壊 |
|---|---|---|---|
| `PutChar` | A=文字 | — | なし |
| `PrintString` | DE=文字列アドレス(0終端) | — | AF,DE |
| `NEWLINE` | — | — | AF |
| `GetChar` | — | A=受信文字 | AF |
| `GETLINE` | HL=バッファ先頭 | A=文字数、バッファに0終端文字列 | AF,B,HL |
| `StartTimer` | — | PIOA bit7 HIGH | AF |
| `StopTimer` | — | PIOA bit7 LOW | AF |

### PIOB スイッチ

| 関数 | 入力 | 出力 | 破壊 |
|---|---|---|---|
| `InitPIOB` | — | — | AF |
| `Debounce` | — | ≈15ms待ち | なし |
| `WaitSwPress` | — | A=bitmask(アクティブLOW反転済み) | AF |
| `SW_PlayerMove` | — | 着手済(BOARD更新) | AF,BC,DE |

### ゲーム制御

| 関数 | 入力 | 出力 | 破壊 |
|---|---|---|---|
| `InitBoard` | — | BOARD初期化・PassStreak=0 | AF,BC,DE,HL |
| `PrintBoard` | — | 盤面シリアル出力 | なし(全PUSH/POP) |
| `PrintCounts` | — | "X:nn O:nn" 出力 | AF,BC,DE,HL |
| `DecideFirstTurn` | — | AiSide/HumSide/TurnSide設定 | AF,DE |
| `DoTurn` | — | A=0:継続 / 1:パス連続終了 | AF,BC,DE |
| `ShowWinner` | — | 勝者文字列出力 | AF,BC,DE,HL |

### 座標変換

| 関数 | 入力 | 出力 | 破壊 |
|---|---|---|---|
| `RowColToOffset` | B=row(0-7),C=col(0-7) | C=offset(B×8+C) | AF |
| `OffsetToRowCol` | C=offset | B=row,C=col | AF |
| `InRange` | B=row,C=col | A=1:有効 / 0:無効 | AF |

### 盤面操作

| 関数 | 入力 | 出力 | 破壊 |
|---|---|---|---|
| `SaveBoard` | HL=保存先バッファ | BOARD→(HL) | なし(全PUSH/POP) |
| `RestoreBoard` | HL=復元元バッファ | (HL)→BOARD | なし(全PUSH/POP) |
| `IsBoardFull` | — | A=1:満杯 / 0:空きあり | AF,BC,HL |
| `PlaceAtOffset` | A=side,C=offset | A=1:成功 / 0:失敗(BEL) | AF,HL |
| `CountStones` | — | B=黒数,C=白数 | AF,D,HL |
| `CountEmpty` | — | A=空きマス数 | AF,BC,HL |

### 合法手判定 / 着手

| 関数 | 入力 | 出力 | 破壊 |
|---|---|---|---|
| `TryDirCount` | WORK_PLAYER/ROW/COL・TD_DR/DC設定済み | A=ひっくり返せる枚数 | AF,BC,DE,HL |
| `IsLegalMove` | D=side,B=row,C=col | A=1:合法 / 0:不合法 | AF,BC,DE,HL,IX,IY |
| `FlipDirN` | A=枚数,WORK_*/TD_*設定済み | BOARD更新 | AF,BC,HL |
| `ApplyMove` | D=side,B=row,C=col | A=1:成功 / 0:失敗 | **AF,BC**,DE,HL,IX,IY |
| `HasAnyLegalMove` | D=player | A=1:あり / 0:なし | AF,BC,DE,HL,IX,IY |
| `CountAllFlips` | D=player,B=row,C=col | A=合計ひっくり返し数 | **AF,BC,DE,HL,IX,IY** |
| `CountMobility` | D=player | A=合法手数,AI_MOB_COUNT更新 | **AF**,BC,DE,HL,IX,IY |
| `ParseMove` | RXBUF設定済み | C=offset,A=1:成功 / 0:失敗 | AF,BC |

### AI — Minimax depth-2 + α-β

| 関数 | 入力 | 出力 | 破壊 |
|---|---|---|---|
| `OppBestScore` | D=opp | A=opp_best(depth-1),OBS_COUNT=手数 | AF,BC,DE,HL |
| `OppBestScore_d2` | D=opp | A=opp_best(depth-2+α-β),OBS_COUNT | AF,BC,DE,HL |
| `AIset` | — | 最善手をBOARDに反映・移動先を出力 | AF,BC,DE,HL |

### AI — 終盤完全読み

| 関数 | 入力 | 出力 | 破壊 |
|---|---|---|---|
| `EG_GetSaveAddr` | A=EG_DEPTH | HL=バッファアドレス | AF,BC,HL |
| `SearchFull` | D=side,EG_DEPTH設定,SF_SIDE_TMP=side | A=スコア(符号付き,手番視点) | AF,BC,DE,HL |
| `AIset_EG` | — | 最善手をBOARDに反映・移動先を出力 | AF,BC,DE,HL |

### 主要変数

| 変数 | 用途 |
|---|---|
| `AiSide` / `HumSide` / `TurnSide` | BLACK(1)/WHITE(2) |
| `PassStreak` | 連続パス数(0-2) |
| `AI_BEST_ROW/COL/SCORE` | AIset 作業用 |
| `OBS_BEST/OBS_COUNT/OBS2_MIN_AI` | OppBestScore 作業用 |
| `EG_DEPTH` | SearchFull 再帰深さ(AIset_EGから呼ぶ時は1で初期化) |
| `EG_BESTSCORE/BESTROW/BESTCOL` | AIset_EG 作業用 |
| `SF_SIDE_TMP` | SearchFull 内 side 保持用(AiSideでなくこちらを使う) |
| `SF_ALPHA_TBL[10]` | depth別 alpha値 |
| `BOARD_SAVE1` | AIset 外ループ用(depth-1) |
| `BOARD_SAVE2` | OppBestScore_d2 内ループ用(depth-2) |
| `BOARD_EG_SAVES` | SearchFull 再帰用(depth 2〜9,各64B) |

## 詳細履歴

`DEVLOG_RVS8.md`（このディレクトリ内）を参照
