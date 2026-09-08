# Z80 オセロ AI プロジェクト (RVS8)

Super AKI-80 (TMPZ84C015 / 10MHz) で動作するオセロ AI。Z80 アセンブラ実装。
第7回自作CPU大会 (2026-05-09) 出場作品。

## ドキュメント全体構成 ★最初に読む

このファイルは**入口**。日常的に必要な情報だけを置き、詳細は個別ファイルに分けている。

| ファイル | 記録している内容 | いつ読むか |
|---|---|---|
| **CLAUDE.md**（本ファイル） | 作業対象、開発フロー、ハード仕様、Git規約、現在の最優先タスク | 毎回 |
| [docs/PITFALLS.md](docs/PITFALLS.md) | 既知の注意事項（レジスタ破壊・オーバーフロー・インデックス計算の罠） | **アセンブラを書く前に必ず** |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 版の系譜、実装済み機能、評価式、POS_WEIGHT テーブル、処理時間実測値、ROM化構成 | 仕様を確認するとき |
| [docs/REFERENCE.md](docs/REFERENCE.md) | 関数リファレンス（入出力・破壊レジスタ）、RFCT000 命名規則 | 既存関数を呼ぶ・名前を決めるとき |
| [docs/TODO.md](docs/TODO.md) | TODO 一覧（消化済み含む） | 次の作業を決めるとき |
| [DEVLOG_RVS8.md](DEVLOG_RVS8.md) | 詳細な時系列の開発ログ（変更・実機計測・バグ調査・大会報告） | 経緯を追うとき／作業後に追記 |
| [README.md](README.md) | 公開用のプロジェクト概要 | 対外的な説明を書くとき |
| `README.local.md` | ローカル専用メモ（Git 管理外・非公開） | 些末なメモを書くとき |
| `asm/FLOW.md` | 制御フロー図。※ MM2_AB_EG 時点で更新停止、行番号は当てにしない | 参考程度 |

**記録の使い分け**: 経緯・実測値は DEVLOG に追記 → 確定した仕様・規約・TODO は
CLAUDE.md / docs 配下に反映。細かい内部メモは `README.local.md`（公開リポジトリには上げない）。

## 現在の状況（2026-09-08）

- **作業対象**: `asm/RFCT150.ASM`（大会出場版）／`asm/RF150ROM.ASM`（ROM起動版）
- **最優先**: 終盤完全読みのフリーズ修正（`SF_OLOOP` の `LD D,0` → `LD B,0`、commit 380ee94）の
  **実機動作確認が未実施**。空き4の局面で完全読みを発動させ、Pico GPIO15 で処理時間を計測する。
- 次点: `python/measure_eg_nodes.py` でノード数を実測し `SF_NODE_CAP` を決める（Z80側は未実装）
- 中期: 評価関数の質向上（次回大会 2026年秋〜冬予定）、自作4bit CPU の完成

## 実コードの場所
`F:\ClaudeCode\Z80-Othello\asm\` 以下を絶対パスで参照・編集する
（旧パス `F:\oke\Z80\ASM\オセロ\` は参照しない）

**現在の作業対象: `RFCT150.ASM` / `RF150ROM.ASM`**
- `RFCT150.ASM`: RFCT120 + 終盤完全読み（AIset_EG/SearchFull, ENDGAME_THRESHOLD=4）有効化版。第7回自作CPU大会（2026-05-09）に出場。終盤完全読み発動時のフリーズは 2026-09-03 に原因特定・修正済み（実機確認待ち）。
- `RF150ROM.ASM`: RFCT150 の ROM（27C256）起動対応版。ORG 0000H + InitSIOA/InitCTC3 + RAM変数分離。実機確認済み。
- `RFCT120.ASM`: 安定版フォールバック（終盤完全読みなし）。現状維持。
- `RFCT100.ASM`: 参照用・編集しない。

大会出場版: `F:\ClaudeCode\Z80-Othello\asm\RFCT150.ASM`（ROM版: `RF150ROM.ASM`）

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
| CPU | TMPZ84C015-BF10 (Super AKI-80) |
| 外部クロック | 約20MHz → CGC(1/2) → CPU/CTC: 10MHz (1T = 0.1μs) |
| シリアル | SIOA: DAT=18H, CTL=19H |
| PIOA | DATA=1CH, CMD=1DH（D7: 計測トリガ出力） |
| PIOB | DATA=1EH, CMD=1FH（SW0-SW4: スイッチ入力, Mode3） |
| CTC | **利用不可**（Super AKI-80では動作しない） |

## 計測システム

```
Z80 PIOA D7 ──→ Pico GPIO15 → measureTimeWithZ80.py
Z80 SIOA  ──┬──→ PC ターミナル
            └──→ Pico UART → LCD盤面描画（gameDisplay.py・動作確認済み）
```

## Gitコミット

- コミットメッセージ形式: `[ファイル名] 変更内容の概要`
- ビルド成果物（.err .hex .lin .lst .sym）はコミットしない
