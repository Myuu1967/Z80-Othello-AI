# Z80 オセロ AI プロジェクト (RVS8)

## 実コードの場所
`F:\oke\Z80\ASM\オセロ\` 以下を絶対パスで参照・編集する

## ハードウェア仕様

| 項目 | 値 |
|---|---|
| CPU | Z80 (Super AKI-80) |
| クロック | 10MHz (1T = 0.1μs) |
| シリアル | SIOA: DAT=18H, CTL=19H |
| PIO | PIOA_CMD=0CH, PIOA_DATA=0DH |
| CTC | **利用不可**（Super AKI-80では動作しない） |

## 現行ファイル構成

```
RVS8_GREEDY.ASM
  └─ RVS8_POSWEIGHT.ASM
       └─ RVS8_MINIMAX1.ASM
            └─ RVS8_MINIMAX1_16.ASM
                 └─ RVS8_MM1_MOB.ASM  ← 【現行最新】
```

**作業対象は常に `F:\oke\Z80\ASM\オセロ\RVS8_MM1_MOB.ASM`**

## 評価式

```
mm_score = POS_WEIGHT[ai_pos]        (5〜120)
         + (255 - opp_best)          (相手抑制)
         + (ai_mob - opp_mob + 64)   (モビリティ差)
```

## 既知の注意事項

- `ApplyMove` は B,C を破壊 → **PUSH BC は ApplyMove より前**
- `CountMobility` は A を破壊 → **PUSH AF / POP AF 必須**
- CTC 使用不可 → 計測は Pico 外部計測システムを使用

## 計測システム

```
Z80 PIOA D7 ──→ Pico GPIO15 → measureTimeWithZ80.py
Z80 SIOA  ──┬──→ PC ターミナル
            └──→ Pico UART → LCD盤面描画（未完成）
```

## Gitコミット

- コミットメッセージ形式: `[ファイル名] 変更内容の概要`
- ビルド成果物（.err .hex .lin .lst .sym）はコミットしない

## 詳細履歴

`DEVLOG_RVS8.md`（このディレクトリ内）を参照
