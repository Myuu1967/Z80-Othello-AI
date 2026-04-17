# Z80 オセロ AI プロジェクト (RVS8)

## 実コードの場所
`F:\ClaudeCode\Z80-Othello\asm\` 以下を絶対パスで参照・編集する
（旧パス `F:\oke\Z80\ASM\オセロ\` は参照しない）

**現在の作業対象: `F:\ClaudeCode\Z80-Othello\asm\MM2_AB_EG.ASM`（アセンブル通過・実機確認中）**
ベースファイル: `F:\ClaudeCode\Z80-Othello\asm\RVS8_MM2_AB.ASM`

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

## POS_WEIGHT テーブル（改訂版）

```
;       A    B    C    D    E    F    G    H
DEFB  120,   5,  30,  25,  25,  30,   5, 120  ; 1
DEFB    5,   1,  15,  15,  15,  15,   1,   5  ; 2
DEFB   30,  15,  20,  20,  20,  20,  15,  30  ; 3
DEFB   25,  15,  20,  18,  18,  20,  15,  25  ; 4
DEFB   25,  15,  20,  18,  18,  20,  15,  25  ; 5
DEFB   30,  15,  20,  20,  20,  20,  15,  30  ; 6
DEFB    5,   1,  15,  15,  15,  15,   1,   5  ; 7
DEFB  120,   5,  30,  25,  25,  30,   5, 120  ; 8

角=120, Xマス=1(ほぼ禁止), Cマス=5, 辺中央=25-30
max score = 120 + 64 flips = 184 < 256 (byte-safe)
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

1. **MM2_AB_EG.ASM 実機確認・処理時間計測**（α-β 修正済み、実機ロード待ち）
2. 閾値調整（ENDGAME_THRESHOLD 現在=2、実機確認後に 4〜8 への拡張を検討）
3. ムーブオーダリング → depth-3 検討
4. PASS連続2回・DRAW の動作テスト
5. ROM ブート化（オセロ完成後）

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

## 詳細履歴

`DEVLOG_RVS8.md`（このディレクトリ内）を参照
