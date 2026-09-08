# アーキテクチャ・現行仕様

版の系譜、実装済み機能、評価式、位置重みテーブル、実測値、ROM化構成。
入口は [CLAUDE.md](../CLAUDE.md)。

## 現行ファイル構成

```
RVS8_GREEDY.ASM
  └─ RVS8_POSWEIGHT.ASM
       └─ RVS8_MINIMAX1.ASM
            └─ RVS8_MINIMAX1_16.ASM
                 └─ RVS8_MM1_MOB.ASM
                      └─ RVS8_PIOSW.ASM  ← 実機確認済み
                           └─ RVS8_MM2_AB.ASM  ← 実機確認済み
                                └─ MM2_AB_EG.ASM  ← 終盤完全読み（凍結中）
                                     └─ MM2_AB_MO.ASM  ← ムーブオーダリング
                                          └─ MM2_AB_EV.ASM  ← 評価関数改善
                                               └─ MM2_AB_D3.ASM  ← 大会用確定版
                                                    ├─ MM2_AB_ROM.ASM  ← ROM起動版（保留中）
                                                    └─ MM2_AB_BCUT.ASM ← β-cutoff実装版（実機確認済み・リファクタリング元）
                                                         └─ RFCT000.ASM ← 変数名・ラベル名・関数名整理（ロジック変更なし）
                                                              └─ RFCT001.ASM ← カットオフ定数値見直し（MOB_STABLE_CAP フェーズ別）
                                                                   └─ RFCT002.ASM ← AMM_BETA_SKIP 閾値修正 + フェーズ別分岐
                                                                        └─ RFCT003.ASM ← D3_THRESHOLD 調整・総合テスト版（実機確認済み）
                                                                             └─ RFCT100.ASM ← AIコア再構築（再帰negamax + 符号付きPOS_WEIGHT）
                                                                                  └─ RFCT120.ASM ← POS_WEIGHTランタイム切替 + β-cutoff（安定版・実機確認済み）
                                                                                       └─ RFCT150.ASM ← 終盤完全読み有効化（★大会出場版・フリーズ調査中）
                                                                                            └─ RF150ROM.ASM ← ROM（27C256）起動対応版（実機確認済み）
```

## 実装済み機能 (RFCT150.ASM) ← 大会出場版

- 再帰 negamax + 完全α-β（α下限継承 + エントリーβ-cutoff）
- depth-2/3 ランタイム切替（空き < 20 → depth-3、D3_THRESHOLD=20）
- **終盤完全読み**（AIset_EG / SearchFull、空き ≤ 4 で発動、ENDGAME_THRESHOLD=4）
- POS_WEIGHT depth別ランタイム切替（depth-2: GA_D2S / depth-3: GA_D2S）
- PASS処理: 合法手なし→相手番を depth 消費せず再帰（Python互換）
- 先後手選択: SW0=先手(黒), SW2=後手(白)、SIOA '1'/'2' でも選択可
- PIOB スイッチ入力（SW0-SW4, Mode3）
- PIOA D7 → Pico GPIO15 AI処理時間計測
- 評価値表示（TeraTerm / Pico LCD 5行目）
- PB5 押下 → 投了・リトライ
- 処理時間: 先手・後手ともに **4秒以下**（depth-3）

## フォールバック版 RFCT120.ASM（安全に動く版）

RFCT150 が実機で不安定なときに差し替える安全版は **`asm/RFCT120.ASM`**。
DEVLOG 2026-05-03「RFCT120 実機確認・大会出場候補確定」で大会出場候補に昇格した版で、
先手・後手とも処理時間 4 秒以下を実機確認済み。RFCT150 はこの RFCT120 をコピーして
`SearchFull` / `AIset_EG` を有効化したものなので、**RFCT150 のフリーズ箇所
（`SF_OLOOP`）は RFCT120 には存在しない**（`grep SF_OLOOP` = 0 件）。

| 項目 | RFCT120（安全版） | RFCT150（大会版） |
|---|---|---|
| 終盤完全読み | **無効** (`ENDGAME_THRESHOLD EQU 0`) | 空き ≤ 4 で発動 (`EQU 4`) |
| POS_WEIGHT depth-3 | GA_RFCT100 | GA_D2S |
| depth 切替 | 空き < 20 → depth-3 | 同左 |
| ROM（27C256）起動版 | **なし** | `RF150ROM.ASM` |
| 実機確認 | 済（2026-05-03） | 済。ただしフリーズ修正後は未確認 |

`ENDGAME_THRESHOLD EQU 0` により `CALL AIset_EG` の到達条件が「空き ≤ 0」となるため、
RFCT120 では終盤完全読みは事実上呼ばれない。

`asm/RFCT120_CP.ASM` は RFCT120.ASM の作業用コピー（2026-09-08 作成、アセンブル・動作確認とも未実施）。
原本との差分は `LINE_MAX EQU 20` へのコメント追記1行のみ。

**注意: RFCT120 には ROM 起動版がない。** `RF150ROM.ASM` は RFCT150 由来なので、
EPROM 単独起動でフォールバックしたい場合は RFCT120 の ROM 版を別途作る必要がある。
モニタ ROM 経由なら `RFCT120.hex`（2026-05-03 ビルド）をそのままロードできる。

## 評価式 (RFCT150 EvalLeaf)

```
EARLY (空き≥44): pos_diff + mob_diff×4 + stable_diff×4  - stone_diff×4
MID   (空き≥18): pos_diff + mob_diff×4 + stable_diff×8  - stone_diff×2
LATE  (空き<18): (stone_diff + stable_diff) × 100

pos_diff = Σ(自石:POS_WEIGHT) - Σ(相手石:POS_WEIGHT)  (符号付きテーブル)
```

## POS_WEIGHT テーブル（GA_D2S・depth-2/3 共用）

```
;       A    B    C    D    E    F    G    H
DEFB  114,  -5, -16,  -7,  -7, -16,  -5, 114  ; 1
DEFB   -5, -54, -16,   7,   7, -16, -54,  -5  ; 2
DEFB  -16, -16,   6,   2,   2,   6, -16, -16  ; 3
DEFB   -7,   7,   2, -12, -12,   2,   7,  -7  ; 4/5
DEFB  -16, -16,   6,   2,   2,   6, -16, -16  ; 6
DEFB   -5, -54, -16,   7,   7, -16, -54,  -5  ; 7
DEFB  114,  -5, -16,  -7,  -7, -16,  -5, 114  ; 8

角=114, Xマス=-54, 符号付き（負値あり）
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

### AT28C256 ピン非互換問題（2026-04-23 判明・却下）

27C256 と AT28C256 はピン配置が非互換のため Super AKI-80 ソケットに直挿し不可。
ピン改造は作業コストが高いため **AT28C256 は使用しない方針に確定**。

**→ 27C256 EPROM（UV消去型）を使用する。イレーサー・ライター手元にあり。**
