# MM2_AB_EG.ASM 制御フロー図

## クイックナビ（Grepマーカー）

| マーカー | 内容 | 行 |
|---|---|---|
| `[CONST]` | ENDGAME_THRESHOLD等の定数 | 103 |
| `[WEIGHT]` | POS_WEIGHTテーブル | 167 |
| `[AICORE]` | OppBestScore/OppBestScore_d2/AIset | 990 |
| `[EGCORE]` | SearchFull/AIset_EG | 1438 |
| `[FLOW]` | DoTurn/DecideFirstTurn | 2225 |

## メインループ

```
START
  └─ InitPIOB
  └─ PrintBoard
  └─ DecideFirstTurn  (SW0=先手黒 / SW2=後手白)
       └─ HumSide/AiSide/TurnSide をセット

MAIN_LOOP:
  └─ DoTurn ──────────────────────────────────────────┐
       │ A=0: 継続                                     │
       │   └─ PrintBoard                               │
       │   └─ PrintCounts                              │
       │   └─ IsBoardFull ─ 満了→ GameOver            │
       │   └─ MAIN_LOOP へ戻る                        │
       │                                               │
       └─ A=1: 連続PASS終了 → GameOver ←─────────────┘

GameOver:
  └─ MSG_GAMEOVER 表示
  └─ ShowWinner
  └─ GO_ASK: "r:Retry or q:Quit ?"
       └─ 'r' → InitBoard → PrintBoard → DecideFirstTurn → MAIN_LOOP
       └─ 'q' → MSG_BYE → HALT
```

---

## DoTurn (2301行)

```
DoTurn:
  ├─ HasAnyLegalMove(TurnSide)
  │
  ├─[合法手なし]─────────────────────────────────────────
  │   ├─ AiSide == TurnSide ? → MSG_AI_PASS
  │   └─ else               → MSG_PL_PASS
  │       └─ DT_PassCommon:
  │             PassStreak++
  │             PassStreak >= 2 → DT_EndByPass: MSG_PASSEND, RET A=1
  │             else            → DT_SwitchReturn0
  │
  └─[合法手あり]─────────────────────────────────────────
      PassStreak = 0
      ├─ AiSide == TurnSide → DT_DoAI
      │     StartTimer
      │     CountEmpty
      │     ├─ empty <= ENDGAME_THRESHOLD(4) → AIset_EG
      │     └─ empty >  ENDGAME_THRESHOLD    → AIset
      │     StopTimer
      └─ else → DT_DoHum: SW_PlayerMove
          └─ DT_SwitchReturn0:
                TurnSide = BLACK→WHITE / WHITE→BLACK
                RET A=0
```

---

## OppBestScore_d2 (depth-2 α-β, 1066行)

```
OppBestScore_d2(D=HumSide):
  OBS_COUNT=0, OBS2_MIN_AI=FFH  ← α値 (AI最善スコアの最小値)

  外ループ: 相手の全合法手 j (row/col 0..7)
    CountAllFlips(HumSide) → 非合法: skip
    OBS_COUNT++
    SaveBoard(BOARD_SAVE2)
    ApplyMove(HumSide, j)
    OBS_BEST = 0

    内ループ: AIの全合法手 k (row/col 0..7)
      CountAllFlips(AiSide) → 非合法: skip
      score_k = POS_WEIGHT[k] + flips_k
      if score_k > OBS_BEST: OBS_BEST = score_k
      α-cutoff: OBS_BEST >= OBS2_MIN_AI → ID2_END (内ループ打ち切り)

    if OBS_BEST < OBS2_MIN_AI: OBS2_MIN_AI = OBS_BEST  ← α更新
    RestoreBoard(BOARD_SAVE2)

  OBS_COUNT==0 → RET 0 (相手合法手なし)
  else         → RET 255 - OBS2_MIN_AI
                 (相手が最善を尽くした時のAIスコア抑制値)
```

---

## AIset (通常探索, 1305行)

```
AIset:
  AI_BEST_SCORE=0, AI_BEST_ROW=FFH

  for row=0..7, col=0..7:
    CountAllFlips(AiSide, row, col) → flips
    if flips=0: skip

    SaveBoard(BOARD_SAVE1)
    ApplyMove(AiSide, row, col)
    OppBestScore_d2(HumSide) → opp_best, OBS_COUNT(相手手数)
    CountMobility(AiSide)    → AI_MOB_COUNT
    RestoreBoard(BOARD_SAVE1)

    mm_score = POS_WEIGHT[row*8+col]
             + (255 - opp_best)
             + (AI_MOB_COUNT - OBS_COUNT + 64)

    if mm_score > AI_BEST_SCORE: 更新

  ApplyMove(best)
  "AI moves to XX" 表示
```

---

## AIset_EG (終盤完全読み外ループ, 1646行)

```
AIset_EG:
  EG_BESTSCORE=81H(-127), EG_BESTROW=FFH

  for row=0..7, col=0..7:
    CountAllFlips(AiSide) → flips
    if flips=0: skip

    SaveBoard(BOARD_SAVE1)
    ApplyMove(AiSide, row, col)

    EG_DEPTH = 1           ← BOARD_SAVE1(depth=0)と衝突回避
    SF_ALPHA_TBL[0] = EG_BESTSCORE  ← alpha[0] = AI現在のベスト
    PUSH EG_BESTSCORE      ← SearchFull内部で上書きされるため退避
    SF_SIDE_TMP = HumSide
    SearchFull → A(相手視点)
    NEG        → ai_score(E)

    RestoreBoard(BOARD_SAVE1)
    POP → EG_BESTSCORE 復元  ★バグ⑤修正点

    ベスト更新 (符号付き比較, 初回=EG_BESTROW==FFHで無条件採用)

  ApplyMove(best)
  "AI moves to XX" 表示
```

---

## SearchFull (negamax再帰, 1453行)

```
SearchFull(D=side):
  HasAnyLegalMove(D) → あり/なし

  [合法手なし]:
    HasAnyLegalMove(3-D) →
      なし: ゲーム終了 → CountStones → 手番視点石差(SF_SIDE_TMP基準) RET
      あり: SF_Pass:
              EG_DEPTH++, SF_SIDE_TMP=相手番
              SearchFull(相手) → NEG → 自分視点 RET
              (EG_DEPTH--, SF_SIDE_TMP復元)

  [合法手あり]:
    EG_BESTSCORE = 81H       ★バグ⑥修正点(元80H→81H)
    SF_ALPHA_TBL[EG_DEPTH] = 81H

    for row=0..7, col=0..7:
      CountAllFlips(SF_SIDE_TMP) → flips
      if flips=0: skip

      SaveBoard(EG_GetSaveAddr(EG_DEPTH))
      ApplyMove
      EG_DEPTH++, SF_SIDE_TMP=相手番
      PUSH EG_BESTSCORE
      SearchFull(相手) → NEG → child_score(E)
      POP  EG_BESTSCORE 復元
      EG_DEPTH--, SF_SIDE_TMP=自番に戻す
      RestoreBoard

      ベスト更新:
        初回(EG_BESTSCORE==81H): 無条件採用
        以降: child > best → 採用

      α-β:
        SF_ALPHA_TBL[EG_DEPTH] = new_best
        beta = -SF_ALPHA_TBL[EG_DEPTH-1]
        if new_best >= beta: β-cutoff → RET

  RET EG_BESTSCORE
```

---

## EG_GetSaveAddr (1265行)

```
EG_DEPTH  0 → BOARD_SAVE1
EG_DEPTH  1 → BOARD_SAVE2
EG_DEPTH  N → BOARD_EG_SAVES + (N-2)*64
```

---

## 主要変数

| 変数 | 用途 |
|------|------|
| TurnSide | 現在の手番 (BLACK=1/WHITE=2) |
| AiSide / HumSide | AI・人間の色 |
| PassStreak | 連続PASS数 (2で終了) |
| EG_DEPTH | SearchFull 再帰深さ |
| EG_BESTSCORE | AIset_EG/SearchFull 現在ベスト |
| SF_SIDE_TMP | SearchFull内の現在手番 (AiSideと混同注意) |
| SF_ALPHA_TBL[0..9] | depth別 α値 |
| BOARD_SAVE1 | AIset_EG 外ループ用 (depth=0) |
| BOARD_SAVE2 | OppBestScore_d2 内ループ用 (depth=1) |
| BOARD_EG_SAVES | SearchFull 再帰用 (depth=2..9, 8×64B) |

---

## 既知バグ修正ポイント

| # | 箇所 | 内容 |
|---|------|------|
| ⑤ | AIset_EG 1677行 | PUSH/POP AF でEG_BESTSCORE退避 (SearchFull内上書き対策) |
| ⑥ | SF_HasMove 1508行 | EG_BESTSCORE初期値 80H→81H (NEGオーバーフロー対策) |
| ③ | SearchFull α-β | -INF初期値 80H→81H 統一 |
| ① | SearchFull終端 | AiSide→SF_SIDE_TMP 使用 (negamax正負逆転対策) |
| ② | AIset_EG呼出 | EG_DEPTH=0→1 (BOARD_SAVE1衝突回避) |
