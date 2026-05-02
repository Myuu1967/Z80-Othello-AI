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
| 2026-04-29 | GA_RFCT100 優勝 (corner=157, x_sq=-49, 内陸全負値) | POS_WEIGHT_D2 (廃止) |
| 2026-04-29 | **GA_D2S 優勝 (corner=114, x_sq=-54, 内陸正値)** | POS_WEIGHT_D2 (現行) |

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

---

## NM_RECURSE バグ修正 (2026-04-29)

### 原因

`ApplyMove` 内で `TryDirCount` が `LD D,0` を実行するため、`ApplyMove` 返り時点で D=0。
その後の opponent side 判定コードが **D (=0) をそのまま参照** していた。

```asm
; 修正前 (バグあり)
CALL ApplyMove     ; D は TryDirCount の LD D,0 で破壊され D=0
LD   A,BLACK       ; A = 1
CP   D             ; 1 vs 0 → 常に NZ
JR   NZ,NMR_OPP_WHITE  ; 常にジャンプ
LD   D,WHITE       ; スキップ
NMR_OPP_WHITE:
LD   D,BLACK       ; 常に D=BLACK になる
```

### 影響

- **AI=BLACK** (HumSide=WHITE): 偶然正しく動作（opponent=BLACK が正解）
- **AI=WHITE** (HumSide=BLACK): 誤動作（opponent=WHITE のはず → BLACK を設定）
  → NegaMax が WHITE 側も BLACK として評価 → 評価符号が反転 → 最悪手を選択するに等しい動作

### 修正

`ApplyMove` 後に `NM_SIDE_TBL[depth]` から現サイドを再ロードして正しい opponent を設定。
RFCT100.ASM / RFCT120.ASM 両方に適用済み。

---

## RFCT100 v2 評価関数設計・GA スクリプト作成 (2026-04-29)

### 動機

depth-2 対局観察で「石を多く取る手が mob を下げる」問題を確認。  
中盤に石が多くなると相手の合法手が増え、自分の合法手が減る。  
mob_diff×2 では捉えきれない部分を **石数差ペナルティ** で補う。

### 新評価式 (optimize_weights_rfct100_v2.py)

```
EARLY (empty≥44): pos_diff + mob_diff×3 + stable_diff×4  - stone_diff×2
MID   (empty≥12): pos_diff + mob_diff×3 + stable_diff×6  - stone_diff×1
LATE  (empty<12):  stone_diff×100 + stable_diff×30  (変更なし)
```

`-stone_diff×w` = 自石が相手より多いほどスコアが下がる → 石の取り過ぎを抑制。  
`mob_diff` を ×2→×3 に強化（全滅リスクの安全なプロキシとして）。  
EARLY に比べ MID のペナルティを小さくして終盤移行を意識。

### ウェイト選択の根拠

| 項 | EARLY | MID | 理由 |
|---|---|---|---|
| mob_diff | ×3 | ×3 | mob は石数リスクの最も安全なプロキシ |
| stable_diff | ×4 | ×6 | 変更なし |
| stone_diff | −×2 | −×1 | 序盤は差が小さく影響軽微、中盤で緩める |

### 作成ファイル

`python/optimize_weights_rfct100_v2.py`  
- 初期集団の起点: GA_RFCT100_PARAMS（現行優勝値 `[157,-12,2,5,-49,-16,-4,-19,-15,-24]`）  
- 出力: `python/result2.txt` に結果記録済み

### GA v2 結果 (optimize_weights_rfct100_v2.py, 2026-04-29)

所要時間: 約52.6分（GA 40.8分 + トーナメント 11.8分）。20個体 900ゲーム。

| 順位 | 勝数/900 | 備考 |
|---|---|---|
| **1位** | **128** | `[114,-5,-16,-7,-54,-16,7,6,2,-12]` [GA_D2S] ← **現行採用** |
| 2位 | 111 | `[195,-16,-17,2,-3,-54,-16,-11,-2,-30]` |
| 4位 | 94 | `[157,-12,2,5,-49,-16,-4,-19,-15,-24]` [GA_RFCT100、廃止] |
| 8位 | 61 | `[66,-32,-1,44,-45,22,1,10,23,-29]` [GA_D3] |

**結果考察**: v2評価関数（石数差ペナルティ）では内陸マスに正値（inner=6, inner2=2）を持つ GA_D2S が最適。  
新しい GA 個体（corner=195〜207）は GA_D2S に届かなかった。  
→ RFCT100.ASM の POS_WEIGHT_D2 と POS_ORDER_D2 を GA_D2S 値に更新済み。  
→ `play_vs_ai.py` の POS_WEIGHT テーブルも同値に更新済み。

### ウェイト改訂 (2026-04-29 対人試験後)

ユーザーが play_vs_ai.py で対局し「強くなった」と確認したウェイトに更新:

| 項 | 初期案 | 対人試験後 |
|---|---|---|
| mob_diff (EARLY/MID) | ×3 | ×8 |
| stable_diff EARLY | ×4 | ×8 |
| stable_diff MID | ×6 | ×16 |
| stone_diff EARLY | −×2 | −×8 |
| stone_diff MID | −×1 | −×4 |

位置重みより動的評価（mob・stable・石数ペナルティ）を重視する方向。  
GA スクリプト (optimize_weights_rfct100_v2.py) も同値に同期済み。

---

## 人 vs AI 対戦 GUI 作成 (2026-04-29)

`python/play_vs_ai.py` を新規作成。tkinter GUI。

- 先後手選択ダイアログ → 合法手を緑ドット表示 → クリックで着手
- AI は RFCT100 v2 評価関数 + GA_RFCT100 優勝 POS_WEIGHT を使用
- 空き ≥ 20 → depth-2 / 空き < 20 → depth-3 自動切替
- AI 最終手を黄色リングでハイライト、ステータスバーに評価値・深さ表示
- PASS ダイアログ、ゲーム終了後リプレイ対応

---

## RFCT120 POS_WEIGHT ランタイム切替 + depth-3 GA スクリプト作成 (2026-04-29)

### 背景

depth-2 と depth-3 では最適な POS_WEIGHT が異なる（depth-3 ではより先を読めるため
コーナー重みを下げられる）。従来はコンパイル時 EQU エイリアスで固定していたが、
AIset で depth を選択するタイミングにランタイム切替を実装した。

### RFCT120.ASM 変更内容

- `NM_WT_PTR` / `NM_ORD_PTR` 変数を追加（使用中テーブルの先頭アドレスを保持）
- `AIset` の depth 選択分岐で両ポインタをセット
  - depth-3 → `POS_WEIGHT_D3` / `POS_ORDER_D3`
  - depth-2 → `POS_WEIGHT_D2` / `POS_ORDER_D2`
- `EvalLeaf`: `LD IY,POS_WEIGHT` → `LD IY,(NM_WT_PTR)`
- `AS_LOOP` / `NMR_LOOP`×2: `LD HL,POS_ORDER` → `LD HL,(NM_ORD_PTR)`（計3箇所）
- コンパイル時 EQU エイリアス（`POS_WEIGHT EQU POS_WEIGHT_D2` 等）をコメントアウト

### GA スクリプト作成

`python/optimize_weights_d3_v2eval.py` を新規作成。

- depth-3 × v2 評価関数（mob×8/stable×8/16/-stone×8/4）で POS_WEIGHT を最適化
- 初期ベースライン: `GA_D3_PARAMS`（旧 depth-3 最適値）
- 設定: 個体数=12, 世代=20, GA評価=3ゲーム, トーナメント=10ゲーム
- 所要時間: 60〜90 分見込み（実行中）
- 結果は `result_d3_v2eval.txt` に出力

GA 完了後に `POS_WEIGHT_D3` / `POS_ORDER_D3` を新値に更新予定。

---

## RFCT120 POS_WEIGHT_D3 更新 + β-cutoff 実装 (2026-04-30)

### POS_WEIGHT_D3 / POS_ORDER_D3 を GA_RFCT100 値に更新

`result_d3_v2eval.txt`（optimize_weights_d3_v2eval.py, depth-3×v2eval）の結果を反映。

| 順位 | 勝数/280 | テーブル |
|---|---|---|
| **1位** | **49** | `[157,-12,2,5,-49,-16,-4,-19,-15,-24]` **GA_RFCT100** ← 採用 |
| 2位 | 41 | `[114,-5,-16,-7,-54,-16,7,6,2,-12]` GA_D2S |
| 7位 | 22 | `[66,-32,-1,44,-45,22,1,10,23,-29]` GA_D3（旧値） |

変更点:
- `POS_WEIGHT_D3`: 旧 GA_D3 値 → GA_RFCT100 値（corner=157, x_sq=-49, 内陸全負値）
- `POS_ORDER_D3`: 重み降順を新テーブルに合わせて更新（157, 5, 2, -4, -12, -15, -16, -19, -24, -49）

### β-cutoff 実装 (TODO #25)

`NM_RECURSE` に β カットオフを追加。アセンブルOK。

#### 実装方針

negamax の性質: 子ノードのスコアは親の視点から符号反転して使う。

cutoff 条件: `alpha[depth] + alpha_parent >= 0`  
（= `alpha[depth] >= -alpha_parent = beta`）

#### 追加変数

`NM_AIset_ALPHA: DEFW` — AIset ループの現在ベスト（depth=0 の parent alpha）

#### AIset 変更

NegaMax 呼び出し直前に `NM_ROOT_SCORE → NM_AIset_ALPHA` をコピー。

#### NM_RECURSE 変更（alpha 更新成功時のみチェック）

```
alpha 更新後:
  LD A,(NM_CALL_DEPTH)
  depth==0 → BC = NM_AIset_ALPHA
  depth>=1 → BC = NM_ALPHA_TBL[(depth-1)*2]
  ADC HL,BC   ; HL = alpha[depth] + alpha_parent
  JP M, NMR_NO_UPDATE   ; sum < 0 → no cutoff
  RestoreBoard → JP NMR_RETURN  ; β-cutoff 発火
```

#### 効果の見込み

| depth | cutoff 発生条件 | 期待効果 |
|---|---|---|
| depth-2 | alpha[0] + NM_AIset_ALPHA >= 0（HumSide応手が良すぎる） | やや改善 |
| depth-3 | alpha[1] + alpha[0] >= 0（内ループを早期打ち切り） | 主要な速度改善（O(b²)→O(b^1.5)相当） |

実機での処理時間計測が次のステップ（目標: depth-3 で 4 秒以下）。

### 実機確認結果 (2026-04-30, TODO #25)

**先手・後手ともに AI 思考時間 4 秒以内を確認。β-cutoff の効果で RFCT120 は処理時間クリア。**

---

## RFCT120 α-β 完全実装（α下限継承 + エントリー β-cutoff）(2026-04-30)

### 背景

β-cutoff は実装済みだったが、α 下限ウィンドウの伝播が不完全だった。

`NM_RECURSE` で `NM_ALPHA_TBL[depth]` を常に `NM_SCORE_MIN` で初期化していたため、
depth=1 の探索で「すでに beta より大きい alpha」で入っても即時カットされず、
葉評価を 1 回以上行ってから cutoff していた。

### 標準 negamax α-β の α 伝播

```
depth=0 への α: NM_SCORE_MIN  (親=AIset の alpha は -INF)  → 変更なし
depth=1 への α: NM_AIset_ALPHA (= -(-NM_AIset_ALPHA) = -beta[0])  ← 今回の修正
```

### 修正内容

`NM_RECURSE` 初期化部分を変更（`NM_ALPHA_TBL[depth]` の初期化ロジック）:

```asm
; 変更前
NM_ALPHA_TBL[depth] = NM_SCORE_MIN (E000H)  ; 常に固定

; 変更後
if depth == 0: NM_ALPHA_TBL[0] = NM_SCORE_MIN          ; 変更なし
if depth >= 1: NM_ALPHA_TBL[d] = NM_AIset_ALPHA         ; α 下限継承
```

さらに初期化直後にエントリー β-cutoff 確認を追加:

```asm
; alpha[depth] + alpha[depth-1] >= 0 → 初期 alpha が既に beta を超えている
; → SaveBoard も ApplyMove も不要、即 NMR_RETURN
```

### 効果

| 状況 | 変更前 | 変更後 |
|---|---|---|
| NM_AIset_ALPHA=100, alpha[0]=-10 で depth-1 入場時 | 葉1枚評価してから cutoff | 入場直後に即 cutoff |
| 全体 | β-cutoff のみ | 完全 α-β ウィンドウ [α,β] |

アセンブルOK（2026-04-30）。処理時間 4 秒以下を確認。対局テストは後日実施予定。

---

## D3_THRESHOLD 30→25 調整 + play_vs_ai.py RFCT120 同期 (2026-05-01)

### 経緯

実機対局テストで D3_THRESHOLD=30 の状態でも **7 秒かかる手が 1 手確認**された。
α下限継承 + エントリー β-cutoff 後でも worst case が許容範囲を超えるため、閾値を下げる対処を実施。

### 変更内容

| ファイル | 変更 |
|---|---|
| `RFCT120.ASM` | `D3_THRESHOLD EQU 30` → `25` |
| `python/play_vs_ai.py` | `D3_THRESHOLD = 30` → `25` |

`play_vs_ai.py` はこのタイミングで RFCT120.ASM と完全同期:
- `POS_WEIGHT_D2` / `POS_WEIGHT_D3` を別テーブルとして定義
- `ai_move()` 内で depth に応じてランタイム切替
- コメントを RFCT120 参照に更新

### 処理時間の限界考察

| D3_THRESHOLD | 状態 |
|---|---|
| 40 | 10秒超え発生（α下限継承実装後に試行）|
| 30 | 7秒の局面が1手存在 |
| 25 | 実機計測予定（RFCT003 時代の D3_THRESHOLD=20 で 4秒以下実績あり） |
| 20 | 確実に 4秒以下（RFCT003 確認済み）、ただし depth-2 範囲が広がり弱く感じる |

Z80 10MHz・4秒以内という制約のもとでは **depth-2/3 ハイブリッドの閾値チューニングがほぼ限界**。
深さ拡張以外の強化手段（評価関数の質向上）が次の課題。

### 今後の改善方針

純粋な深さ拡張は限界に近いため、同じ depth-2/3 でも**評価関数の精度を上げる**方向を検討:
- フロンティア石ペナルティ（空きマス隣接石は裏返されやすい）
- 奇数偶数理論（終盤の手番有利）
- mob/stable 重みの再 GA 最適化

---

## 対局後バグ分析：「相手有利な手」の原因精査 (2026-05-02)

### 問題1: EMPTY_CACHE バグ（致命的・depth-3 エンドゲーム付近）

`EMPTY_CACHE` は `AIset` 冒頭で1回だけ取得され、再帰中に更新されない。
`EvalLeaf` はこの root 値をフェーズ判定に使うため、leaf の実際の空きマス数と乖離する。

```asm
AIset:
    CALL CountEmpty
    LD   (EMPTY_CACHE),A    ; root値で固定 ← 問題
...
EvalLeaf:
    LD   A,(EMPTY_CACHE)    ; root値のまま使用
    CP   12
    JP   C,EL_LATE
```

影響範囲:

| 探索 | root empty | leaf empty | フェーズ誤認 | 影響度 |
|---|---|---|---|---|
| depth-2 | 25〜43 | 23〜41 | なし | 無影響 |
| depth-2 | 44〜46 | 42〜44 | EARLY→MID | stable_w 8 vs 16 の取り違え（軽微） |
| **depth-3** | **13〜14** | **10〜11** | **MID→LATE** | **stone×100 が適用されず致命的** |

depth-3 で空き13〜14 の局面: 本来 `stone_diff × 100` が支配すべき終盤を `pos_diff + mob×8 + stable×16` で評価 → AI が終盤戦略を完全に誤る。

**修正内容（2026-05-02実施）**: NegaMax の leaf 到達時（`NM_TOTAL_DEPTH==NM_CALL_DEPTH`）と `NMR_END`（合法手なし）の EvalLeaf 呼び出し直前に `CountEmpty` を追加し `EMPTY_CACHE` を更新。`CountEmpty` は BC・HL を PUSH/POP 保護しており D（side）も非破壊のため追加コストは64マスのスキャンのみ。

```asm
; NegaMax leaf (修正後)
        CALL CountEmpty         ; A=実際の空きマス数 (BC,HL保持 D保持)
        LD   (EMPTY_CACHE),A
        CALL EvalLeaf
        RET

; NMR_END PASS (修正後)
        LD   D,(HL)
        CALL CountEmpty         ; A=実際の空きマス数 (BC,HL保持 D保持)
        LD   (EMPTY_CACHE),A
        CALL EvalLeaf
        RET
```

### 問題2: stone_diff ペナルティが depth-2 で過大に効く可能性（設計問題）

`EvalLeaf` の MID フェーズ評価: `pos_diff + mob_diff×8 + stable_diff×16 - stone_diff×4`

石を多く取るほどペナルティが大きくなる設計のため、積極的に石を取るべき局面で消極的な手を選ぶ可能性がある。特に序盤（EARLY: `-stone_diff×8`）は重みが大きい。

| 手 | pos_diff | mob×8 | stable×16 | stone×4 | 合計（例）|
|---|---|---|---|---|---|
| コーナー取り（net +6石） | +90 | −40 | +16 | **−24** | +42 |
| 安全手（net ±0石） | +5 | +24 | 0 | 0 | +29 |

コーナーが勝るが差が縮まり、配置次第では逆転しうる。

### 問題3: PASS 処理の Python vs Z80 不整合（軽微）

Z80 の `NMR_END`（合法手なし）: `EvalLeaf` を呼んで即リターン（相手手番を探索しない）。  
Python の `negamax`: `return -negamax(board, depth, -beta, -alpha, opp)` で depth 消費なく相手手番を継続。  
PASS が絡む局面での評価がズレる。

### 優先対処順

1. **EMPTY_CACHE バグ修正**（depth-3 エンドゲームに直接影響）→ ✓ 完了（2026-05-02）
2. **MID_GAME 閾値引き上げ（12→18）**（depth-3 leaf の MID 式破綻対策）→ ✓ 完了（2026-05-02）
3. **stone_diff 重みの見直し**（対局観察→GA 再調整）
4. **PASS 処理の Python 互換化**（後回し可）

---

## MID_GAME 閾値 12→18 変更（depth-3 leaf 評価破綻対策）(2026-05-02)

### 発端

実機対局ログ（空き=19, depth-3）で AI が G2 を選択し Eval:200 を出力。
Human が H2 で応じると X:39 O:8 に激変。Eval の符号が完全に誤っていた。

### 根本原因

depth-3 のとき leaf_empty = root_empty - 3。root_empty=19 → leaf_empty=16。

leaf_empty=16 は旧 MID_GAME=12 の閾値では MID フェーズ。
MID フェーズ評価式 `pos_diff + mob×8 + stable×16 - stone_diff×4` が leaf で O:10, X:53 の場合:

| 項 | 値 | 問題 |
|---|---|---|
| `pos_diff` | **+550** | X の多数の内側石（負値 POS_WEIGHT）が O 側に加算 |
| `- stone_diff×4` = `-(-43×4)` | **+172** | 石数劣勢（負値 stone_diff）がペナルティ逆転でボーナスに |
| 合計 | **≈+600** | O が圧倒的に負けている局面なのに大正値 |

LATE フェーミュラなら: `-43 × 100 = -4300`（正しく壊滅評価）。

MID 式は 2 つの要因で石数大差局面に対し誤った評価を返す:
1. 負値 POS_WEIGHT テーブル使用時、石数が多い側の内側石が相手の pos_diff をかさ上げする
2. `-stone_diff×w` は石数劣勢（stone_diff < 0）をペナルティでなくボーナスに変換する

### 修正内容

`MID_GAME EQU 12` → `MID_GAME EQU 18`（RFCT120.ASM）  
`CP MID_GAME` を `EvalLeaf` の LATE 判定箇所に適用。  
`play_vs_ai.py` の `if empty < 12:` → `if empty < MID_GAME (=18):` に変更。

| root_empty | leaf_empty | 修正前 | 修正後 |
|---|---|---|---|
| 14〜17 | 11〜14 | MID/LATE混在 | **LATE** |
| 18〜20 | 15〜17 | **MID（誤）** | **LATE（正）** |
| 21〜24 | 18〜21 | MID | MID（境界） |
| 25〜（depth-2） | 23〜 | MID | MID（無影響）|

### EMPTY_CACHE 修正との関係

EMPTY_CACHE 修正（2026-05-02）を先行適用済み。  
leaf で `CountEmpty` を呼ぶため leaf の実際の空きマス数でフェーズ判定される。  
→ MID_GAME=18 と組み合わせることで root_empty=19 の leaf_empty=16 が正しく LATE に判定される。

---

## depth-3 悪手選択の原因調査 (2026-05-02)

### 発端

MID_GAME=18・EMPTY_CACHE 修正後の実機対局で、X:19 O:31（空き=14）の局面で AI が G7（X マス）を選択、評価値 Eval:-1140。その後 O が H8（コーナー）を取得し、次手でも AI が G8 を選択、評価値 -1410。ユーザーから「打つ手がおかしすぎる」との指摘。

### NegaMax α-β コードの精査結果

コード全体を精査した結果、**コードバグは発見されなかった**。

確認した項目:
- `NM_ALPHA_TBL[depth]` 初期値: depth=0 → NM_SCORE_MIN(-8192)、depth>=1 → NM_AIset_ALPHA（α下限継承）。正しい。
- エントリー β-cutoff: `alpha[depth] + alpha[depth-1] >= 0` で発火。数学的に正しい。
- 通常 β-cutoff: `alpha[depth] + alpha_parent >= 0` で発火。正しい。
- NM_CALL_DEPTH のインクリメント/デクリメント: CALL前後で対称。正しい。
- EvalLeaf(D=side) の符号: leaf で HumSide 視点→negamax が negate→AiSide 視点に変換。正しい。
- 比較演算 `SBC HL,DE; JP M`: LATE 評価の最大スコア ≈ ±6640、減算後最大 ±13280 < 32767。オーバーフローなし。
- NM_TOTAL_DEPTH=2（depth-3 の場合）: AIset ply0 + depth=0(OPP ply1) + depth=1(AI ply2) + leaf。正しく3手先探索。

### G7 選択が「正しい」理由

G7 はコーナー H8 に対角に隣接する X マス（POS_ORDER_D3 の末尾）。  
POS_ORDER_D3 ではコーナー(weight=157)が先頭で試される。A1 等のコーナーが G7 より先に探索される。

**G7 が選ばれた = G7 より先に試された全合法手（コーナー含む）が G7 の -1140 より悪かった（-1141 以下）。**

この時点で A1 が合法手だった可能性は低い（ユーザーが A1 を打ったのは AI の G8 の 2 手後であり、その間の着手で挟み込み経路が生まれたと推定）。

### 本質的問題: LATE 式の重み設定

| 評価項目 | 重み | 備考 |
|---|---|---|
| stone_diff | × 100 | 支配的 |
| stable_diff | × 30 | コーナー 1 個 = たったの 30 点 |

G7 で 3 枚フリップすると AI は石数差で +3 → stone_diff が 3 改善 → +300 点。  
その後 O が H8 を取り stable +1 → AI は -30 点。  
**純利益: +300 - 30 = +270 点相当** → G7 は短期石数改善で "得" と判断される。

depth-3 の探索は H8 コーナー奪取を「見て」いる。しかし stone_diff×100 の支配力が stable×30 を圧倒するため、コーナーを明け渡しても石数を取る選択が最善に見える。

### 改善候補

```
現行: stone_diff × 100 + stable × 30
提案: stone_diff × 100 + stable × 60   ← stable重みを2倍に
```

stable 重みを 60 にするとコーナー 1 個 = 60 点 vs 石 3 枚フリップ = 300 点で、依然 stone_diff が勝るが差は縮まる。  
stable ×100 相当（= stone_diff と等価）にすると「コーナー 1 個 = 1 石差」として評価でき、戦略的に妥当な選択に近づく可能性がある。

TODO #28（stone_diff ペナルティ重みの見直し）と組み合わせて play_vs_ai.py で A/B テストし、GA 再調整を検討する。
