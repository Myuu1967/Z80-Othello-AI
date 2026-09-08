# Z80 Othello AI

Super AKI-80（TMPZ84C015、Z80互換 / 10MHz）で動作するオセロAI  
Negamax + α-β枝刈り + 終盤完全読み を Z80アセンブリで実装

第7回「自作CPUを語る会」オセロ大会（2026-05-09）出場作品

---

## ハードウェア構成

| 項目 | 内容 |
|---|---|
| CPU | TMPZ84C015-BF10（Super AKI-80） |
| クロック | 約10MHz（外部 約20MHz → CGC 1/2分周） |
| シリアル | SIOA 9600bps（TeraTerm / Pico経由） |
| 表示 | Raspberry Pi Pico + LCD（MicroPython） |
| ROM起動版 | 27C256 EPROM（RF150ROM.ASM） |

## AI実装機能

- Negamax + 完全α-β枝刈り（α下限継承 + エントリーβ-cutoff）
- depth-2/3 ランタイム切替（空きマス < 20 → depth-3）
- 終盤完全読み（空きマス ≤ 4 で発動、AIset_EG / SearchFull）
- 遺伝的アルゴリズム（GA）による位置重みテーブル最適化
- フェーズ別評価（序盤 / 中盤 / 終盤）

## 評価式（大会出場版 RFCT150）

```
EARLY（空き ≥ 44）: pos_diff + mob_diff×4 + stable_diff×4  − stone_diff×4
MID  （空き ≥ 18）: pos_diff + mob_diff×4 + stable_diff×8  − stone_diff×2
LATE （空き < 18）: （stone_diff + stable_diff）× 100
```

## ファイル構成

### Z80 アセンブリ（asm/）

| ファイル | 内容 |
|---|---|
| `RFCT150.ASM` | **★大会出場版**（終盤完全読み有効） |
| `RF150ROM.ASM` | ROM（27C256）起動対応版 |
| `RFCT120.ASM` | 安定版フォールバック（終盤完全読みなし） |
| `RFCT100.ASM` | 再帰negamax移行版（参照用） |
| `RFCT000〜003.ASM` | リファクタリング段階版 |
| `MM2_AB_*.ASM` | α-β枝刈り中間版（開発履歴） |
| `RVS8_*.ASM` | 初期版（Greedy → depth-1 → depth-2） |

### Python スクリプト（python/）

| ファイル | 内容 |
|---|---|
| `play_vs_ai.py` | 人 vs AI 対戦 GUI（tkinter） |
| `othello_mm3_ab.py` | Python AI コア（Z80実装の参照実装） |
| `optimize_weights.py` | 遺伝的アルゴリズムによる位置重みテーブル最適化 |
| `benchmark_vs.py` | AI同士ベンチマーク |

### Pico / MicroPython（othelloGUI/）

| ファイル | 内容 |
|---|---|
| `gameDisplay.py` | **メイン** UART受信 + LCD盤面描画 |
| `measureTimeWithZ80.py` | PIOA D7 → GPIO15 処理時間外部計測 |

## 処理時間実測値

| バージョン | 最大処理時間 |
|---|---|
| depth-1 | ≈ 700ms |
| depth-2（α-β あり） | 2秒以下 |
| depth-2/3 切替（RFCT150） | **4秒以下**（大会制限時間クリア） |

## 開発ログ

詳細な開発経緯・バグ記録は [DEVLOG_RVS8.md](DEVLOG_RVS8.md) を参照。

## 関連記事

- [はてなブログ 開発記事（前編）](https://tanuki-bayashin.hatenablog.com/entry/2026/02/23/172618)

## 開発環境

- アセンブラ: Z80 アセンブラ（Super AKI-80 付属）
- Python: 3.x（tkinter、AI プロトタイプ・GA最適化）
- MicroPython: Raspberry Pi Pico 向け

## ライセンス

MIT License — 詳細は [LICENSE](LICENSE) を参照
