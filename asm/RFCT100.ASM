; =========================================================
; Super AKI-80 8x8 Othello  [RFCT100: NegaMax 再帰 AI コア再構築]
;                            [符号付き POS_WEIGHT (V2ベース)]
;                            [Player input: PIOB switch SW0-SW4]
; ---------------------------------------------------------
; Target : Z80 (Super AKI-80)
; Serial : SIOA  DAT=18h  CTL=19h  (SIO init by monitor)
; PIO-B  : CMD=1Fh  DATA=1Eh  SW0:PB0(Lt) SW1:PB1(Rt) SW2:PB2(Up) SW3:PB3(Dn) SW4:PB4(Enter)
;
; Board model:
;   0 = EMPTY, 1 = BLACK('X'), 2 = WHITE('O')
;
; Features:
;   - Board print (8x8)
;   - Player input: PIOB SW0-SW4
;   - AI move: NegaMax 再帰 α-β (符号付き 16bit スコア)
;       AIset:    ルートループ + 最善手着手
;       NegaMax:  再帰 α-β (PASS・terminal 対応)
;       EvalLeaf: 葉ノード評価 (pos_diff + mob + stable)
;   - EndGame perfect read (SearchFull, 凍結中)
;       BOARD_EG_SAVES: depth 2..9 用 (8スロット x 64B = 512B)
;   - Legal check + flipping (ApplyMove)
;   - Counts display "X:nn O:nn"
;   - Game end: board full OR 2 consecutive passes
;
; Score type: 符号付き 16bit, 手番プレイヤー視点 (正=有利)
;   pos_diff:    Sigma(POS_WEIGHT[AI石]) - Sigma(POS_WEIGHT[OPP石])
;   mob_diff:    (AI合法手数 - OPP合法手数) x mob_w
;   stable_diff: (AI安定石 - OPP安定石) x stable_w
;   NM_SCORE_MIN = 0F000H (-4096): 初期 alpha 値 (mob/stable込み max|score|=2608 をカバー)
;
; α-β 枝刈り:
;   NM_ALPHA_TBL[d] = depth d の現在ベスト (alpha)
;   beta[d] = -NM_ALPHA_TBL[d-1]  (親の alpha を反転)
;   cutoff: NM_ALPHA_TBL[d] >= -NM_ALPHA_TBL[d-1]
;
; RFCT100 系譜: RFCT003.ASM からの分岐 (RFCT00x とは別ライン)
;
; Apr 26th, 2026 RFCT100 Step1/7: ファイル土台作成
;   - 旧AIコア削除 (Ply2Best_D2/D3, Ply3Best, LeafEval, AIset)
;   - 変数置換: NM_TOTAL_DEPTH/NM_CALL_DEPTH/NM_ALPHA_TBL 等追加
;   - POS_WEIGHT → 符号付き V2 値
;   - POS_ORDER  → V2 重み降順に更新
; Apr 27th, 2026 RFCT100 Step6/7: AIset depth-2/3 切替 + 重みテーブル D2/D3 切替
;   - NM_SCORE_MIN: -512 → -2048 (GA_D2signed 最大|score|=1168 に対応)
;   - POS_WEIGHT_D3 / POS_WEIGHT_D2 両テーブル追加、EQU エイリアスで切替
; Apr 27th, 2026 RFCT100 Step7/7: EvalLeaf mob/stable 追加
;   - mob_diff × mob_w / stable_diff × stable_w をフェーズ別に加算
;   - EARLY(>=44): mob×3,  stable×8   MID(>=12): mob×3, stable×12  LATE(<12): EL_LATE(stone_diff×100+stable×30)
;   - POS_ORDER_D3  / POS_ORDER_D2  両テーブル追加、EQU エイリアスで切替
;   - AIset: depth-1 固定 → 空きマス数 < D3_THRESHOLD で depth-3 / else depth-2
; =========================================================

        ORG 8000H
        JP  START


; =========================================================
; I/O ports (SIOA)
; =========================================================
SIOA_DAT        EQU 18H
SIOA_CTL        EQU 19H

; =========================================================
; PIO
; =========================================================
PIOA_DATA       EQU 1CH
PIOA_CMD        EQU 1DH
PIOB_DATA       EQU 1EH
PIOB_CMD        EQU 1FH

; ---- PIOB スイッチビット定義 (アクティブLOW) ----
SW_LEFT         EQU 01H     ; SW0 PB0 : 左
SW_RIGHT        EQU 02H     ; SW1 PB1 : 右
SW_UP           EQU 04H     ; SW2 PB2 : 上
SW_DOWN         EQU 08H     ; SW3 PB3 : 下
SW_ENTER        EQU 10H     ; SW4 PB4 : 確定
SW_ABORT        EQU 20H     ; SW5 PB5 : 中断

; =========================================================
; ASCII / control chars
; =========================================================
CR              EQU 0DH
LF              EQU 0AH
BS              EQU 08H
DEL             EQU 7FH
BEL             EQU 07H


; =========================================================
; Game constants
; =========================================================
BOARD_W         EQU 8
BOARD_H         EQU 8
BOARD_BYTES     EQU BOARD_W*BOARD_H

EMPTY           EQU 0
BLACK           EQU 1
WHITE           EQU 2

DIR_CNT         EQU 8

BUF_MAX         EQU 64
LINE_MAX        EQU 20

; [CONST] 閾値・ゲーム定数 --------------------------------
ENDGAME_THRESHOLD  EQU 0    ; 終盤完全読み無効

; フェーズ閾値 (CountEmpty の値で判定)
EARLY_GAME  EQU 44          ; 空き >= 44: 序盤
MID_GAME    EQU 12          ; 空き >= 12: 中盤、else: 終盤

; depth切り替え閾値
D3_THRESHOLD EQU 20         ; 空き < 20 → depth-3 / 空き >= 20 → depth-2

; Ply2Best β-cutoff: mob+stable 最大値 (フェーズ別)
;   mob_diff+64 max ≈ 96 (AI約32手 OPP=0), stable_diff+8 max ≈ 24 (AI=16石 OPP=0)
MOB_STABLE_CAP_EARLY EQU 1872   ; 96×12 + 24×30 (序盤: mob_w=12, stable_w=30)
MOB_STABLE_CAP_MID   EQU 1968   ; 96×8  + 24×50 (中盤: mob_w=8,  stable_w=50)
MOB_STABLE_CAP_LATE  EQU 1104   ; 96×4  + 24×30 (終盤: mob_w=4,  stable_w=30)
OBS_SCORE_MAX        EQU  130   ; POS_WEIGHT_MAX(66) + FLIPS_MAX(64)

; NegaMax スコア定数
NM_SCORE_MIN    EQU  0E000H ; -8192 (LATE: stone_diff×100+stable×30, max|score|≈7020, 7020-(-8192)=15212<32767)


; =========================================================
; Strings (0-terminated)
; =========================================================
COL_HEADER:     DEFM "  A B C D E F G H",0
MSG_NEWLINE:    DEFM CR,LF,0

MSG_PROMPT:     DEFM "Your move (A1-H8) > ",0
MSG_BADFMT:     DEFM CR,LF,"Bad input. Use A1-H8.",CR,LF,0
MSG_ILLEGAL:    DEFM CR,LF,"NG (illegal move).",CR,LF,0
MSG_ILLEGAL2:   DEFM CR,LF,"NG2 (illegal move).",CR,LF,0

; ---- スイッチ入力用メッセージ ----
MSG_SWGUIDE:    DEFM "SW:Up/Dn/Lt/Rt=0-3 Ent=4",CR,LF,0
MSG_SWPOS:      DEFM "Move: ",0

MSG_GAMEOVER:   DEFM CR,LF,"GAME OVER",CR,LF,0

MsgChooseOrder: DEFM "Choose: SW0=1st(X) SW2=2nd(O)",CR,LF,0
MsgAiFirst:     DEFM "AI goes first. You are WHITE (O).",CR,LF,0
MsgHumanFirst:  DEFM "You go first. You are BLACK (X).",CR,LF,0

MSG_AI_PASS:    DEFM "AI PASS",CR,LF,0
MSG_PL_PASS:    DEFM "YOU PASS",CR,LF,0

MSG_COUNTS:     DEFM "X:",0
MSG_SPACEO:     DEFM " O:",0

MSG_WIN_X:      DEFM "BLACK(X) wins",0
MSG_WIN_O:      DEFM "WHITE(O) wins",0
MSG_DRAW:       DEFM "Draw",0

AImoveMSG:      DEFM "AI moves to ",0
AImovePOS:      DEFB 'A','1',0
MSG_EVAL:       DEFM "Eval:",0

MSG_RETRYQ:     DEFM CR,LF,"r:Retry or q:Quit ? ",0
MSG_BYE:        DEFM CR,LF,"Bye.",CR,LF,0

MSG_PASSEND:    DEFM CR,LF,"Game ended by consecutive passes.",CR,LF,0
MSG_ABORT:      DEFM CR,LF,"Game aborted.",CR,LF,0

; =========================================================
; Tables
; =========================================================
; index: 0=EMPTY, 1=BLACK, 2=WHITE -> printable char
STONE_CHAR:
        DEFB '.', 'X', 'O'

; ---------------------------------------------------------
; 位置重みテーブル  (各64 bytes, row-major 8x8)
;   符号付きバイト。DEFB の負値はアセンブラが2の補数に変換する。
;   sign-ext して 16bit 加減算に使う。
;
; 切替: 下部の EQU エイリアスを _D2 or _D3 に変更するだけ。
; ---------------------------------------------------------

; --- GA_D3優勝テーブル (depth-3 AI同士 30世代, 2026-04-26) ---
;   corner=66, edge_ctr=44, inner2=23, near_x=22, inner=10
;   inner_edge=1, edge_near=-1, center=-29, c_sq=-32, x_sq=-45
POS_WEIGHT_D3:
        ;       A    B    C    D    E    F    G    H
        DEFB   66, -32,  -1,  44,  44,  -1, -32,  66  ; 1
        DEFB  -32, -45,  22,   1,   1,  22, -45, -32  ; 2
        DEFB   -1,  22,  10,  23,  23,  10,  22,  -1  ; 3
        DEFB   44,   1,  23, -29, -29,  23,   1,  44  ; 4
        DEFB   44,   1,  23, -29, -29,  23,   1,  44  ; 5
        DEFB   -1,  22,  10,  23,  23,  10,  22,  -1  ; 6
        DEFB  -32, -45,  22,   1,   1,  22, -45, -32  ; 7
        DEFB   66, -32,  -1,  44,  44,  -1, -32,  66  ; 8

; --- GA_D2S優勝テーブル (optimize_weights_rfct100_v2.py 1位, 2026-04-29) ---
;   corner=114, x_sq=-54, c_sq=-5, near_x=-16, edge_near=-16, edge_ctr=-7
;   inner_edge=7, inner=6, inner2=2, center=-12
POS_WEIGHT_D2:
        ;       A    B    C    D    E    F    G    H
        DEFB  114,  -5, -16,  -7,  -7, -16,  -5, 114  ; 1
        DEFB   -5, -54, -16,   7,   7, -16, -54,  -5  ; 2
        DEFB  -16, -16,   6,   2,   2,   6, -16, -16  ; 3
        DEFB   -7,   7,   2, -12, -12,   2,   7,  -7  ; 4
        DEFB   -7,   7,   2, -12, -12,   2,   7,  -7  ; 5
        DEFB  -16, -16,   6,   2,   2,   6, -16, -16  ; 6
        DEFB   -5, -54, -16,   7,   7, -16, -54,  -5  ; 7
        DEFB  114,  -5, -16,  -7,  -7, -16,  -5, 114  ; 8

; --- ムーブオーダリング用: POS_WEIGHT降順のマスoffset一覧 (各64バイト) ---
; offset = row*8 + col  (row=0..7, col=0..7)

; GA_D3 重み降順: 66,44,23,22,10,1,-1,-29,-32,-45
POS_ORDER_D3:
        ; weight=66: corner
        DEFB  0,  7, 56, 63
        ; weight=44: edge_ctr (D1/A4 etc.)
        DEFB  3,  4, 24, 31, 32, 39, 59, 60
        ; weight=23: inner2 (D3/C4 etc.)
        DEFB 19, 20, 26, 29, 34, 37, 43, 44
        ; weight=22: near_x (C2/B3 etc.)
        DEFB 10, 13, 17, 22, 41, 46, 50, 53
        ; weight=10: inner (C3 etc.)
        DEFB 18, 21, 42, 45
        ; weight=1: inner_edge (D2/B4 etc.)
        DEFB 11, 12, 25, 30, 33, 38, 51, 52
        ; weight=-1: edge_near (C1/A3 etc.)
        DEFB  2,  5, 16, 23, 40, 47, 58, 61
        ; weight=-29: center (D4 etc.)
        DEFB 27, 28, 35, 36
        ; weight=-32: c_sq (B1/A2 etc.)
        DEFB  1,  6,  8, 15, 48, 55, 57, 62
        ; weight=-45: x_sq (B2/G2 etc.)
        DEFB  9, 14, 49, 54

; GA_D2S優勝 重み降順: 114,7,6,2,-5,-7,-12,-16,-54
POS_ORDER_D2:
        ; weight=114: corner
        DEFB  0,  7, 56, 63
        ; weight=7: inner_edge (D2/E2/B4/G4 etc.)
        DEFB 11, 12, 25, 30, 33, 38, 51, 52
        ; weight=6: inner (C3/F3/C6/F6)
        DEFB 18, 21, 42, 45
        ; weight=2: inner2 (D3/E3/C4/F4 etc.)
        DEFB 19, 20, 26, 29, 34, 37, 43, 44
        ; weight=-5: c_sq (B1/G1/A2/H2 etc.)
        DEFB  1,  6,  8, 15, 48, 55, 57, 62
        ; weight=-7: edge_ctr (D1/E1/A4/H4 etc.)
        DEFB  3,  4, 24, 31, 32, 39, 59, 60
        ; weight=-12: center (D4/E4/D5/E5)
        DEFB 27, 28, 35, 36
        ; weight=-16: near_x+edge_near (C2/F2/B3/G3 + C1/F1/A3/H3 etc.)
        DEFB 10, 13, 17, 22, 41, 46, 50, 53
        DEFB  2,  5, 16, 23, 40, 47, 58, 61
        ; weight=-54: x_sq (B2/G2/B7/G7)
        DEFB  9, 14, 49, 54

; --- D2/D3 切替エイリアス: 以下の1行を変えるだけで切替 ---
POS_WEIGHT EQU POS_WEIGHT_D2   ; → _D3 で GA_D3テーブルに切替
POS_ORDER  EQU POS_ORDER_D2    ; → _D3 で GA_D3テーブルに切替

; [WEIGHT] 安定石コーナーテーブル (3バイト x 4コーナー)
; 各エントリ: offset, dc(列方向 +1/FFH), dr(行方向 +1/FFH)
CS_CORNER_TBL:
        DEFB  0, 01H, 01H   ; A1: dc=+1(右), dr=+1(下)
        DEFB  7, 0FFH,01H   ; H1: dc=-1(左), dr=+1(下)
        DEFB 56, 01H, 0FFH  ; A8: dc=+1(右), dr=-1(上)
        DEFB 63, 0FFH,0FFH  ; H8: dc=-1(左), dr=-1(上)

DIR_DR:
        DEFB -1,-1,-1, 0,0, 1,1,1
DIR_DC:
        DEFB -1, 0, 1,-1,1,-1,0,1


; =========================================================
; Board (current state)
; =========================================================
BOARD:
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,WHITE,BLACK,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,BLACK,WHITE,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY

BOARD_INIT:
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,WHITE,BLACK,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,BLACK,WHITE,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY

; ---------------------------------------------------------
; BOARD_SAVE1/2/3  minimax用 盤面バックアップ (各64バイト)
;   BOARD_SAVE1: ply1 AIset 外ループ用
;   BOARD_SAVE2: ply2 Ply2Best_D3 外ループ用
;   BOARD_SAVE3: ply3 Ply3Best ループ用  ← depth-3 新規
; ---------------------------------------------------------
BOARD_SAVE1:
        DEFS BOARD_BYTES
BOARD_SAVE2:
        DEFS BOARD_BYTES
BOARD_SAVE3:
        DEFS BOARD_BYTES

; ---------------------------------------------------------
; BOARD_EG_SAVES  終盤完全読み用 (EG_DEPTH 2..9, 各64バイト)
;   EG_GetSaveAddr で depth -> アドレスを計算して使用
; ---------------------------------------------------------
BOARD_EG_SAVES:
        DEFS BOARD_BYTES * 8    ; 512バイト

; =========================================================
; Variables / Work area
; =========================================================
RXBUF:          DEFS BUF_MAX

AiSide:         DEFB 0
HumSide:        DEFB 0
TurnSide:       DEFB 0

PassStreak:     DEFB 0          ; consecutive passes 0..2

; ---- Work for IsLegalMove / TryDirCount / FlipDirN ----
WORK_PLAYER:    DEFB 0
WORK_ROW:       DEFB 0
WORK_COL:       DEFB 0

TD_R:           DEFB 0
TD_C:           DEFB 0
TD_OPP:         DEFB 0
TD_DR:          DEFB 0
TD_DC:          DEFB 0
TD_COUNT:       DEFB 0
TD_N:           DEFB 0

; ---- ApplyMove work ----
AM_DIDFLIP:     DEFB 0

; ---- スイッチ入力カーソル ----
PLR_COL:        DEFB 0      ; 列 0-7 (A-H)
PLR_ROW:        DEFB 0      ; 行 0-7 (1-8)

; ---- NegaMax AI work (RFCT100) ----
NM_TOTAL_DEPTH: DEFB 0          ; 総探索深さ (2 or 3)
NM_CALL_DEPTH:  DEFB 0          ; 現在の再帰深さ (0=AIset直下)
NM_ALPHA_TBL:   DEFS 8          ; alpha[depth] 符号付き16bit x 4 (depth 0..3)
NM_HAS_MOVE:    DEFS 4          ; 合法手発見フラグ (depth 0..3, 0=未発見 / 1=発見)
NM_IDX_TBL:     DEFS 4          ; ループインデックス per depth (0..3)
NM_SIDE_TBL:    DEFS 4          ; 手番 side per depth (0..3)
NM_ROOT_SCORE:  DEFW 0          ; AIset: 符号付き16bit ルートベストスコア
NM_ROOT_POS:    DEFB 0FFH       ; AIset: 最善手 offset (FFH=未発見)
EV_POS_DIFF:    DEFW 0          ; EvalLeaf: pos_diff 作業用 (符号付き16bit)
EV_SIDE:        DEFB 0          ; EvalLeaf: 評価対象 side
AI_MOB_COUNT:   DEFB 0          ; CountMobility: AI合法手数

; ---- CountStable work area ----
CS_SIDE:        DEFB 0          ; CountStable: 対象サイド
CS_COUNT:       DEFB 0          ; CountStable: 安定石数作業用
CS_OFF:         DEFB 0          ; CountStable: 現在のコーナーoffset
CS_DC:          DEFB 0          ; CountStable: 行方向 (+1 or FFH=-1)
CS_DR:          DEFB 0          ; CountStable: 列方向 (+1 or FFH=-1)
AI_STABLE:      DEFB 0          ; AIの安定石数
OPP_STABLE:     DEFB 0          ; 相手の安定石数

; ---- フェーズ管理 ----
GAME_PHASE:     DEFB 0      ; 0=序盤 1=中盤 2=終盤 (AIset先頭で設定)
EMPTY_CACHE:    DEFB 0      ; AIset先頭でCountEmptyの結果を保存
AS_IDX:         DEFB 0          ; AIset: POS_ORDER ループインデックス (0..63)
AS_OFFSET:      DEFB 0          ; AIset: 現在の着手 offset (一時保存)

; ---- EndGame 完全読み用 ----
EG_DEPTH:       DEFB 0          ; SearchFull 再帰深さ (0-based)
EG_BESTSCORE:   DEFB 0          ; AIset_EG ベストスコア (符号付き -64..+64)
EG_BESTROW:     DEFB 0
EG_BESTCOL:     DEFB 0
EG_ALPHA:       DEFB 0          ; α値 (未使用, 予約)
SF_SIDE_TMP:    DEFB 0          ; SearchFull 内 side 一時保存
SF_ALPHA_TBL:   DEFS 10         ; α-β: depth別 alpha値 (符号付き byte, depth 0..9)


; =========================================================
; Main entry / game loop
; =========================================================

START:
        LD   SP,0FFF0H
        DI                      ; SIO init is assumed done by monitor

        CALL InitPIOB           ; PIOB: SW0-SW4 入力モード

        CALL PrintBoard
        CALL DecideFirstTurn

MAIN_LOOP:
        ; PB5 中断チェック (ターン間)
        IN   A,(PIOB_DATA)
        CPL
        BIT  5,A
        JR   Z,ML_NO_ABORT
        CALL Debounce
        IN   A,(PIOB_DATA)
        CPL
        BIT  5,A
        JP   NZ,GAME_ABORTED
ML_NO_ABORT:
        CALL DoTurn
        OR   A
        JP   NZ,GameOver        ; A=1 => end by consecutive passes

        CALL PrintBoard
        CALL PrintCounts

        CALL IsBoardFull
        OR   A
        JP   NZ,GameOver

        JP   MAIN_LOOP


; =========================================================
; Game aborted (PB5 押下による中断)
; =========================================================
GAME_ABORTED:
        LD   SP,0FFF0H          ; 積みっぱなしの戻りアドレスをクリア
        LD   DE,MSG_ABORT
        CALL PrintString
        JP   GO_ASK


; =========================================================
; Game over
; =========================================================
GameOver:
        LD   DE,MSG_GAMEOVER
        CALL PrintString
        CALL ShowWinner

GO_ASK:
        LD   DE,MSG_RETRYQ
        CALL PrintString

GO_WAIT:
        ; SIOA: 受信データあるか確認 (ノンブロッキング)
        XOR  A
        OUT  (SIOA_CTL),A
        IN   A,(SIOA_CTL)
        BIT  0,A                ; RDRF=1?
        JR   NZ,GO_SIOA

        ; PIOB: PB0(bit0)=r / PB2(bit2)=q 確認
        IN   A,(PIOB_DATA)
        CPL
        AND  05H                ; bit0=PB0, bit2=PB2
        JR   Z,GO_WAIT          ; 何も押されていない

        PUSH AF
        CALL Debounce
        POP  AF
        IN   A,(PIOB_DATA)
        CPL
        AND  05H
        JR   Z,GO_WAIT          ; チャタリング

        ; PB0=1 → 'r'、PB2=1 → 'q'
        BIT  0,A
        LD   A,'r'
        JR   NZ,GO_SW_ECHO
        LD   A,'q'
GO_SW_ECHO:
        PUSH AF
GO_SW_REL:
        CALL Debounce
        IN   A,(PIOB_DATA)
        CPL
        AND  05H
        JR   NZ,GO_SW_REL       ; 離し待ち
        POP  AF
        CALL PutChar            ; エコー
        JR   GO_CHK             ; 既に小文字なのでそのままチェック

GO_SIOA:
        IN   A,(SIOA_DAT)
        CALL PutChar
        CP   'A'
        JR   C,GO_CHK
        CP   'Z'+1
        JR   NC,GO_CHK
        ADD  A,20H              ; 大文字→小文字変換

GO_CHK:
        CP   'r'
        JR   Z,GO_RETRY
        CP   'q'
        JR   Z,GO_QUIT

        LD   A,BEL
        CALL PutChar
        JR   GO_WAIT

GO_RETRY:
        CALL NEWLINE
        CALL InitBoard
        CALL PrintBoard
        CALL DecideFirstTurn
        JP   MAIN_LOOP

GO_QUIT:
        CALL NEWLINE
        LD   DE,MSG_BYE
        CALL PrintString
        RST  00H
        HALT

; ---------------------------------------------------------
; InitBoard
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
InitBoard:
        XOR  A
        LD   (PassStreak),A

        LD   HL,BOARD_INIT
        LD   DE,BOARD
        LD   BC,BOARD_BYTES
        LDIR
        RET


; =========================================================
; PrintBoard
; =========================================================
PrintBoard:
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL

        LD   DE,MSG_NEWLINE
        CALL PrintString

        LD   DE,COL_HEADER
        CALL PrintString

        LD   DE,MSG_NEWLINE
        CALL PrintString

        LD   HL,BOARD
        LD   B,BOARD_H

PB_ROW_LOOP:
        LD   A,'9'
        SUB  B
        CALL PutChar

        LD   A,' '
        CALL PutChar

        LD   C,BOARD_W

PB_COL_LOOP:
        LD   A,(HL)
        INC  HL

        LD   E,A
        LD   D,0
        PUSH HL
        LD   HL,STONE_CHAR
        ADD  HL,DE
        LD   A,(HL)
        POP  HL

        CALL PutChar

        LD   A,' '
        CALL PutChar

        DEC  C
        JR   NZ,PB_COL_LOOP

        LD   DE,MSG_NEWLINE
        CALL PrintString

        DJNZ PB_ROW_LOOP

        POP  HL
        POP  DE
        POP  BC
        POP  AF
        RET


; =========================================================
; Low-level Serial I/O
; =========================================================
PutChar:
        PUSH AF
PC_WAITTX:
        IN   A,(SIOA_CTL)
        BIT  2,A
        JR   Z,PC_WAITTX
        POP  AF
        OUT  (SIOA_DAT),A
        RET

PrintString:
        PUSH AF
        PUSH DE
PS_LOOP:
        LD   A,(DE)
        OR   A
        JR   Z,PS_DONE
        CALL PutChar
        INC  DE
        JR   PS_LOOP
PS_DONE:
        POP  DE
        POP  AF
        RET

NEWLINE:
        LD   A,CR
        CALL PutChar
        LD   A,LF
        CALL PutChar
        RET

GetChar:
GC_WRX:
        XOR  A
        OUT  (SIOA_CTL),A
        IN   A,(SIOA_CTL)
        BIT  0,A
        JR   Z,GC_WRX
        IN   A,(SIOA_DAT)
        RET


; =========================================================
; GETLINE
; =========================================================
GETLINE:
        LD   B,0

GL_LOOP:
        CALL GetChar

        CP   CR
        JR   Z,GL_DONE
        CP   LF
        JR   Z,GL_DONE

        CP   BS
        JR   Z,GL_BS
        CP   DEL
        JR   Z,GL_BS

        LD   E,A

        LD   A,B
        CP   LINE_MAX
        JR   C,GL_STORE

        LD   A,BEL
        CALL PutChar
        JR   GL_LOOP

GL_STORE:
        LD   A,E
        LD   (HL),A
        INC  HL
        INC  B
        CALL PutChar
        JR   GL_LOOP

GL_BS:
        LD   A,B
        OR   A
        JR   Z,GL_LOOP

        DEC  HL
        DEC  B

        LD   A,BS
        CALL PutChar
        LD   A,' '
        CALL PutChar
        LD   A,BS
        CALL PutChar

        JR   GL_LOOP

GL_DONE:
        XOR  A
        LD   (HL),A
        LD   A,B
        RET

; ---------------------------------------------------------
; StartTimer
; PIOA bit7 を HIGH にして Pico 計測を開始
; Destroys: AF
; ---------------------------------------------------------
StartTimer:
        PUSH AF
        LD   A,00001111B    ; PIOA: 全ビット出力モード
        OUT  (PIOA_CMD),A

        LD   A,0            ; PIOA: 全ビット LOW
        OUT  (PIOA_DATA),A
        LD   A,80H          ; PIOA: bit7 HIGH
        OUT  (PIOA_DATA),A

        POP  AF
        RET


; ---------------------------------------------------------
; StopTimer
; PIOA bit7 を LOW
; Destroys: A
; ---------------------------------------------------------
StopTimer:
        PUSH AF

        LD   A,0
        OUT  (PIOA_DATA),A        ; PIOA: 全ビット LOW

        POP  AF
        RET


; =========================================================
; PIOB スイッチ入力 ルーティン群
; =========================================================

; ---------------------------------------------------------
; InitPIOB
; PIOB を Mode3 (ビット制御) 全ビット入力として初期化
; Destroys: AF
; ---------------------------------------------------------
InitPIOB:
        PUSH AF
        LD   A,0FFH         ; Mode3 コマンド (D7:D6=11, D3:D0=1111)
        OUT  (PIOB_CMD),A
        LD   A,0FFH         ; I/O定義: 全ビット入力 (1=input)
        OUT  (PIOB_CMD),A
        POP  AF
        RET


; ---------------------------------------------------------
; Debounce
; ≈15ms ソフトウェア遅延 (10MHz 想定)
; Destroys: なし (BC を PUSH/POP)
; ---------------------------------------------------------
Debounce:
        PUSH BC
        LD   B,59
DB_OUTER:
        PUSH BC
        LD   B,200
DB_INNER:
        DJNZ DB_INNER
        POP  BC
        DJNZ DB_OUTER
        POP  BC
        RET


; ---------------------------------------------------------
; WaitSwPress
; Returns: A = 押されたスイッチの bitmask (アクティブLOW反転済み)
; Destroys: AF
; ---------------------------------------------------------
WaitSwPress:
WSP_WAIT:
        IN   A,(PIOB_DATA)
        CPL
        AND  3FH             ; SW0-SW5 (PB5=中断含む)
        JR   Z,WSP_WAIT

        PUSH AF
        CALL Debounce
        POP  AF
        IN   A,(PIOB_DATA)
        CPL
        AND  3FH
        JR   Z,WSP_WAIT

        PUSH AF
WSP_RELEASE:
        CALL Debounce
        IN   A,(PIOB_DATA)
        CPL
        AND  3FH
        JR   NZ,WSP_RELEASE
        POP  AF
        RET


; ---------------------------------------------------------
; SW_PlayerMove
; PIOB スイッチでカーソル移動し Enter(SW4) で着手
; Destroys: AF,BC,DE
; ---------------------------------------------------------
SW_PlayerMove:
        LD   DE,MSG_SWGUIDE
        CALL PrintString

        XOR  A
        LD   (PLR_COL),A
        LD   (PLR_ROW),A

SWP_REPRINT:
        LD   DE,MSG_SWPOS
        CALL PrintString
        LD   A,(PLR_COL)
        ADD  A,'A'
        CALL PutChar
        LD   A,(PLR_ROW)
        ADD  A,'1'
        CALL PutChar

SWP_LOOP:
        CALL WaitSwPress
        LD   E,A

        BIT  5,E             ; PB5 中断?
        JP   NZ,GAME_ABORTED

        BIT  4,E
        JR   NZ,SWP_ENTER

        BIT  2,E
        JR   Z,SWP_CHK1
        LD   A,(PLR_ROW)
        DEC  A
        AND  07H
        LD   (PLR_ROW),A

SWP_CHK1:
        BIT  3,E
        JR   Z,SWP_CHK2
        LD   A,(PLR_ROW)
        INC  A
        AND  07H
        LD   (PLR_ROW),A

SWP_CHK2:
        BIT  0,E
        JR   Z,SWP_CHK3
        LD   A,(PLR_COL)
        DEC  A
        AND  07H
        LD   (PLR_COL),A

SWP_CHK3:
        BIT  1,E
        JR   Z,SWP_UPD
        LD   A,(PLR_COL)
        INC  A
        AND  07H
        LD   (PLR_COL),A

SWP_UPD:
        LD   A,BS
        CALL PutChar
        CALL PutChar
        LD   A,(PLR_COL)
        ADD  A,'A'
        CALL PutChar
        LD   A,(PLR_ROW)
        ADD  A,'1'
        CALL PutChar
        JR   SWP_LOOP

SWP_ENTER:
        CALL NEWLINE

        LD   A,(PLR_ROW)
        LD   B,A
        LD   A,(PLR_COL)
        LD   C,A

        LD   A,(HumSide)
        LD   D,A
        PUSH BC
        PUSH DE
        CALL IsLegalMove
        POP  DE
        POP  BC
        OR   A
        JR   Z,SWP_ILLEGAL

        LD   A,(HumSide)
        LD   D,A
        CALL ApplyMove
        OR   A
        JR   Z,SWP_ILLEGAL2
        RET

SWP_ILLEGAL:
        LD   DE,MSG_ILLEGAL
        CALL PrintString
        JP   SWP_REPRINT

SWP_ILLEGAL2:
        LD   DE,MSG_ILLEGAL2
        CALL PrintString
        JP   SWP_REPRINT


; =========================================================
; Move parsing / Player move  (旧SIOAキー入力版 / デバッグ用)
; =========================================================
ParseMove:
        LD   A,(RXBUF)
        OR   A
        JR   Z,PM_BEEPFAIL
        LD   A,(RXBUF+1)
        OR   A
        JR   Z,PM_BEEPFAIL

        LD   A,(RXBUF)

        CP   'a'
        JR   C,PM_COLUPPER
        CP   'z'+1
        JR   NC,PM_COLUPPER
        AND  11011111b

PM_COLUPPER:
        SUB  'A'
        CP   8
        JR   NC,PM_BEEPFAIL
        LD   B,A

        LD   A,(RXBUF+1)
        SUB  '1'
        CP   8
        JR   NC,PM_BEEPFAIL

        SLA  A
        SLA  A
        SLA  A
        ADD  A,B
        LD   C,A

        LD   A,1
        RET

PM_BEEPFAIL:
        LD   A,BEL
        CALL PutChar
        XOR  A
        RET


PlayerMove:
PM_LOOP:
        LD   DE,MSG_PROMPT
        CALL PrintString
        CALL NEWLINE

        LD   HL,RXBUF
        CALL GETLINE
        CALL NEWLINE

        CALL ParseMove
        OR   A
        JR   Z,PM_BADINPUT

        CALL OffsetToRowCol

        LD   A,(HumSide)
        LD   D,A

        PUSH BC
        PUSH DE
        CALL IsLegalMove
        POP  DE
        POP  BC

        OR   A
        JR   Z,PM_ILLEGAL

        LD   A,(HumSide)
        LD   D,A
        CALL ApplyMove
        OR   A
        JR   Z,PM_ILLEGAL2

        RET

PM_BADINPUT:
        LD   DE,MSG_BADFMT
        CALL PrintString
        JR   PM_LOOP

PM_ILLEGAL:
        LD   DE,MSG_ILLEGAL
        CALL PrintString
        JR   PM_LOOP

PM_ILLEGAL2:
        LD   DE,MSG_ILLEGAL2
        CALL PrintString
        JR   PM_LOOP


; =========================================================
; Board save / restore  (minimax用)
; =========================================================

; ---------------------------------------------------------
; SaveBoard
;   BOARD(64B) -> (HL) で指定したバッファ
; Input:  HL = 保存先アドレス
; Destroys: なし (AF,BC,DE,HL を保護)
; ---------------------------------------------------------
SaveBoard:
        PUSH HL
        PUSH DE
        PUSH BC
        PUSH AF
        EX   DE,HL              ; DE = 保存先
        LD   HL,BOARD
        LD   BC,BOARD_BYTES
        LDIR
        POP  AF
        POP  BC
        POP  DE
        POP  HL
        RET

; ---------------------------------------------------------
; RestoreBoard
;   (HL) で指定したバッファ -> BOARD(64B)
; Input:  HL = 復元元アドレス
; Destroys: なし (AF,BC,DE,HL を保護)
; ---------------------------------------------------------
RestoreBoard:
        PUSH HL
        PUSH DE
        PUSH BC
        PUSH AF
        LD   DE,BOARD
        LD   BC,BOARD_BYTES
        LDIR
        POP  AF
        POP  BC
        POP  DE
        POP  HL
        RET


; =========================================================
; AI  (Minimax depth-2 + Alpha-Beta)
; =========================================================

; ---------------------------------------------------------
; CountAllFlips
;   ある手を打ったときに全方向でひっくり返せる石の合計を返す
; Inputs: D=player, B=row, C=col
; Output: A = total flips (0 = illegal or no flips)
; Destroys: AF,BC,DE,HL,IX,IY
; ---------------------------------------------------------
CountAllFlips:
        LD   A,D
        LD   (WORK_PLAYER),A
        LD   A,B
        LD   (WORK_ROW),A
        LD   A,C
        LD   (WORK_COL),A

        CALL RowColToOffset
        LD   HL,BOARD
        LD   E,C
        LD   D,0
        ADD  HL,DE

        LD   A,(HL)
        OR   A
        JR   NZ,CAF_Fail

        LD   B,DIR_CNT
        LD   IX,DIR_DR
        LD   IY,DIR_DC
        LD   D,0

CAF_Loop:
        LD   A,(IX+0)
        LD   (TD_DR),A
        INC  IX

        LD   A,(IY+0)
        LD   (TD_DC),A
        INC  IY

        PUSH BC
        PUSH DE
        CALL TryDirCount
        POP  DE
        POP  BC

        ADD  A,D
        LD   D,A

        DJNZ CAF_Loop

        LD   A,D
        RET

CAF_Fail:
        XOR  A
        RET


; [UTIL] AI ユーティリティ (CountMobility / CountEmpty / CountStable) -----

; ---------------------------------------------------------
; CountMobility
; Input:  D = player side
; Output: A = legal move count / AI_MOB_COUNT にも格納
; Destroys: AF,BC,DE,HL,IX,IY
; ---------------------------------------------------------
CountMobility:
        XOR  A
        LD   (AI_MOB_COUNT),A

        LD   B,0
CMB_ROW:
        LD   C,0
CMB_COL:
        PUSH BC
        PUSH DE
        CALL CountAllFlips
        POP  DE
        POP  BC

        OR   A
        JR   Z,CMB_NEXT

        LD   HL,AI_MOB_COUNT
        INC  (HL)

CMB_NEXT:
        INC  C
        LD   A,C
        CP   8
        JR   C,CMB_COL

        INC  B
        LD   A,B
        CP   8
        JR   C,CMB_ROW

        LD   A,(AI_MOB_COUNT)
        RET


; ---------------------------------------------------------
; CountEmpty
;   BOARD の空きマス(EMPTY=0)数を返す
; Output: A = empty count (0..64)
; Destroys: AF, BC, HL
; ---------------------------------------------------------
CountEmpty:
        PUSH BC
        PUSH HL
        LD   HL,BOARD
        LD   B,BOARD_BYTES
        LD   C,0
CE_Loop:
        LD   A,(HL)
        OR   A
        JR   NZ,CE_Next
        INC  C
CE_Next:
        INC  HL
        DJNZ CE_Loop
        LD   A,C
        POP  HL
        POP  BC
        RET


; ---------------------------------------------------------
; CountStable
;   簡易安定石カウント: コーナー + そこから連続する辺の石
; Input:  D = side
; Output: A = stable count
; Destroys: AF, BC, DE, HL
; ---------------------------------------------------------
CountStable:
        LD   A,D
        LD   (CS_SIDE),A
        XOR  A
        LD   (CS_COUNT),A

        LD   HL,CS_CORNER_TBL
        LD   B,4                ; 4コーナー

CS_CRN_LOOP:
        PUSH BC
        PUSH HL

        LD   A,(HL)              ; offset
        LD   (CS_OFF),A
        INC  HL
        LD   A,(HL)              ; dc
        LD   (CS_DC),A
        INC  HL
        LD   A,(HL)              ; dr
        LD   (CS_DR),A

        ; コーナーが自分の石かチェック
        LD   A,(CS_OFF)
        LD   E,A
        LD   D,0
        LD   HL,BOARD
        ADD  HL,DE
        LD   A,(HL)
        LD   E,A
        LD   A,(CS_SIDE)
        CP   E
        JP   NZ,CS_CRN_SKIP

        ; コーナー自体をカウント
        LD   HL,CS_COUNT
        INC  (HL)

        ; corner_row(B), corner_col(C) を計算
        LD   A,(CS_OFF)
        LD   E,A
        AND  07H
        LD   C,A             ; C = corner_col
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A             ; B = corner_row

        ; --- 行スキャン (B=固定, C=変化) ---
CS_ROW_LOOP:
        LD   A,C
        LD   E,A
        LD   A,(CS_DC)
        ADD  A,E             ; A = col + dc
        LD   C,A
        CP   8               ; 範囲外? (<0 は 248〜255 になり>=8 で検出)
        JP   NC,CS_COL_INIT
        PUSH BC
        LD   A,B
        SLA  A
        SLA  A
        SLA  A
        ADD  A,C             ; A = row*8+col
        LD   E,A
        LD   D,0
        LD   HL,BOARD
        ADD  HL,DE
        LD   A,(HL)
        POP  BC
        LD   E,A
        LD   A,(CS_SIDE)
        CP   E
        JP   NZ,CS_COL_INIT
        LD   HL,CS_COUNT
        INC  (HL)
        JP   CS_ROW_LOOP

        ; --- 列スキャン (C=固定, B=変化) ---
CS_COL_INIT:
        ; corner_row, corner_col を再計算
        LD   A,(CS_OFF)
        LD   E,A
        AND  07H
        LD   C,A             ; C = corner_col
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A             ; B = corner_row

CS_COL_LOOP:
        LD   A,B
        LD   E,A
        LD   A,(CS_DR)
        ADD  A,E             ; A = row + dr
        LD   B,A
        CP   8
        JP   NC,CS_CRN_SKIP
        PUSH BC
        LD   A,B
        SLA  A
        SLA  A
        SLA  A
        ADD  A,C
        LD   E,A
        LD   D,0
        LD   HL,BOARD
        ADD  HL,DE
        LD   A,(HL)
        POP  BC
        LD   E,A
        LD   A,(CS_SIDE)
        CP   E
        JP   NZ,CS_CRN_SKIP
        LD   HL,CS_COUNT
        INC  (HL)
        JP   CS_COL_LOOP

CS_CRN_SKIP:
        POP  HL              ; テーブル先頭に戻す
        LD   DE,3
        ADD  HL,DE           ; 次のエントリへ
        POP  BC
        DEC  B
        JP   NZ,CS_CRN_LOOP

        LD   A,(CS_COUNT)
        RET


; [AICORE] NegaMax�݋��T�� (RFCT100) ----------------------

; ---------------------------------------------------------
; AIset  [Step 6/7 - depth-2/3 切替、NegaMax 再帰呼び出し]
;   空きマス数 < D3_THRESHOLD → depth-3 (NM_TOTAL_DEPTH=2)
;   空きマス数 >= D3_THRESHOLD → depth-2 (NM_TOTAL_DEPTH=1)
;   POS_ORDER 順に全着手試行 → NegaMax 最大スコア手を選択。
;   BOARD_SAVE1 で盤面退避/復元。
;
; Variables: AS_IDX, AS_OFFSET, NM_ROOT_SCORE, NM_ROOT_POS
; Destroys: AF,BC,DE,HL,IX,IY
; ---------------------------------------------------------
AIset:
        ; 空きマス数キャッシュ
        CALL CountEmpty
        LD   (EMPTY_CACHE),A

        ; 初期化
        LD   HL,NM_SCORE_MIN
        LD   (NM_ROOT_SCORE),HL
        LD   A,0FFH
        LD   (NM_ROOT_POS),A
        XOR  A
        LD   (AS_IDX),A
        LD   (NM_CALL_DEPTH),A

        ; depth 選択: 空きマス数 < D3_THRESHOLD → depth-3, else depth-2
        LD   A,(EMPTY_CACHE)
        CP   D3_THRESHOLD
        JR   NC,AS_DEPTH2
        LD   A,2                ; depth-3: NM_TOTAL_DEPTH=2
        JR   AS_SET_DEPTH
AS_DEPTH2:
        LD   A,1                ; depth-2: NM_TOTAL_DEPTH=1
AS_SET_DEPTH:
        LD   (NM_TOTAL_DEPTH),A

        ; 盤面退避 (BOARD_SAVE1)
        LD   HL,BOARD_SAVE1
        CALL SaveBoard

AS_LOOP:
        LD   A,(AS_IDX)
        CP   64
        JP   NC,AS_END

        ; offset = POS_ORDER[AS_IDX]
        LD   HL,POS_ORDER
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)
        LD   (AS_OFFSET),A

        ; B=row, C=col
        LD   C,A
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A
        LD   A,C
        AND  07H
        LD   C,A

        LD   A,(AiSide)
        LD   D,A
        CALL CountAllFlips      ; 全破壊 A=flip count
        OR   A
        JP   Z,AS_NEXT          ; 非合法手 → スキップ

        ; 合法手: 盤面復元 → 着手 → 評価
        LD   HL,BOARD_SAVE1
        CALL RestoreBoard

        LD   A,(AS_OFFSET)
        LD   C,A
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A
        LD   A,C
        AND  07H
        LD   C,A
        LD   A,(AiSide)
        LD   D,A
        CALL ApplyMove

        LD   A,(HumSide)
        LD   D,A
        CALL NegaMax            ; HL = score (HumSide視点)
        ; negate: AiSide視点に変換
        EX   DE,HL
        LD   HL,0
        AND  A
        SBC  HL,DE              ; HL = -score

        ; if HL > (NM_ROOT_SCORE): 更新
        LD   A,(NM_ROOT_SCORE)
        LD   E,A
        LD   A,(NM_ROOT_SCORE+1)
        LD   D,A                ; DE = best_score (A経由でロード)
        PUSH HL
        AND  A
        SBC  HL,DE              ; HL = score - best (flags使用)
        POP  HL                 ; HL = score 復元 (flags 保持)
        JP   M,AS_RESTORE       ; score < best → スキップ
        JR   Z,AS_RESTORE       ; 同点 → スキップ
        LD   (NM_ROOT_SCORE),HL
        LD   A,(AS_OFFSET)
        LD   (NM_ROOT_POS),A

AS_RESTORE:
        LD   HL,BOARD_SAVE1
        CALL RestoreBoard

AS_NEXT:
        LD   A,(AS_IDX)
        INC  A
        LD   (AS_IDX),A
        JP   AS_LOOP

AS_END:
        LD   A,(NM_ROOT_POS)
        CP   0FFH
        RET  Z                  ; 合法手なし → DoTurn 側でパス処理

        ; 盤面復元 → 最善手を適用
        LD   HL,BOARD_SAVE1
        CALL RestoreBoard

        LD   A,(NM_ROOT_POS)
        LD   C,A
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A
        LD   A,C
        AND  07H
        LD   C,A
        LD   A,(AiSide)
        LD   D,A
        CALL ApplyMove

        ; "AI moves to XY\r\n" 出力
        LD   A,(NM_ROOT_POS)
        AND  07H
        ADD  A,'A'
        LD   (AImovePOS),A
        LD   A,(NM_ROOT_POS)
        RRCA
        RRCA
        RRCA
        AND  07H
        ADD  A,'1'
        LD   (AImovePOS+1),A
        LD   DE,AImoveMSG
        CALL PrintString
        LD   DE,AImovePOS
        CALL PrintString
        CALL NEWLINE

        ; "Eval:YYYY\r\n" 出力
        LD   DE,MSG_EVAL
        CALL PrintString
        LD   HL,(NM_ROOT_SCORE)
        CALL PrintSigned
        CALL NEWLINE
        RET


; ---------------------------------------------------------
; NM_GetSaveBuf
;   NM_CALL_DEPTH に対応する BOARD_SAVE バッファアドレスを返す
;   NegaMax の各再帰レベルが使うバッファ。
;   AIset は BOARD_SAVE1 を直接使用するため depth=0 は BOARD_SAVE2 から。
;
;   depth 0 -> BOARD_SAVE2  (NegaMax 1段目)
;   depth 1 -> BOARD_SAVE3  (NegaMax 2段目)
;   depth N(>=2) -> BOARD_EG_SAVES + (N-2)*64
;
; Input:  (NM_CALL_DEPTH)
; Output: HL = バッファアドレス
; Destroys: AF, BC, HL
; ---------------------------------------------------------
NM_GetSaveBuf:
        LD   A,(NM_CALL_DEPTH)
        OR   A
        JR   NZ,NGS_D1
        LD   HL,BOARD_SAVE2
        RET
NGS_D1:
        CP   1
        JR   NZ,NGS_D2
        LD   HL,BOARD_SAVE3
        RET
NGS_D2:
        ; depth >= 2: BOARD_EG_SAVES + (A-2)*64
        SUB  2
        LD   C,A
        LD   B,0
        SLA  C
        SLA  C
        SLA  C
        SLA  C
        SLA  C
        SLA  C              ; C = (A-2) * 64
        LD   HL,BOARD_EG_SAVES
        ADD  HL,BC
        RET


; ---------------------------------------------------------
; EvalLeaf  [pos_diff + mob×mob_w + stable×stable_w]
;   フェーズ判定: EMPTY_CACHE >= 44 → EARLY (mob×2,  stable×4)
;                 EMPTY_CACHE >= 12 → MID   (mob×2,  stable×6)
;                 EMPTY_CACHE  < 12 → LATE  (EL_LATE: stone_diff×100 + stable×30)
;
; Input:  D = 評価対象 side (AI視点: 正=有利)
; Output: HL = score (符号付き16bit)
; Destroys: AF, BC, DE, HL, IX, IY
; ---------------------------------------------------------
EvalLeaf:
        LD   A,D
        LD   (EV_SIDE),A    ; 評価対象 side を保存

        ; LATE(empty<12): Python互換 stone_diff×100 + stable×30
        LD   A,(EMPTY_CACHE)
        CP   12
        JP   C,EL_LATE

        LD   HL,0000H
        LD   (EV_POS_DIFF),HL

        LD   IX,BOARD       ; IX = BOARD ポインタ
        LD   IY,POS_WEIGHT  ; IY = POS_WEIGHT ポインタ
        LD   B,64           ; 64マスループ

EL_LOOP:
        ; BOARD[i] を読む
        LD   A,(IX+0)
        OR   A
        JR   Z,EL_NEXT      ; EMPTY → スキップ
        LD   C,A            ; C = 石の色

        ; POS_WEIGHT[i] を符号付き16bitに拡張 → DE
        LD   E,(IY+0)       ; E = weight byte (符号付き)
        LD   D,0
        BIT  7,E
        JR   Z,EL_POS
        LD   D,0FFH         ; 負値: DE = sign-extended
EL_POS:
        ; 自石 or 相手石?
        LD   A,(EV_SIDE)
        CP   C
        JR   NZ,EL_SUB      ; 相手石 → subtract

        ; 自石: EV_POS_DIFF += weight
        LD   HL,(EV_POS_DIFF)
        ADD  HL,DE
        LD   (EV_POS_DIFF),HL
        JR   EL_NEXT

EL_SUB:
        ; 相手石: EV_POS_DIFF -= weight
        LD   HL,(EV_POS_DIFF)
        AND  A              ; clear carry
        SBC  HL,DE
        LD   (EV_POS_DIFF),HL

EL_NEXT:
        INC  IX
        INC  IY
        DJNZ EL_LOOP

        ; --- mob 項 ---
        ; mob_ai = CountMobility(EV_SIDE)
        LD   A,(EV_SIDE)
        LD   D,A
        CALL CountMobility      ; A = mob_ai (IX,IY 破壊: pos_diff 完了後なので無問題)
        PUSH AF                 ; save mob_ai (POP DE で D=mob_ai)
        ; mob_opp = CountMobility(3-EV_SIDE)
        LD   A,(EV_SIDE)
        LD   B,A
        LD   A,3
        SUB  B
        LD   D,A
        CALL CountMobility      ; A = mob_opp
        LD   C,A                ; C = mob_opp
        POP  DE                 ; D = mob_ai, E = flags (不使用)
        ; mob_diff → HL (符号付き16bit)
        LD   A,D
        SUB  C                  ; A = mob_diff (signed byte)
        LD   L,A
        LD   H,0
        BIT  7,A
        JR   Z,EL_MOBPOS
        LD   H,0FFH             ; 負値: 符号拡張
EL_MOBPOS:
        ; mob_w = 2 (EARLY/MID 共通)
        ADD  HL,HL              ; ×2
EL_MOBDONE:
        ; EV_POS_DIFF += mob_term
        EX   DE,HL
        LD   HL,(EV_POS_DIFF)
        ADD  HL,DE
        LD   (EV_POS_DIFF),HL

        ; --- stable 項 ---
        ; stable_ai = CountStable(EV_SIDE)
        LD   A,(EV_SIDE)
        LD   D,A
        CALL CountStable        ; A = stable_ai
        PUSH AF                 ; save stable_ai (POP DE で D=stable_ai)
        ; stable_opp = CountStable(3-EV_SIDE)
        LD   A,(EV_SIDE)
        LD   B,A
        LD   A,3
        SUB  B
        LD   D,A
        CALL CountStable        ; A = stable_opp
        LD   C,A                ; C = stable_opp
        POP  DE                 ; D = stable_ai
        ; stable_diff → HL (符号付き16bit)
        LD   A,D
        SUB  C                  ; A = stable_diff (signed byte)
        LD   L,A
        LD   H,0
        BIT  7,A
        JR   Z,EL_STBPOS
        LD   H,0FFH             ; 負値: 符号拡張
EL_STBPOS:
        ; フェーズ判定: stable_w (EARLY=×4, MID=×6)
        LD   A,(EMPTY_CACHE)
        CP   44
        JR   NC,EL_STB4         ; >= 44 → EARLY: stable_w=4
        ; MID: stable_w=6 = ×4 + ×2
        ADD  HL,HL              ; ×2
        PUSH HL                 ; save ×2
        ADD  HL,HL              ; ×4
        POP  DE                 ; DE = ×2
        ADD  HL,DE              ; ×6
        JR   EL_STBDONE
EL_STB4:
        ; stable_w=4 = ×4
        ADD  HL,HL              ; ×2
        ADD  HL,HL              ; ×4
EL_STBDONE:
        ; EV_POS_DIFF += stable_term → HL = final score
        EX   DE,HL
        LD   HL,(EV_POS_DIFF)
        ADD  HL,DE
        RET

; --- LATE(empty<12): stone_diff × 100 + stable_diff × 30 ---
; Python eval_board の LATE 式に完全一致
EL_LATE:
        ; 石数カウント: C=my_count, E=opp_count
        LD   HL,BOARD
        LD   B,64
        LD   C,0
        LD   E,0
        LD   A,(EV_SIDE)
        LD   D,A            ; D = my side
EL_STONE_LOOP:
        LD   A,(HL)
        OR   A
        JR   Z,EL_STONE_NEXT    ; EMPTY
        CP   D
        JR   NZ,EL_STONE_OPP
        INC  C                  ; my stone
        JR   EL_STONE_NEXT
EL_STONE_OPP:
        INC  E                  ; opp stone
EL_STONE_NEXT:
        INC  HL
        DJNZ EL_STONE_LOOP

        ; stone_diff = C - E → HL (符号付き16bit)
        LD   A,C
        SUB  E
        LD   L,A
        LD   H,0
        BIT  7,A
        JR   Z,EL_LATE_SPOS
        LD   H,0FFH
EL_LATE_SPOS:
        ; × 100 = ×64 + ×32 + ×4
        ADD  HL,HL          ; ×2
        ADD  HL,HL          ; ×4
        PUSH HL             ; save ×4
        ADD  HL,HL          ; ×8
        ADD  HL,HL          ; ×16
        ADD  HL,HL          ; ×32
        PUSH HL             ; save ×32
        ADD  HL,HL          ; ×64
        POP  DE
        ADD  HL,DE          ; ×96
        POP  DE
        ADD  HL,DE          ; ×100
        LD   (EV_POS_DIFF),HL

        ; stable_diff × 30: stable_ai - stable_opp
        LD   A,(EV_SIDE)
        LD   D,A
        CALL CountStable        ; A = stable_ai
        PUSH AF
        LD   A,(EV_SIDE)
        LD   B,A
        LD   A,3
        SUB  B
        LD   D,A
        CALL CountStable        ; A = stable_opp
        LD   C,A
        POP  DE                 ; D = stable_ai
        LD   A,D
        SUB  C                  ; A = stable_diff (signed byte)
        LD   L,A
        LD   H,0
        BIT  7,A
        JR   Z,EL_LATE_STBPOS
        LD   H,0FFH
EL_LATE_STBPOS:
        ; × 30 = ×32 - ×2
        ADD  HL,HL          ; ×2
        PUSH HL
        ADD  HL,HL          ; ×4
        ADD  HL,HL          ; ×8
        ADD  HL,HL          ; ×16
        ADD  HL,HL          ; ×32
        POP  DE
        AND  A
        SBC  HL,DE          ; ×30
        EX   DE,HL
        LD   HL,(EV_POS_DIFF)
        ADD  HL,DE
        RET


; ---------------------------------------------------------
; NegaMax  [Step 5/7 - 再帰実装完成]
;   NM_CALL_DEPTH == NM_TOTAL_DEPTH → leaf: EvalLeaf(D=side) で返す
;   それ以外 → NM_RECURSE (POS_ORDER ループ + 再帰 + α更新)
;
; Input:  D = side to move
;         (NM_CALL_DEPTH), (NM_TOTAL_DEPTH) 設定済み
; Output: HL = score (D=side 視点, 符号付き16bit)
; Destroys: AF,BC,DE,HL,IX,IY
; ---------------------------------------------------------
NegaMax:
        LD   A,(NM_CALL_DEPTH)
        LD   B,A
        LD   A,(NM_TOTAL_DEPTH)
        CP   B                  ; NM_TOTAL_DEPTH == NM_CALL_DEPTH?
        JR   NZ,NM_RECURSE      ; 残り深さ > 0 → 再帰

        ; remaining == 0 → leaf
        CALL EvalLeaf
        RET

; ---------------------------------------------------------
; NM_RECURSE  [Step 5/7]
;   POS_ORDER 順に全合法手を試み、再帰 NegaMax の negamax 最大スコアを返す。
;   合法手なし → EvalLeaf (PASS/terminal 簡易処理)。
;
;   per-depth テーブル (NM_CALL_DEPTH でインデックス):
;     NM_SIDE_TBL[d]  : 手番 side
;     NM_IDX_TBL[d]   : POS_ORDER ループインデックス (0..63)
;     NM_HAS_MOVE[d]  : 合法手発見フラグ
;     NM_ALPHA_TBL[d*2]: best score (符号付き16bit, NM_SCORE_MINで初期化)
;   盤面退避: NM_GetSaveBuf(NM_CALL_DEPTH) → BOARD_SAVE2/3/...
; ---------------------------------------------------------
NM_RECURSE:
        ; D = side to move

        ; --- 初期化 ---
        LD   A,(NM_CALL_DEPTH)
        LD   C,A
        LD   B,0

        LD   HL,NM_SIDE_TBL     ; NM_SIDE_TBL[depth] = D
        ADD  HL,BC
        LD   (HL),D

        LD   HL,NM_IDX_TBL      ; NM_IDX_TBL[depth] = 0
        ADD  HL,BC
        LD   (HL),0

        LD   HL,NM_HAS_MOVE     ; NM_HAS_MOVE[depth] = 0
        ADD  HL,BC
        LD   (HL),0

        ADD  A,A                ; A = depth * 2
        LD   C,A
        LD   HL,NM_ALPHA_TBL    ; NM_ALPHA_TBL[depth] = NM_SCORE_MIN (E000H = -8192)
        ADD  HL,BC
        LD   (HL),00H           ; lo = 00H
        INC  HL
        LD   (HL),0E0H          ; hi = E0H

        CALL NM_GetSaveBuf      ; 盤面退避
        CALL SaveBoard

NMR_LOOP:
        LD   A,(NM_CALL_DEPTH)
        LD   C,A
        LD   B,0

        LD   HL,NM_IDX_TBL      ; idx = NM_IDX_TBL[depth]
        ADD  HL,BC
        LD   A,(HL)
        CP   64
        JP   NC,NMR_END

        LD   HL,POS_ORDER       ; offset = POS_ORDER[idx]
        LD   C,A
        ADD  HL,BC
        LD   A,(HL)             ; A = offset

        ; D = NM_SIDE_TBL[depth] (B,C を offset→row/col 変換前にロード)
        LD   C,A                ; C = offset (一時退避)
        LD   A,(NM_CALL_DEPTH)
        LD   HL,NM_SIDE_TBL
        LD   E,A
        LD   D,0
        ADD  HL,DE
        LD   D,(HL)             ; D = side
        LD   A,C                ; A = offset (復元)

        ; offset → B=row, C=col
        LD   C,A
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A
        LD   A,C
        AND  07H
        LD   C,A

        CALL CountAllFlips      ; A = flip count
        OR   A
        JP   Z,NMR_NEXT         ; 非合法手 → スキップ

        ; 合法手: has_move[depth] = 1
        LD   A,(NM_CALL_DEPTH)
        LD   HL,NM_HAS_MOVE
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   (HL),1

        CALL NM_GetSaveBuf      ; 盤面復元
        CALL RestoreBoard

        ; offset を NM_IDX_TBL[depth] から再計算
        LD   A,(NM_CALL_DEPTH)
        LD   HL,NM_IDX_TBL
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)             ; A = idx
        LD   HL,POS_ORDER
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)             ; A = offset

        ; offset → B=row, C=col
        LD   C,A
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A
        LD   A,C
        AND  07H
        LD   C,A

        ; D = side を再ロード
        LD   A,(NM_CALL_DEPTH)
        LD   HL,NM_SIDE_TBL
        LD   E,A
        LD   D,0
        ADD  HL,DE
        LD   D,(HL)

        CALL ApplyMove          ; D=side, B=row, C=col

        ; 相手サイドを D に設定
        LD   A,BLACK
        CP   D
        JR   NZ,NMR_OPP_WHITE
        LD   D,WHITE
        JR   NMR_DO_RECURSE
NMR_OPP_WHITE:
        LD   D,BLACK

NMR_DO_RECURSE:
        LD   A,(NM_CALL_DEPTH)  ; NM_CALL_DEPTH++ (再帰前)
        INC  A
        LD   (NM_CALL_DEPTH),A

        CALL NegaMax            ; HL = score (相手視点)

        LD   A,(NM_CALL_DEPTH)  ; NM_CALL_DEPTH-- (再帰後)
        DEC  A
        LD   (NM_CALL_DEPTH),A

        ; 符号反転: HL = -HL (自プレイヤー視点)
        EX   DE,HL
        LD   HL,0
        AND  A
        SBC  HL,DE

        ; alpha[depth] と比較・更新
        LD   A,(NM_CALL_DEPTH)
        ADD  A,A                ; A = depth * 2
        LD   C,A
        LD   B,0
        PUSH HL                 ; [sp] = score
        LD   HL,NM_ALPHA_TBL
        ADD  HL,BC              ; HL = &alpha[depth]
        LD   E,(HL)
        INC  HL
        LD   D,(HL)             ; DE = alpha
        DEC  HL
        PUSH HL
        POP  IX                 ; IX = &alpha[depth].lo
        POP  HL                 ; HL = score

        PUSH HL
        AND  A
        SBC  HL,DE              ; score - alpha (flags)
        POP  HL                 ; HL = score (flags 保持)
        JP   M,NMR_NO_UPDATE
        JR   Z,NMR_NO_UPDATE
        LD   (IX+0),L           ; alpha.lo = score.lo
        LD   (IX+1),H           ; alpha.hi = score.hi

NMR_NO_UPDATE:
        CALL NM_GetSaveBuf      ; 次イテレーション用に盤面復元
        CALL RestoreBoard

NMR_NEXT:
        LD   A,(NM_CALL_DEPTH)  ; idx[depth]++
        LD   HL,NM_IDX_TBL
        LD   C,A
        LD   B,0
        ADD  HL,BC
        INC  (HL)
        JP   NMR_LOOP

NMR_END:
        ; 合法手なし → EvalLeaf (PASS/terminal 簡易処理)
        LD   A,(NM_CALL_DEPTH)
        LD   HL,NM_HAS_MOVE
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)
        OR   A
        JR   NZ,NMR_RETURN

        LD   A,(NM_CALL_DEPTH)
        LD   HL,NM_SIDE_TBL
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   D,(HL)
        CALL EvalLeaf
        RET

NMR_RETURN:
        ; HL = alpha[depth]
        LD   A,(NM_CALL_DEPTH)
        ADD  A,A
        LD   C,A
        LD   B,0
        LD   HL,NM_ALPHA_TBL
        ADD  HL,BC
        LD   A,(HL)
        LD   E,A
        INC  HL
        LD   A,(HL)
        LD   D,A
        EX   DE,HL              ; HL = alpha[depth]
        RET


; [EGCORE] 終盤完全読み (negamax + α-β) -------------------

; ---------------------------------------------------------
; EG_GetSaveAddr
;   EG_DEPTH の値に対応する BOARD_SAVE バッファアドレスを返す
;   depth 0 -> BOARD_SAVE1
;   depth 1 -> BOARD_SAVE2
;   depth N(>=2) -> BOARD_EG_SAVES + (N-2)*64
; Input:  A = EG_DEPTH
; Output: HL = バッファアドレス
; Destroys: AF, BC, HL
; ---------------------------------------------------------
EG_GetSaveAddr:
        OR   A
        JR   NZ,EGA_D1
        LD   HL,BOARD_SAVE1
        RET
EGA_D1:
        CP   1
        JR   NZ,EGA_D2
        LD   HL,BOARD_SAVE2
        RET
EGA_D2:
        ; depth >= 2: BOARD_EG_SAVES + (A-2)*64
        SUB  2
        LD   C,A
        LD   B,0
        SLA  C
        SLA  C
        SLA  C
        SLA  C
        SLA  C
        SLA  C              ; C = (A-2) * 64
        LD   HL,BOARD_EG_SAVES
        ADD  HL,BC
        RET


; ---------------------------------------------------------
; SearchFull
;   終盤完全読み 再帰探索 (negamax)
;   α-β は処理時間計測後に EG_ALPHA を使って追加予定
;
; Input:
;   D = side to move (BLACK=1 or WHITE=2)
;   (EG_DEPTH)    = 現在の再帰深さ (0-based, AIset_EGの1手後から開始)
;   (SF_SIDE_TMP) = 現在の手番 side (再帰内で保持・復元に使用)
; Output:
;   A = score (手番プレイヤー視点の石差, 符号付き -64..+64)
;       正=手番プレイヤー有利, 負=不利
; Destroys: AF, BC, DE, HL
; ---------------------------------------------------------
SearchFull:
        ; [1] 合法手チェック
        PUSH DE
        CALL HasAnyLegalMove    ; D=side -> A=1:あり / 0:なし
        POP  DE
        OR   A
        JR   NZ,SF_HasMove

        ; --- 合法手なし: 相手番を確認 ---
        LD   A,3
        SUB  D
        LD   D,A                ; D = 相手番 (3 - side)
        PUSH DE
        CALL HasAnyLegalMove
        POP  DE
        OR   A
        JR   NZ,SF_Pass         ; 相手には合法手あり → PASS して再帰

        ; --- ゲーム終了 (双方合法手なし) ---
        ; score = 現在手番側の石数 - 相手石数 (手番プレイヤー視点, negamax準拠)
        ; ※ AiSide ではなく SF_SIDE_TMP を使う点に注意
        ;    偶数深さで AiSide を使うとスコアの正負が逆転するバグになる
        CALL CountStones        ; B=黒数, C=白数
        LD   A,(SF_SIDE_TMP)
        CP   BLACK
        JR   Z,SF_CurrIsBlack
SF_CurrIsWhite:
        LD   A,C
        SUB  B                  ; WHITE - BLACK (現在手番=WHITE視点)
        RET
SF_CurrIsBlack:
        LD   A,B
        SUB  C                  ; BLACK - WHITE (現在手番=BLACK視点)
        RET

SF_Pass:
        ; PASS: 相手番で再帰し、スコアの符号を反転して返す
        LD   A,(EG_DEPTH)
        INC  A
        LD   (EG_DEPTH),A
        LD   A,D
        LD   (SF_SIDE_TMP),A    ; 相手番をセット
        CALL SearchFull         ; A = 相手視点スコア
        PUSH AF
        ; 深さ・side を復元
        LD   A,(EG_DEPTH)
        DEC  A
        LD   (EG_DEPTH),A
        LD   A,(SF_SIDE_TMP)    ; 現在は相手番
        LD   E,A
        LD   A,3
        SUB  E
        LD   (SF_SIDE_TMP),A    ; 自分番に戻す
        POP  AF
        NEG                     ; 自分視点に反転
        RET

SF_HasMove:
        ; [2] 全64マス走査 → 合法手ごとに再帰
        LD   A,81H
        LD   (EG_BESTSCORE),A   ; ベスト = -127 (80H は NEG でオーバーフロー → 使わない)

        ; α-β: alpha[EG_DEPTH] = -INF で初期化
        PUSH BC
        LD   HL,SF_ALPHA_TBL
        LD   A,(EG_DEPTH)
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   (HL),81H           ; SF_ALPHA_TBL[EG_DEPTH] = -127 (80H NEG オーバーフロー対策)
        POP  BC

        LD   B,0                ; row=0
SF_ROW:
        LD   C,0                ; col=0
SF_COL:
        LD   A,(SF_SIDE_TMP)
        LD   D,A

        PUSH BC
        PUSH DE
        CALL CountAllFlips      ; A = flips
        POP  DE
        POP  BC
        OR   A
        JR   Z,SF_NEXTCOL       ; 非合法手

        ; 合法手: 仮着手 → 再帰 → 復元
        PUSH BC                 ; row,col 保護 (ApplyMove が B,C を破壊)
        LD   A,(EG_DEPTH)
        CALL EG_GetSaveAddr     ; HL = SAVE バッファ
        CALL SaveBoard

        LD   A,(SF_SIDE_TMP)
        LD   D,A
        CALL ApplyMove          ; B,C 破壊

        ; 深さ更新・相手番にして再帰
        LD   A,(EG_DEPTH)
        INC  A
        LD   (EG_DEPTH),A
        LD   A,(SF_SIDE_TMP)
        LD   E,A
        LD   A,3
        SUB  E
        LD   D,A
        LD   (SF_SIDE_TMP),A    ; 相手番をセット

        ; EG_BESTSCORE を退避 (再帰呼び出しで上書きされるため)
        LD   A,(EG_BESTSCORE)
        PUSH AF

        CALL SearchFull         ; A = 相手視点スコア
        NEG                     ; 自分視点に反転
        LD   E,A                ; E = child_score

        ; EG_BESTSCORE を復元
        POP  AF
        LD   (EG_BESTSCORE),A

        ; 深さ・side を復元
        LD   A,(EG_DEPTH)
        DEC  A
        LD   (EG_DEPTH),A
        LD   A,(SF_SIDE_TMP)
        LD   B,A                ; B = 相手番 (テンポラリ)
        LD   A,3
        SUB  B                  ; 自分番 = 3 - 相手番
        LD   (SF_SIDE_TMP),A    ; 自分番に戻す

        LD   A,(EG_DEPTH)
        CALL EG_GetSaveAddr
        CALL RestoreBoard

        POP  BC                 ; row,col 復元

        ; ベスト更新 (初回は無条件採用、以降は符号付き比較)
        ; 注: 81H は sentinel (未発見)。E - 81H は正値スコアでオーバーフローするため
        ;     初回は比較せず無条件採用する。
        LD   A,(EG_BESTSCORE)
        CP   81H                ; sentinel (初回)?
        JR   Z,SF_DO_UPDATE
        LD   D,A                ; D = current best (テンポラリ)
        LD   A,E                ; A = child_score
        SUB  D                  ; child - best (符号付き減算)
        JP   M,SF_NEXTCOL       ; child < best → スキップ
        JR   Z,SF_NEXTCOL       ; 同点 → スキップ (先着優先)
SF_DO_UPDATE:
        LD   A,E
        LD   (EG_BESTSCORE),A   ; 新ベスト

        ; α-β: alpha[D] 更新 & β-cutoff チェック
        ;   beta[D] = -alpha[D-1]  (親のalphaを反転)
        ;   alpha[D] >= beta[D] なら枝刈り
        PUSH BC                 ; row,col を退避
        LD   HL,SF_ALPHA_TBL
        LD   A,(EG_DEPTH)
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   (HL),E             ; SF_ALPHA_TBL[EG_DEPTH] = new best
        DEC  HL                 ; HL -> SF_ALPHA_TBL[EG_DEPTH-1]
        LD   A,(HL)             ; alpha[D-1] (親のbest)
        NEG                     ; beta = -alpha[D-1]
        LD   D,A                ; D = beta
        LD   A,E                ; A = alpha[D] (自分のbest)
        SUB  D                  ; alpha[D] - beta
        POP  BC                 ; row,col を復元
        JP   P,SF_RET           ; alpha > beta → β-cutoff
        JR   Z,SF_RET           ; alpha == beta → β-cutoff

SF_NEXTCOL:
        INC  C
        LD   A,C
        CP   8
        JP   C,SF_COL

        INC  B
        LD   A,B
        CP   8
        JP   C,SF_ROW           ; 内側が深いため JP 使用

        LD   A,(EG_BESTSCORE)
SF_RET:
        RET


; ---------------------------------------------------------
; AIset_EG
;   終盤完全読みの最善手選択 (外ループ)
;   AIset と同じ走査構造、スコア計算を SearchFull に差し替え
; Destroys: AF, BC, DE, HL
; ---------------------------------------------------------
AIset_EG:
        LD   A,81H
        LD   (EG_BESTSCORE),A   ; -127 = 最小値 (80H は NEG でオーバーフロー → 使わない)
        LD   A,0FFH
        LD   (EG_BESTROW),A     ; FFH = 未発見

        LD   B,0                ; row=0
AEGM_ROW:
        LD   C,0                ; col=0
AEGM_COL:
        LD   A,(AiSide)
        LD   D,A

        PUSH BC
        PUSH DE
        CALL CountAllFlips
        POP  DE
        POP  BC
        OR   A
        JR   Z,AEGM_NEXTCOL

        PUSH BC                 ; row,col 保護
        LD   HL,BOARD_SAVE1
        CALL SaveBoard
        LD   A,(AiSide)
        LD   D,A
        CALL ApplyMove          ; B,C 破壊

        ; SearchFull 初期設定
        ; depth=1 から開始: AIset_EG が BOARD_SAVE1(depth=0) を使用するため
        ;   depth=0 と衝突しないよう SearchFull は depth=1(BOARD_SAVE2) から使う
        LD   A,1
        LD   (EG_DEPTH),A       ; depth = 1
        LD   A,(EG_BESTSCORE)   ; AI の現在のベスト → depth=1 の beta = -このスコア
        LD   (SF_ALPHA_TBL),A   ; alpha[0] = AI_best (最初は 81H = -127, 更新される)
        PUSH AF                 ; EG_BESTSCORE を退避 (SearchFull が内部で上書きするため)
        LD   A,(HumSide)
        LD   D,A
        LD   (SF_SIDE_TMP),A    ; SearchFull 用 side セット
        CALL SearchFull         ; A = 相手視点スコア
        NEG                     ; AI視点に反転
        LD   E,A                ; E = ai_score

        LD   HL,BOARD_SAVE1
        CALL RestoreBoard
        POP  AF                 ; EG_BESTSCORE を復元
        LD   (EG_BESTSCORE),A
        POP  BC                 ; row,col 復元

        ; ベスト更新 (初回は無条件採用、以降は符号付き比較)
        ; EG_BESTROW=FFH は未発見 sentinel。E - 81H は正値スコアでオーバーフローするため
        ; 初回は比較せず無条件採用する。
        LD   A,(EG_BESTROW)
        CP   0FFH
        JR   Z,AEGM_UPDATE      ; 初回は無条件採用
        LD   A,(EG_BESTSCORE)
        LD   D,A
        LD   A,E
        SUB  D                  ; new - best (符号付き)
        JP   M,AEGM_NEXTCOL     ; new < best → スキップ
        JR   Z,AEGM_NEXTCOL     ; 同点 → スキップ
AEGM_UPDATE:
        LD   A,E
        LD   (EG_BESTSCORE),A
        LD   A,B
        LD   (EG_BESTROW),A
        LD   A,C
        LD   (EG_BESTCOL),A

AEGM_NEXTCOL:
        INC  C
        LD   A,C
        CP   8
        JR   C,AEGM_COL

        INC  B
        LD   A,B
        CP   8
        JP   C,AEGM_ROW

        ; 合法手がなければ終了 (DoTurn 側で PASS 処理)
        LD   A,(EG_BESTROW)
        CP   0FFH
        RET  Z

        ; ベスト手を実際に打つ
        LD   B,A
        LD   A,(EG_BESTCOL)
        LD   C,A
        LD   A,(AiSide)
        LD   D,A
        CALL ApplyMove

        ; "AI moves to XX" 表示
        LD   A,(EG_BESTCOL)
        ADD  A,'A'
        LD   (AImovePOS),A
        LD   A,(EG_BESTROW)
        ADD  A,'1'
        LD   (AImovePOS+1),A
        LD   DE,AImoveMSG
        CALL PrintString
        LD   DE,AImovePOS
        CALL PrintString
        CALL NEWLINE
        RET


; ---------------------------------------------------------
; HasAnyLegalMove
; Input:  D = player
; Output: A = 1 あり / 0 なし
; Destroys: AF,BC,DE,HL,IX,IY
; ---------------------------------------------------------
HasAnyLegalMove:
        LD   B,0
HAM_ROW:
        LD   C,0
HAM_COL:
        PUSH BC
        PUSH DE
        CALL IsLegalMove
        POP  DE
        POP  BC
        OR   A
        JR   NZ,HAM_FOUND

        INC  C
        LD   A,C
        CP   8
        JR   C,HAM_COL

        INC  B
        LD   A,B
        CP   8
        JR   C,HAM_ROW

        XOR  A
        RET

HAM_FOUND:
        LD   A,1
        RET


; =========================================================
; Coordinate helpers / Board primitives
; =========================================================
OffsetToRowCol:
        LD   A,C

        LD   B,A
        SRL  B
        SRL  B
        SRL  B

        AND  7
        LD   C,A
        RET

RowColToOffset:
        LD   A,B
        SLA  A
        SLA  A
        SLA  A
        ADD  A,C
        LD   C,A
        RET

InRange:
        BIT  7,B
        JR   NZ,IR_Fail
        LD   A,B
        CP   8
        JR   NC,IR_Fail

        BIT  7,C
        JR   NZ,IR_Fail
        LD   A,C
        CP   8
        JR   NC,IR_Fail

        LD   A,1
        RET
IR_Fail:
        XOR  A
        RET

PlaceAtOffset:
        LD   B,A

        LD   HL,BOARD
        LD   E,C
        LD   D,0
        ADD  HL,DE

        LD   A,(HL)
        OR   A
        JR   NZ,PAO_BeepFail

        LD   A,B
        LD   (HL),A

        LD   A,1
        RET

PAO_BeepFail:
        LD   A,BEL
        CALL PutChar
        XOR  A
        RET

IsBoardFull:
        PUSH HL
        PUSH BC

        LD   HL,BOARD
        LD   B,BOARD_BYTES

IBF_Loop:
        LD   A,(HL)
        OR   A
        JR   Z,IBF_NotFull
        INC  HL
        DJNZ IBF_Loop

        LD   A,1
        JR   IBF_Done

IBF_NotFull:
        XOR  A

IBF_Done:
        POP  BC
        POP  HL
        RET


; =========================================================
; Rule core: TryDirCount / IsLegalMove / FlipDirN / ApplyMove
; =========================================================
TryDirCount:
        LD   A,(WORK_PLAYER)
        LD   E,A
        LD   A,3
        SUB  E
        LD   (TD_OPP),A

        XOR  A
        LD   (TD_COUNT),A

        LD   A,(WORK_ROW)
        LD   E,A
        LD   A,(TD_DR)
        ADD  A,E
        LD   (TD_R),A

        LD   A,(WORK_COL)
        LD   E,A
        LD   A,(TD_DC)
        ADD  A,E
        LD   (TD_C),A

TDC_Loop:
        LD   A,(TD_R)
        LD   B,A
        LD   A,(TD_C)
        LD   C,A
        CALL InRange
        OR   A
        JR   Z,TDC_Fail

        CALL RowColToOffset

        LD   HL,BOARD
        LD   E,C
        LD   D,0
        ADD  HL,DE
        LD   A,(HL)
        LD   E,A

        LD   A,(TD_OPP)
        CP   E
        JR   Z,TDC_GotOpp

        LD   A,(WORK_PLAYER)
        CP   E
        JR   Z,TDC_ReturnCount

        JR   TDC_Fail

TDC_GotOpp:
        LD   A,(TD_COUNT)
        INC  A
        LD   (TD_COUNT),A

        LD   A,(TD_R)
        LD   E,A
        LD   A,(TD_DR)
        ADD  A,E
        LD   (TD_R),A

        LD   A,(TD_C)
        LD   E,A
        LD   A,(TD_DC)
        ADD  A,E
        LD   (TD_C),A

        JR   TDC_Loop

TDC_ReturnCount:
        LD   A,(TD_COUNT)
        RET

TDC_Fail:
        XOR  A
        RET


IsLegalMove:
        LD   A,D
        LD   (WORK_PLAYER),A
        LD   A,B
        LD   (WORK_ROW),A
        LD   A,C
        LD   (WORK_COL),A

        CALL RowColToOffset
        LD   HL,BOARD
        LD   E,C
        LD   D,0
        ADD  HL,DE
        LD   A,(HL)
        OR   A
        JR   NZ,ILM_NotLegal

        LD   B,DIR_CNT
        LD   IX,DIR_DR
        LD   IY,DIR_DC

ILM_Loop:
        LD   A,(IX+0)
        LD   (TD_DR),A
        INC  IX

        LD   A,(IY+0)
        LD   (TD_DC),A
        INC  IY

        PUSH BC
        CALL TryDirCount
        POP  BC

        OR   A
        JR   NZ,ILM_Legal

        DJNZ ILM_Loop

ILM_NotLegal:
        XOR  A
        RET

ILM_Legal:
        LD   A,1
        RET


FlipDirN:
        LD   (TD_N),A
        OR   A
        RET  Z

        LD   A,(WORK_ROW)
        LD   E,A
        LD   A,(TD_DR)
        ADD  A,E
        LD   (TD_R),A

        LD   A,(WORK_COL)
        LD   E,A
        LD   A,(TD_DC)
        ADD  A,E
        LD   (TD_C),A

FD_Loop:
        LD   A,(TD_N)
        OR   A
        RET  Z

        LD   A,(TD_R)
        LD   B,A
        LD   A,(TD_C)
        LD   C,A

        CALL RowColToOffset

        LD   HL,BOARD
        LD   E,C
        LD   D,0
        ADD  HL,DE
        LD   A,(WORK_PLAYER)
        LD   (HL),A

        LD   A,(TD_N)
        DEC  A
        LD   (TD_N),A

        LD   A,(TD_R)
        LD   E,A
        LD   A,(TD_DR)
        ADD  A,E
        LD   (TD_R),A

        LD   A,(TD_C)
        LD   E,A
        LD   A,(TD_DC)
        ADD  A,E
        LD   (TD_C),A

        JR   FD_Loop


ApplyMove:
        LD   A,D
        LD   (WORK_PLAYER),A
        LD   A,B
        LD   (WORK_ROW),A
        LD   A,C
        LD   (WORK_COL),A

        XOR  A
        LD   (AM_DIDFLIP),A

        LD   B,DIR_CNT
        LD   IX,DIR_DR
        LD   IY,DIR_DC

AM_Loop:
        LD   A,(IX+0)
        LD   (TD_DR),A
        INC  IX

        LD   A,(IY+0)
        LD   (TD_DC),A
        INC  IY

        PUSH BC
        CALL TryDirCount
        OR   A
        JR   Z,AM_NoFlip

        CALL FlipDirN

        LD   A,1
        LD   (AM_DIDFLIP),A

AM_NoFlip:
        POP  BC
        DJNZ AM_Loop

        LD   A,(AM_DIDFLIP)
        OR   A
        JR   Z,AM_Fail

        LD   A,(WORK_ROW)
        LD   B,A
        LD   A,(WORK_COL)
        LD   C,A
        CALL RowColToOffset

        LD   A,(WORK_PLAYER)
        CALL PlaceAtOffset

        LD   A,1
        RET

AM_Fail:
        XOR  A
        RET


; =========================================================
; Counting / printing / winner
; =========================================================
CountStones:
        LD   HL,BOARD
        LD   D,BOARD_BYTES
        LD   B,0
        LD   C,0

CS_Loop:
        LD   A,(HL)
        CP   BLACK
        JR   NZ,CS_NotX
        INC  B
        JR   CS_Next

CS_NotX:
        CP   WHITE
        JR   NZ,CS_Next
        INC  C

CS_Next:
        INC  HL
        DEC  D
        JR   NZ,CS_Loop
        RET

PrintDec2:
        LD   B,0
PD2_Loop:
        CP   10
        JR   C,PD2_Out
        SUB  10
        INC  B
        JR   PD2_Loop

PD2_Out:
        LD   C,A

        LD   A,B
        ADD  A,'0'
        CALL PutChar

        LD   A,C
        ADD  A,'0'
        CALL PutChar
        RET

; ---------------------------------------------------------
; PrintDec4  HL の値を10進4桁以内で出力 (leading zero 抑制、最低1桁)
; Input:  HL = value (0..9999)
; Destroys: AF,BC,DE
; ---------------------------------------------------------
PrintDec4:
        LD   B,0             ; leading zero flag (0=抑制, FFH=出力済み)
        LD   DE,1000
        CALL PD4_Div
        LD   DE,100
        CALL PD4_Div
        LD   DE,10
        CALL PD4_Div
        LD   A,L             ; 一の位は必ず出力
        ADD  A,'0'
        CALL PutChar
        RET

PD4_Div:
        LD   C,0
PD4_DLoop:
        OR   A               ; carry クリア
        SBC  HL,DE
        JR   C,PD4_DRem
        INC  C
        JR   PD4_DLoop
PD4_DRem:
        ADD  HL,DE           ; 引き過ぎた分を戻す
        LD   A,C
        OR   B               ; 桁=0 かつ未出力 → leading zero 抑制
        RET  Z
        LD   B,0FFH          ; 出力済みフラグ
        LD   A,C
        ADD  A,'0'
        CALL PutChar
        RET

; PrintSigned  符号付き16bit を10進で出力 ('-' + PrintDec4)
; Input:  HL = 符号付き16bit値
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
PrintSigned:
        BIT  7,H             ; 符号ビット確認
        JR   Z,PS_POS        ; 正値 → そのまま
        LD   A,'-'
        CALL PutChar
        EX   DE,HL
        LD   HL,0
        AND  A
        SBC  HL,DE           ; HL = -original
PS_POS:
        CALL PrintDec4
        RET

PrintCounts:
        CALL CountStones

        LD   DE,MSG_COUNTS
        PUSH BC
        CALL PrintString
        POP  BC

        LD   A,B
        PUSH BC
        CALL PrintDec2
        POP  BC

        LD   DE,MSG_SPACEO
        PUSH BC
        CALL PrintString
        POP  BC

        LD   A,C
        CALL PrintDec2

        CALL NEWLINE
        RET

ShowWinner:
        CALL CountStones
        LD   A,B
        CP   C
        JR   Z,SW_Draw
        JR   NC,SW_XWin

SW_OWin:
        LD   DE,MSG_WIN_O
        CALL PrintString
        CALL NEWLINE
        RET

SW_XWin:
        LD   DE,MSG_WIN_X
        CALL PrintString
        CALL NEWLINE
        RET

SW_Draw:
        LD   DE,MSG_DRAW
        CALL PrintString
        CALL NEWLINE
        RET


; [FLOW] ゲームフロー (DoTurn / DecideFirstTurn) -----------
; =========================================================
; Turn control: DecideFirstTurn / DoTurn
; =========================================================
DecideFirstTurn:
        LD   DE,MsgChooseOrder
        CALL PrintString

DFT_WAIT:
        XOR  A
        OUT  (SIOA_CTL),A
        IN   A,(SIOA_CTL)
        BIT  0,A
        JR   NZ,DFT_SIOA

        IN   A,(PIOB_DATA)
        CPL
        AND  05H
        JR   Z,DFT_WAIT

        CALL Debounce
        IN   A,(PIOB_DATA)
        CPL
        AND  05H
        JR   Z,DFT_WAIT

        LD   E,A

DFT_SW_REL:
        CALL Debounce
        IN   A,(PIOB_DATA)
        CPL
        AND  05H
        JR   NZ,DFT_SW_REL

        LD   A,E
        BIT  0,A
        JR   NZ,DFT_HumFirst
        JR   DFT_AiFirst

DFT_SIOA:
        IN   A,(SIOA_DAT)
        CALL PutChar
        CP   '1'
        JR   Z,DFT_HumFirst
        CP   '2'
        JR   Z,DFT_AiFirst
        LD   A,BEL
        CALL PutChar
        JR   DFT_WAIT

DFT_HumFirst:
        CALL NEWLINE
        LD   A,BLACK
        LD   (HumSide),A
        LD   A,WHITE
        LD   (AiSide),A
        LD   A,BLACK
        LD   (TurnSide),A
        LD   DE,MsgHumanFirst
        CALL PrintString
        RET

DFT_AiFirst:
        CALL NEWLINE
        LD   A,BLACK
        LD   (AiSide),A
        LD   A,WHITE
        LD   (HumSide),A
        LD   A,BLACK
        LD   (TurnSide),A
        LD   DE,MsgAiFirst
        CALL PrintString
        RET


DoTurn:
        LD   A,(TurnSide)
        LD   D,A

        CALL HasAnyLegalMove
        OR   A
        JR   NZ,DT_CanMove

        LD   A,(TurnSide)
        LD   B,A
        LD   A,(AiSide)
        CP   B
        JR   Z,DT_AiPass

DT_HumPass:
        LD   DE,MSG_PL_PASS
        CALL PrintString
        JR   DT_PassCommon

DT_AiPass:
        LD   DE,MSG_AI_PASS
        CALL PrintString

DT_PassCommon:
        LD   A,(PassStreak)
        INC  A
        LD   (PassStreak),A
        CP   2
        JR   NC,DT_EndByPass

        JR   DT_SwitchReturn0

DT_CanMove:
        XOR  A
        LD   (PassStreak),A

        LD   A,(TurnSide)
        LD   B,A
        LD   A,(AiSide)
        CP   B
        JR   Z,DT_DoAI

DT_DoHum:
        CALL SW_PlayerMove
        JR   DT_SwitchReturn0

DT_DoAI:
        CALL StartTimer

        ; 空きマス数で通常探索/完全読みを切り替え
        CALL CountEmpty
        CP   ENDGAME_THRESHOLD + 1
        JR   NC,DT_AI_Normal    ; 空き > 閾値 → 通常 depth-2

        CALL AIset_EG            ; 空き <= 閾値 → 終盤完全読み
        JR   DT_AI_Done

DT_AI_Normal:
        CALL AIset

DT_AI_Done:
        CALL StopTimer
        JR   DT_SwitchReturn0

DT_EndByPass:
        LD   DE,MSG_PASSEND
        CALL PrintString
        LD   A,1
        RET

DT_SwitchReturn0:
        LD   A,(TurnSide)
        CP   BLACK
        JR   Z,DT_SetWhite

DT_SetBlack:
        LD   A,BLACK
        LD   (TurnSide),A
        XOR  A
        RET

DT_SetWhite:
        LD   A,WHITE
        LD   (TurnSide),A
        XOR  A
        RET

        END START
