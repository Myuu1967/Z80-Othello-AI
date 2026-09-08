# 既知の注意事項（踏んだ罠の一覧）

レジスタ破壊・オーバーフロー・インデックス計算など、実際にバグの原因になった事項。
コードを触る前に目を通すこと。入口は [CLAUDE.md](../CLAUDE.md)。

## 既知の注意事項

- `ApplyMove` は B,C を破壊 → **PUSH BC は ApplyMove より前**
- `CountMobility` は A を破壊 → **PUSH AF / POP AF 必須**
- `CountAllFlips` は AF,BC,DE,HL,IX,IY を破壊 → 呼び出し元で PUSH BC / PUSH DE 必須
- CTC 使用不可 → 計測は Pico 外部計測システムを使用
- `OppBestScore_d2` 内側ループで D が上書きされる → OD2_COL 先頭で毎回 `LD A,(HumSide); LD D,A`
- `ADD HL,BC` でテーブルを引く前は **必ず `LD B,0`**（`LD D,0` と書き間違えると B にインデックスが残り、`+i*257` を読む。RFCT150 フリーズの原因）

## 既知の注意事項（MM2_AB_EG 追加分）

- `EG_DEPTH` は `AIset_EG` から呼ぶ際は **1** で初期化（0 は BOARD_SAVE1 衝突）
- α-β の -INF 初期値は **81H**（`NEG(80H) = 80H` オーバーフローの罠を避ける）
- `SF_ALPHA_TBL[0]` には `EG_BESTSCORE` を設定（固定 80H でなく AI ベストスコア）
- `LD r,(nn)` / `LD (nn),r` は A のみ有効（B,C 等は A 経由で代替）
- `IXL`/`IXH` はアセンブラ非対応 → D/E レジスタで代替
