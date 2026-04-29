# RVS8 オセロ AI 開発ログ

対象ハード: Super AKI-80 (Z80 10MHz)  
作業日: 2026-04-01 ～  
**ファイル系譜・関数仕様・TODO は CLAUDE.md を正とする**

---

## 運用ルール

- 新機能・バグ修正・設計変更時に更新（動作確認済みのものを記録）
- コミットメッセージ: `[ファイル名] 変更内容の概要`
- ビルド成果物（.err .hex .lin .lst .sym）はコミットしない

---

## 初期開発サマリー (2026-04-01〜04-20)

### ファイル進化 (各段階で実機確認済み)

| ファイル | 追加内容 | 処理時間 |
|---|---|---|
| RVS8_GREEDY | Greedy | — |
| RVS8_POSWEIGHT | POS_WEIGHT (手動設計) | — |
| RVS8_MINIMAX1(_16) | depth-1 minimax | — |
| RVS8_MM1_MOB | +モビリティ差評価 | ≈700ms |
| RVS8_PIOSW | PIOB スイッチ入力 | ≈700ms |
| RVS8_MM2_AB | depth-2 α-β | ≈2秒以下 |

### 主なバグ記録

- `ApplyMove` が B,C を破壊 → `PUSH BC` は必ず ApplyMove より前
- `CountMobility` が A を破壊 → `PUSH AF / POP AF` 必須
- CTC 利用不可（Super AKI-80 では全カウント 0）→ Pico 外部計測に移行

### 計測インフラ

PIOA D7 → Pico GPIO15 → measureTimeWithZ80.py でμs精度計測。  
SIOA → Pico UART → LCD（gameDisplay.py）で盤面描画。

### gameDisplay.py 主要機能（実機確認済み）

先後手選択 (Choose:)、AI手/人手/スコア/処理時間/評価値の5行表示、  
AI PASS / YOU PASS、GAME OVER + 勝者、リトライ (PB0)、投了 (PB5)、ログ再生。

---

## MM2_AB_EG 〜 MM2_AB_D3 (2026-04-15〜04-22)

### 終盤完全読み (MM2_AB_EG) — 凍結中

- SearchFull: negamax 再帰 + α-β、SF_ALPHA_TBL[depth] で depth 別 alpha 管理
- 主なバグ3点を修正（NEG(80H) オーバーフロー → 81H に変更、EG_BESTSCORE 退避漏れ等）
- 閾値=1 でもフリーズ発生 → 原因不明のため凍結

### MM2_AB_MO 〜 MM2_AB_EV (2026-04-20)

- ムーブオーダリング追加 → 処理時間大幅短縮（体感）
- CountStable 実装（コーナー＋辺の連続石）
- フェーズ切り替え（EARLY/MID/LATE）+ mob/stable 重み付け評価

### MM2_AB_D3 — 大会用確定版 (2026-04-21〜04-22)

- depth-2/3 切り替え: 空き < D3_THRESHOLD(=25) → depth-3
- **実機計測: 先手・後手ともに処理時間4秒以下確認 → 大会用確定**
- GA最適化 POS_WEIGHT (optimize_weights.py, 2026-04-22):
  `corner=128, x_sq=1, near_x=36, center=1` が優勝値

---

## AT28C256 非互換問題 (2026-04-23)

27C256 と AT28C256 はピン非互換（ピン1: VPP vs A14、ピン27: A14 vs WE#）。  
Super AKI-80 ソケットに直挿し不可。改造コスト高のため AT28C256 を却下。  
**→ 27C256 EPROM（UV消去型）を使用する方針に確定。イレーサー・ライター手元にあり。**

---

## リファクタリング RFCT000〜003 (2026-04-24〜04-25)

### 背景

MM2_AB_BCUT.ASM で D2_MOB_MAX=2016 (大きすぎ) のため β-cutoff が dead code 化。  
`OD2_BETA = AI_BEST_SCORE - AMM_POS_W - 2016` が常に負 → cutoff 発火せず。  
同様に α-cutoff (AMM_BETA_SKIP) も未発火。コードの複雑さがデバッグ困難の根本原因と判断。

### 各ステップ

| ファイル | 内容 | 結果 |
|---|---|---|
| RFCT000 | 変数・ラベル・関数名リネーム + デッドコード削除 | アセンブル ✓ |
| RFCT001 | MOB_STABLE_CAP をフェーズ別3定数に分割 | アセンブル ✓ |
| RFCT002 | P2_ALPHA 初期値を OBS_SCORE_MAX(192) に修正 + depth-2 専用閾値追加 | アセンブル ✓ |
| RFCT003 | D3_THRESHOLD=20、評価値表示 (PrintDec4/Signed)、PB5 投了機能 | 実機確認 ✓ |

### RFCT002 実機テスト (2026-04-25)

残り25手付近で1回 4秒超え → D3_THRESHOLD を 25 → 20 に変更。

### RFCT003 動作確認

- TeraTerm: `Eval:XXXX` 毎ターン表示 ✓
- Pico LCD: 5行目に評価値表示 ✓
- PB5 押下 → `Game aborted.` → リトライ画面 ✓

---

## benchmark_vs.py 結果と AI強化方針 (2026-04-26)

| 対戦 | 結果 |
|---|---|
| V1/d2 vs V2/d2 | **V2/d2: 80%** |
| V1/d2 vs V1/d3 | V1/d3: 55% |
| V1/d2 vs V2/d3 | **V2/d3: 95%** |

**AI 強化の主因は深さより負値テーブル（V2）**。  
→ 符号付き POS_WEIGHT を Z80 に実装する方針に決定 → RFCT100 へ。

---

## RFCT100 AIコア再構築 (2026-04-26〜04-28)

### 設計方針

RFCT003 の 4段分割ループ（Ply2Best_D2/D3, Ply3Best, LeafEval）を廃止。  
**再帰 negamax（NegaMax 関数）+ 符号付き POS_WEIGHT** に全面置き換え。  
ゲーム制御・I/O・盤面操作等のインフラは流用。

### 探索構造

```
AIset:
  for pos in POS_ORDER:
    ApplyMove(AiSide)
    score = -NegaMax(HumSide)   ← 符号反転
    if score > NM_ROOT_SCORE: 採用

NegaMax(side):
  if NM_CALL_DEPTH == NM_TOTAL_DEPTH: return EvalLeaf(side)
  for pos in POS_ORDER:
    ApplyMove(side)
    child = -NegaMax(3-side)    ← 符号反転 (negamax の核心)
    if child > alpha: alpha = child
  return alpha
```

depth-2: NM_TOTAL_DEPTH=1 / depth-3: NM_TOTAL_DEPTH=2  
切り替え: 空き < D3_THRESHOLD(20) → depth-3

### EvalLeaf 評価式

```
EARLY (空き≥44): pos_diff + mob_diff×2 + stable_diff×4
MID   (空き≥12): pos_diff + mob_diff×2 + stable_diff×6
LATE  (空き<12):  stone_diff×100 + stable_diff×30

pos_diff = Σ(自石:+POS_WEIGHT) - Σ(相手石:+POS_WEIGHT)  (符号付きテーブル)
```

### 実装中のバグ・修正記録

| バグ | 原因 | 修正 |
|---|---|---|
| AI が手を指さない (Step4) | NM_SCORE_MIN=-255 不足（V2 負値で score < -255 が発生） | -32767 → 比較オーバーフロー |
| AI が手を指さない（続き） | score - NM_SCORE_MIN > 32767 → 符号ビット誤立ち | NM_SCORE_MIN=-512 (0xFE00) |
| 処理時間8秒・評価値おかしい | NM_SCORE_MIN=-2048 不足（mob/stable 追加後 max|score|≈2608） | -4096 (0xF000) に変更 |
| depth-2 で高すぎる正値が続く | ホライゾン効果（仕様）+ NM_SCORE_MIN 不足のコンボ | NM_SCORE_MIN 修正で一部解消 |

### POS_WEIGHT テーブル変遷

| 時期 | テーブル | 用途 |
|---|---|---|
| Step1 | V2 (corner=120, x_sq=-40) | 初期値 |
| Step6 | GA_D3 優勝 (corner=66, edge_ctr=44, x_sq=-45) | POS_WEIGHT_D3 |
| Step6 | GA_D2signed 優勝 (corner=114, x_sq=-54) | POS_WEIGHT_D2 (初期) |
| 2026-04-29 | **GA_RFCT100 優勝 (corner=157, x_sq=-49, 内陸全負値)** | POS_WEIGHT_D2 (現行) |

### EvalLeaf mob/stable ウェイト変遷

| 変更 | mob_w | stable_w | 理由 |
|---|---|---|---|
| 初期 | ×12/8/4 | ×30/50/30 | Python 実装と同値 |
| 修正1 | ×3 | ×8/12 | pos_diff が支配されすぎ |
| 修正2 | ×1 | ×4/6 | d2 でコーナー誘い取り頻発 |
| **現行** | **×2** | **×4/6** | mob 項が小さすぎたため微増 |

---

## GA 最適化結果まとめ

### GA_D3 (optimize_weights.py, depth=3, 2026-04-26)

優勝: `[66, -32, -1, 44, -45, 22, 1, 10, 23, -29]`  
→ RFCT100 POS_WEIGHT_D3 に採用

### GA_D2signed (optimize_weights_d2signed.py, depth=2, 2026-04-27)

所要時間: 約38.4分。優勝 (101/560勝): `[114, -5, -16, -7, -54, -16, 7, 6, 2, -12]`  
→ RFCT100 POS_WEIGHT_D2 初期値として採用

### GA_RFCT100 (optimize_weights_rfct100.py, depth=2, mob×2/stable×4/6, 2026-04-29)

所要時間: 約51.6分（GA 35.7分 + トーナメント 15.9分）。12個体 1320ゲーム。

| 順位 | 勝数/1320 | 備考 |
|---|---|---|
| **1位** | **153** | `[157,-12,2,5,-49,-16,-4,-19,-15,-24]` ← **現行採用** |
| 3位 | 118 | GA_D2signed（旧値） |
| 12位 | 46 | GA_D3（depth-2評価関数には不適） |

```
POS_WEIGHT_D2 (現行):
  ;     A   B   C   D   E   F   G   H
  DEFB  157,-12,  2,  5,  5,  2,-12, 157  ; 1
  DEFB  -12,-49,-16, -4, -4,-16,-49, -12  ; 2
  DEFB    2,-16,-19,-15,-15,-19,-16,   2  ; 3
  DEFB    5, -4,-15,-24,-24,-15, -4,   5  ; 4/5
  DEFB    2,-16,-19,-15,-15,-19,-16,   2  ; 6
  DEFB  -12,-49,-16, -4, -4,-16,-49, -12  ; 7
  DEFB  157,-12,  2,  5,  5,  2,-12, 157  ; 8
corner=157、x_sq=-49、内陸マス全て負値が特徴
```

---

## RFCT100 実機対局観察・depth-2 分析 (2026-04-29)

### 対局ログ（AI=O）と動作確認

```
X:07 O:12  AI→C7  Eval:-134  (C6:X→O 1枚フリップ ✓)
X:06 O:14  人間→C2            (D3:O→X 対角1枚 ✓)
X:08 O:13  AI→B1  Eval:-50   (C2/D3/E4:X→O 対角3枚 ✓)
X:05 O:17
```

石数・フリップ数の整合 全て確認 → **negamax は正しく動作している**。

Eval 符号が負の理由: X が H1(コーナー=+157) を保有、O の石は内陸（負値マス）集中。  
石数で O が有利でも pos_diff は O が大幅マイナス（X の H1 だけで 157 点差）。

### depth-2 の本質的限界

depth-2 が選択する手:
```
max_AI手 [ min_相手手 [ EvalLeaf ] ]  ← 相手の最善応手まで折り込んだ minimax スコア
```

**防げるもの:** 「今打つと次の手で角を取られる」（1手後の脅威）  
**防げないもの:** 「n手後に角が取られる」「石数が多くなり合法手が枯渇する」

オセロ中盤の原則「石数多い = 相手の合法手が増える = 自分の合法手が減る」は  
EvalLeaf の `mob_diff×2` で部分的に捉えるが、depth-2 では2手後の mob しか見えない。

### 今後の改善方針

1. **α-β 枝刈り追加（TODO #24）** → 速度改善 → D3_THRESHOLD 引き上げ
2. D3_THRESHOLD を 20→30 程度に上げることで depth-3 の適用範囲を広げる
3. mob_diff の重みを上げることも検討（ただし GA で再調整が必要）
