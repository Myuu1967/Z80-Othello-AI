# 関数リファレンス・命名規則

関数の入出力/破壊レジスタ一覧と、RFCT000 で決めた変数・ラベル・関数の命名規則。
入口は [CLAUDE.md](../CLAUDE.md)。

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

## RFCT000 命名規則（2026-04-25 決定）

### 変数名リネーム表

| 旧 (BCUT) | 新 (RFCT000〜) | 意味 |
|----------|--------------|------|
| `AMM_IDX` | `P1_IDX` | ply1 AIループインデックス |
| `OD2_IDX` | `P2_IDX` | ply2 OPPループインデックス（d2/d3共用） |
| `ID2_IDX` | `P3_IDX` | ply3 AIループインデックス |
| `LD3_IDX` | `LF_IDX` | leaf OPPループインデックス |
| `OBS2_MIN_AI` | `P2_ALPHA` | OPP ply2 の α 値（AI応手スコアの最小値） |
| `OD2_BETA` | `P1_BETA` | AI ply1 の β 閾値（d2/d3共用） |
| `OBS_BEST` | `P2_INNER_BEST` | OppBestScore_d2 内ループの一時最善値 |
| `D3_AI_BEST` | `P3_BEST` | ply3 AI最善スコア |
| `D3_AI_ALPHA` | `LF_ALPHA` | leaf の α 閾値 |
| `OBS3_BEST` | `LF_BEST` | leaf OPP最善スコア |
| `AMM_POS_W` | `P1_POS_W` | ply1 AI位置重みキャッシュ |
| `D2_MOB_MAX` | `MOB_STABLE_CAP` | mob_stable項の上限（RFCT001でフェーズ別に分割） |

### ラベル名リネーム表

| 旧 (BCUT) | 新 (RFCT000〜) | 対象関数 |
|----------|--------------|---------|
| `AMM_LOOP/NEXTCOL/END` | `P1_LOOP/P1_NEXT/P1_END` | AIset 外ループ |
| `AMM_BETA_SKIP/DONE/DISABLE` | `P1_BSKIP/P1_BDONE/P1_BDIS` | AIset プリフィルタ |
| `AMM_EVAL_EARLY/MID/LATE` | `P1_EVAL_EARLY/MID/LATE` | AIset 評価フェーズ分岐 |
| `AMM_SCORE_CMP` | `P1_SCORE_CMP` | AIset スコア比較 |
| `OD2_LOOP/NEXTCOL/END/BCUT` | `P2_LOOP/P2_NEXT/P2_END/P2_BCUT` | OppBestScore_d2 |
| `ID2_LOOP/NEXT/END` | `P2I_LOOP/P2I_NEXT/P2I_END` | OppBestScore_d2 内ループ |
| `OD3_LOOP/NEXTCOL/END/BCUT` | `P2D3_LOOP/P2D3_NEXT/P2D3_END/P2D3_BCUT` | OppBestScore_d3 |
| `AB_D3_LOOP/NEXT/END/POP` | `P3_LOOP/P3_NEXT/P3_END/P3_POP` | AiBestScore_d3 |
| `ID3_L/NEXT/END` | `LF_LOOP/LF_NEXT/LF_END` | ID3_LOOP（LeafEval） |
| `AEV_EARLY` | `P1_PHASE_EARLY` | AIset フェーズ判定（序盤） |
| `AEV_MID` | `P1_PHASE_MID` | AIset フェーズ判定（中盤） |
| `AEV_SET_PHASE` | `P1_PHASE_LATE` | AIset フェーズ判定（終盤） |
| `AMM_SET_DEPTH` | `P1_SET_DEPTH` | AIset depth選択 |
| `AMM_CALL_D2` | `P1_CALL_D2` | OppBestScore_d2 呼び出し分岐 |
| `AMM_AFTER_OBS` | `P1_AFTER_OBS` | OppBestScore 呼び出し後 |
| `OD2_RETURN` | `P2_RETURN` | OppBestScore_d2 戻り処理 |
| `OD3_RETURN` | `P2D3_RETURN` | OppBestScore_d3 戻り処理 |

### 関数名リネーム表

| 旧 (BCUT) | 新 (RFCT000〜) | 意味 |
|----------|--------------|------|
| `OppBestScore_d2` | `Ply2Best_D2` | depth-2 時のply2探索 |
| `OppBestScore_d3` | `Ply2Best_D3` | depth-3 時のply2探索 |
| `AiBestScore_d3` | `Ply3Best` | ply3 AI探索 |
| `ID3_LOOP` | `LeafEval` | leaf 評価ループ |
| `AIset` | 変更なし | 外部(DoTurn)から呼ぶため維持 |
| `OppBestScore` | 削除（デッドコード） | depth-1版、どこからも呼ばれていない |

### RFCT001 で追加する定数

```asm
; mob_stable_term 最大値（フェーズ別）
;   mob_diff+64 max = 96 (= 32moves + 64), stable_diff+8 max = 24
MOB_STABLE_CAP_EARLY EQU 1872  ; 96×12 + 24×30
MOB_STABLE_CAP_MID   EQU 1968  ; 96×8  + 24×50
MOB_STABLE_CAP_LATE  EQU 1104  ; 96×4  + 24×30
OBS_SCORE_MAX        EQU  192  ; POS_WEIGHT_MAX(128) + FLIPS_MAX(64)
```
