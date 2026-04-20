; =========================================================
; Super AKI-80 8x8 Othello  [Minimax depth-3 + Alpha-Beta + Move Ordering + Evaluation]
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
;   - AI move: Minimax depth-3  [Alpha-Beta pruning + 16bit eval + Mobility]
;       ply1: AIset           AI着手   (BOARD_SAVE1)
;       ply2: OppBestScore_d3 OPP着手  (BOARD_SAVE2)
;       ply3: AiBestScore_d3  AI着手   (BOARD_SAVE3)
;       leaf: ID3_LOOP        OPP手をPOS_WEIGHT+flipsで推定
;   - EndGame perfect read: empty <= ENDGAME_THRESHOLD -> SearchFull (negamax)
;       BOARD_EG_SAVES: depth 2..9 用 (8スロット x 64B = 512B)
;   - Legal check + flipping (ApplyMove)
;   - Counts display "X:nn O:nn"
;   - Game end: board full OR 2 consecutive passes
;
; mm_score range (16bit):
;   ai_weight:  5..120
;   opp term:   0..255  (opp_best=0 -> no opp moves -> best)
;   mobility:   0..128  (ai_mob-opp_mob+64, range 0..128)
;   total max:  120+255+128 = 503  < 65536
;   total min:  5+0+0 = 5  > 0
;   initial AI_BEST_SCORE = 0000H -> first legal move always updates
;
; α-β 枝刈り構造:
;   ID3_LOOP (leaf OPP): OBS3_BEST >= D3_AI_ALPHA → α-cutoff
;   AiBestScore_d3:      D3_AI_BEST >= D3_OPP_MIN → β-cutoff
;   OppBestScore_d3:     OD3_MIN_AI <= AIset alpha は未実装
;
; EndGame 完全読み (SearchFull):
;   negamax で全読み。スコア = AI石数 - 相手石数 (符号付き -64..+64)
;
; vs MM2_AB_EV: BOARD_SAVE3 / AiBestScore_d3 / OppBestScore_d3 / ID3_LOOP を追加。
;               OppBestScore_d2 → OppBestScore_d3 に置換。
;
; Apr 8th,  2026 時間計測の処理を加えた
; Apr 9th,  2026 プレイヤー入力を PIOB スイッチ(SW0-SW4)に変更 -> RVS8_PIOSW.ASM
; Apr 11th, 2026 SaveBoard 2スロット化 (HL param)、depth-2準備 -> RVS8_MM2_AB.ASM
; Apr 14th, 2026 α-β 枝刈り実装 (ID2_END α-cutoff in OppBestScore_d2)
; Apr 15th, 2026 EndGame完全読み追加 (SearchFull negamax) -> MM2_AB_EG.ASM
; Apr 20th, 2026 ムーブオーダリング追加 (POS_ORDER テーブル) -> MM2_AB_MO.ASM
; Apr 20th, 2026 評価関数強化 Step1-4 -> MM2_AB_EV.ASM
; Apr 21st, 2026 depth-3 実装 -> MM2_AB_D3.ASM
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

MSG_RETRYQ:     DEFM CR,LF,"r:Retry or q:Quit ? ",0
MSG_BYE:        DEFM CR,LF,"Bye.",CR,LF,0

MSG_PASSEND:    DEFM CR,LF,"Game ended by consecutive passes.",CR,LF,0

; =========================================================
; Tables
; =========================================================
; index: 0=EMPTY, 1=BLACK, 2=WHITE -> printable char
STONE_CHAR:
        DEFB '.', 'X', 'O'

; ---------------------------------------------------------
; POS_WEIGHT  (64 bytes, row-major 8x8)
;
;   Corner=120, X-sq=1(ほぼ禁止), C-sq=5(角隣), Edge=25-30, Inner=18-20
;   max score = 120 + 64 flips = 184 < 256 (byte-safe)
;
;   マス分類:
;     角  (A1/H1/A8/H8)        : 120
;     Xマス(B2/G2/B7/G7)       :   1  ← 角を相手に渡す最悪手
;     Cマス(B1/A2/G1/H2 etc.)  :   5  ← 角隣、相手に角を渡しやすい
;     辺中央(C1-F1 etc.)       :  25-30
;     B列/2行内側              :  15
;     中央                     :  18-20
; ---------------------------------------------------------
; [WEIGHT] 位置評価テーブル ---------------------------------
POS_WEIGHT:
        ;       A    B    C    D    E    F    G    H
        DEFB  120,   5,  30,  25,  25,  30,   5, 120  ; 1
        DEFB    5,   1,  15,  15,  15,  15,   1,   5  ; 2
        DEFB   30,  15,  20,  20,  20,  20,  15,  30  ; 3
        DEFB   25,  15,  20,  18,  18,  20,  15,  25  ; 4
        DEFB   25,  15,  20,  18,  18,  20,  15,  25  ; 5
        DEFB   30,  15,  20,  20,  20,  20,  15,  30  ; 6
        DEFB    5,   1,  15,  15,  15,  15,   1,   5  ; 7
        DEFB  120,   5,  30,  25,  25,  30,   5, 120  ; 8

; [WEIGHT] ムーブオーダリング用: POS_WEIGHT降順のマスoffset一覧 (64バイト)
; offset = row*8 + col  (row=0..7, col=0..7)
POS_ORDER:
        ; weight=120: コーナー
        DEFB  0,  7, 56, 63
        ; weight=30: C-squares
        DEFB  2,  5, 16, 23, 40, 47, 58, 61
        ; weight=25: 辺中央付近
        DEFB  3,  4, 24, 31, 32, 39, 59, 60
        ; weight=20: 内側リング
        DEFB 18, 19, 20, 21, 26, 29, 34, 37, 42, 43, 44, 45
        ; weight=18: 中央4近傍
        DEFB 27, 28, 35, 36
        ; weight=15: 辺内側・中間
        DEFB 10, 11, 12, 13, 17, 22, 25, 30, 33, 38, 41, 46, 50, 51, 52, 53
        ; weight=5: X隣接辺
        DEFB  1,  6,  8, 15, 48, 55, 57, 62
        ; weight=1: Xマス
        DEFB  9, 14, 49, 54

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
;   BOARD_SAVE2: ply2 OppBestScore_d3 外ループ用
;   BOARD_SAVE3: ply3 AiBestScore_d3 ループ用  ← depth-3 新規
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

; ---- Minimax AI work ----
AI_BEST_ROW:    DEFB 0
AI_BEST_COL:    DEFB 0
AI_BEST_SCORE:  DEFW 0          ; mm_score 16bit (高いほどAI有利)

OBS_BEST:       DEFB 0          ; OppBestScore 内部作業用 (8bit: max=184)
OBS_COUNT:      DEFB 0          ; OppBestScore: 相手合法手数
OBS2_MIN_AI:    DEFB 0          ; OppBestScore_d2: AI最善スコアの最小値
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

; ---- ムーブオーダリング用ループインデックス ----
AMM_IDX:        DEFB 0          ; AIset 外ループ POS_ORDER インデックス
OD2_IDX:        DEFB 0          ; OppBestScore_d3 外ループ (ply2 OPP)
ID2_IDX:        DEFB 0          ; AiBestScore_d3 ループ (ply3 AI)
LD3_IDX:        DEFB 0          ; ID3_LOOP インデックス (leaf OPP)

; ---- depth-3 AI work ----
D3_AI_BEST:     DEFB 0          ; AiBestScore_d3: AI 最善スコア作業用
D3_AI_ALPHA:    DEFB 0          ; ID3_LOOP cutoff: 255 - D3_AI_BEST (呼び出し元が設定)
OBS3_BEST:      DEFB 0          ; ID3_LOOP: leaf OPP 最善スコア作業用

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
        AND  1FH
        JR   Z,WSP_WAIT

        PUSH AF
        CALL Debounce
        POP  AF
        IN   A,(PIOB_DATA)
        CPL
        AND  1FH
        JR   Z,WSP_WAIT

        PUSH AF
WSP_RELEASE:
        CALL Debounce
        IN   A,(PIOB_DATA)
        CPL
        AND  1FH
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


; [AICORE] 通常探索 (Minimax depth-2 + α-β) ---------------
; ---------------------------------------------------------
; OppBestScore  [depth-1版: 盤面非破壊]
; Input:  D = opponent side
; Output: A = opp_best / OBS_COUNT = 相手合法手数
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
OppBestScore:
        XOR  A
        LD   (OBS_BEST),A
        LD   (OBS_COUNT),A

        LD   B,0
OBS_ROW:
        LD   C,0
OBS_COL:
        PUSH BC
        PUSH DE
        CALL CountAllFlips
        POP  DE
        POP  BC

        OR   A
        JR   Z,OBS_NEXTCOL

        PUSH AF
        LD   HL,OBS_COUNT
        INC  (HL)
        POP  AF

        LD   E,A

        PUSH BC
        LD   A,B
        SLA  A
        SLA  A
        SLA  A
        ADD  A,C
        LD   C,A
        LD   B,0
        LD   HL,POS_WEIGHT
        ADD  HL,BC
        LD   A,(HL)
        ADD  A,E
        POP  BC

        LD   E,A
        LD   A,(OBS_BEST)
        CP   E
        JR   NC,OBS_NEXTCOL

        LD   A,E
        LD   (OBS_BEST),A

OBS_NEXTCOL:
        INC  C
        LD   A,C
        CP   8
        JR   C,OBS_COL

        INC  B
        LD   A,B
        CP   8
        JR   C,OBS_ROW

OBS_END:
        LD   A,(OBS_BEST)
        RET


; ---------------------------------------------------------
; OppBestScore_d2  [depth-2版 + α-β枝刈り]
; Input:  D = opponent side (= HumSide)
; Output: A = opp_best / OBS_COUNT = 相手合法手数
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
OppBestScore_d2:
        XOR  A
        LD   (OBS_COUNT),A
        LD   A,0FFH
        LD   (OBS2_MIN_AI),A

        XOR  A
        LD   (OD2_IDX),A

OD2_LOOP:
        ; POS_ORDER[OD2_IDX] からマスoffsetを取得 → B=row, C=col
        LD   A,(OD2_IDX)
        CP   64
        JP   NC,OD2_END
        LD   HL,POS_ORDER
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)          ; A = offset
        LD   E,A
        AND  07H
        LD   C,A             ; col
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A             ; row

        LD   A,(HumSide)
        LD   D,A
        PUSH BC
        PUSH DE
        CALL CountAllFlips
        POP  DE
        POP  BC

        OR   A
        JP   Z,OD2_NEXTCOL

        LD   HL,OBS_COUNT
        INC  (HL)

        PUSH BC
        LD   HL,BOARD_SAVE2
        CALL SaveBoard
        LD   A,(HumSide)
        LD   D,A
        CALL ApplyMove

        XOR  A
        LD   (OBS_BEST),A

        XOR  A
        LD   (ID2_IDX),A

ID2_LOOP:
        ; POS_ORDER[ID2_IDX] からマスoffsetを取得 → B=row, C=col
        LD   A,(ID2_IDX)
        CP   64
        JP   NC,ID2_END
        LD   HL,POS_ORDER
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)          ; A = offset
        LD   E,A
        AND  07H
        LD   C,A             ; col
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A             ; row

        LD   A,(AiSide)
        LD   D,A
        PUSH BC
        PUSH DE
        CALL CountAllFlips
        POP  DE
        POP  BC

        OR   A
        JR   Z,ID2_NEXT

        LD   E,A
        PUSH BC
        LD   A,B
        SLA  A
        SLA  A
        SLA  A
        ADD  A,C
        LD   C,A
        LD   B,0
        LD   HL,POS_WEIGHT
        ADD  HL,BC
        LD   A,(HL)
        ADD  A,E
        POP  BC

        LD   HL,OBS_BEST
        CP   (HL)
        JR   C,ID2_NEXT
        JR   Z,ID2_NEXT
        LD   (HL),A
        ; α-cutoff: OBS_BEST >= OBS2_MIN_AI → 枝刈り
        LD   HL,OBS2_MIN_AI
        CP   (HL)
        JR   NC,ID2_END

ID2_NEXT:
        LD   A,(ID2_IDX)
        INC  A
        LD   (ID2_IDX),A
        JP   ID2_LOOP

ID2_END:
        LD   A,(OBS_BEST)
        LD   HL,OBS2_MIN_AI
        CP   (HL)
        JR   NC,OD2_RESTORE
        LD   (HL),A

OD2_RESTORE:
        LD   HL,BOARD_SAVE2
        CALL RestoreBoard
        POP  BC

OD2_NEXTCOL:
        LD   A,(OD2_IDX)
        INC  A
        LD   (OD2_IDX),A
        JP   OD2_LOOP

OD2_END:
        LD   A,(OBS_COUNT)
        OR   A
        JR   NZ,OD2_RETURN
        XOR  A
        RET

OD2_RETURN:
        LD   A,0FFH
        LD   HL,OBS2_MIN_AI
        SUB  (HL)
        RET


; ---------------------------------------------------------
; ID3_LOOP  [depth-3 leaf: OPP視点 POS_WEIGHT+flips 評価]
;
;   ply3(AI着手適用済み)の盤面でOPPが打てる各手を評価し、
;   OPPの最善スコアを OBS3_BEST に格納して返す。
;   スコア = POS_WEIGHT[opp_pos] + CountAllFlips(OPP, pos)
;
;   α-cutoff:
;     OBS3_BEST >= D3_AI_ALPHA のとき打ち切る。
;     D3_AI_ALPHA = 255 - D3_AI_BEST (AiBestScore_d3が呼び出し前に設定)
;     意味: OPPが十分良い応手を見つけたらAIはこのply3手を選ばない。
;
; Input:  D3_AI_ALPHA 設定済み, BOARD = ply3適用後
; Output: OBS3_BEST = OPP最善スコア (0 = OPP合法手なし)
; Destroys: AF,BC,DE,HL,IX,IY,LD3_IDX
; ---------------------------------------------------------
ID3_LOOP:
        XOR  A
        LD   (OBS3_BEST),A

        XOR  A
        LD   (LD3_IDX),A

ID3_L:
        LD   A,(LD3_IDX)
        CP   64
        JP   NC,ID3_END

        LD   HL,POS_ORDER
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)          ; A = offset (0..63)
        LD   E,A
        AND  07H
        LD   C,A             ; col = offset & 7
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A             ; row = offset >> 3

        LD   A,(HumSide)
        LD   D,A
        PUSH BC
        PUSH DE
        CALL CountAllFlips
        POP  DE
        POP  BC

        OR   A
        JR   Z,ID3_NEXT

        ; score = POS_WEIGHT[pos] + flips
        LD   E,A             ; E = flips
        PUSH BC
        LD   A,B
        SLA  A
        SLA  A
        SLA  A
        ADD  A,C
        LD   C,A
        LD   B,0
        LD   HL,POS_WEIGHT
        ADD  HL,BC
        LD   A,(HL)
        ADD  A,E             ; A = POS_WEIGHT + flips
        POP  BC

        LD   HL,OBS3_BEST
        CP   (HL)
        JR   C,ID3_NEXT
        JR   Z,ID3_NEXT
        LD   (HL),A          ; OBS3_BEST = score

        ; α-cutoff: OBS3_BEST >= D3_AI_ALPHA → OPPが十分良い応手を発見
        LD   HL,D3_AI_ALPHA
        CP   (HL)
        JR   NC,ID3_END

ID3_NEXT:
        LD   A,(LD3_IDX)
        INC  A
        LD   (LD3_IDX),A
        JP   ID3_L

ID3_END:
        RET


; ---------------------------------------------------------
; AiBestScore_d3  [depth-3: AI視点 ply3ループ]
;
;   現在のBOARD(ply2 OPP着手後)でAIが打てる各手について:
;     1. SaveBoard(BOARD_SAVE3)
;     2. ApplyMove(AI)
;     3. ID3_LOOP → OBS3_BEST = OPP leaf最善スコア
;     4. RestoreBoard(BOARD_SAVE3)
;     5. ai_score = 255 - OBS3_BEST
;        D3_AI_BEST = max(D3_AI_BEST, ai_score)
;
;   β-cutoff (OppBestScore_d3側):
;     D3_AI_BEST >= OBS2_MIN_AI (OPP現在最小) → OPPはこのply2手を選ばない
;     → この判定はOppBestScore_d3の呼び出し後に行う
;
; Input:  BOARD = ply2 OPP着手後
; Output: D3_AI_BEST = AIのply3最善スコア (0 = AI合法手なし)
; Destroys: AF,BC,DE,HL,IX,IY,ID2_IDX,LD3_IDX,D3_AI_ALPHA,OBS3_BEST
; ---------------------------------------------------------
AiBestScore_d3:
        XOR  A
        LD   (D3_AI_BEST),A

        XOR  A
        LD   (ID2_IDX),A

AB_D3_LOOP:
        ; POS_ORDER[ID2_IDX] からマスoffsetを取得 → B=row, C=col
        LD   A,(ID2_IDX)
        CP   64
        JP   NC,AB_D3_END

        LD   HL,POS_ORDER
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)          ; A = offset (0..63)
        LD   E,A
        AND  07H
        LD   C,A             ; col = offset & 7
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A             ; row = offset >> 3

        LD   A,(AiSide)
        LD   D,A
        PUSH BC
        PUSH DE
        CALL CountAllFlips
        POP  DE
        POP  BC

        OR   A
        JP   Z,AB_D3_NEXT    ; AIが打てない手はスキップ

        PUSH BC

        ; ply3: BOARD_SAVE3 に保存してAI着手を適用
        LD   HL,BOARD_SAVE3
        CALL SaveBoard

        LD   A,(AiSide)
        LD   D,A
        CALL ApplyMove

        ; D3_AI_ALPHA = 255 - D3_AI_BEST (ID3_LOOP用cutoff閾値)
        LD   A,0FFH
        LD   HL,D3_AI_BEST
        SUB  (HL)
        LD   (D3_AI_ALPHA),A

        CALL ID3_LOOP        ; OBS3_BEST = OPPのleaf最善スコア

        LD   HL,BOARD_SAVE3
        CALL RestoreBoard

        ; ai_score = 255 - OBS3_BEST
        LD   A,0FFH
        LD   HL,OBS3_BEST
        SUB  (HL)            ; A = 255 - OBS3_BEST

        ; D3_AI_BEST = max(D3_AI_BEST, ai_score)
        LD   HL,D3_AI_BEST
        CP   (HL)
        JR   C,AB_D3_POP
        JR   Z,AB_D3_POP
        LD   (HL),A

AB_D3_POP:
        POP  BC

AB_D3_NEXT:
        LD   A,(ID2_IDX)
        INC  A
        LD   (ID2_IDX),A
        JP   AB_D3_LOOP

AB_D3_END:
        RET


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
; AIset  (Minimax depth-2 + α-β)
;
;   各合法手について:
;     1. SaveBoard(SAVE1)
;     2. 仮着手 (ApplyMove)
;     3. OppBestScore_d2 -> opp_best, OBS_COUNT=相手合法手数
;     4. CountMobility(AI) -> AI_MOB_COUNT
;     5. RestoreBoard(SAVE1)
;     6. mm_score = POS_WEIGHT[ai_pos] + (255-opp_best) + (ai_mob-opp_mob+64)
;   mm_score 最大の手を選択して実際に打つ。
;
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
AIset:
        LD   HL,0000H
        LD   (AI_BEST_SCORE),HL
        LD   A,0FFH
        LD   (AI_BEST_ROW),A

        ; フェーズ判定: CountEmpty → GAME_PHASE (0=序盤 1=中盤 2=終盤)
        CALL CountEmpty          ; A = 空きマス数
        CP   EARLY_GAME
        JP   NC,AEV_EARLY        ; 空き >= 44 → 序盤
        CP   MID_GAME
        JP   NC,AEV_MID          ; 空き >= 12 → 中盤
        LD   A,2                 ; 終盤
        JP   AEV_SET_PHASE
AEV_EARLY:
        LD   A,0
        JP   AEV_SET_PHASE
AEV_MID:
        LD   A,1
AEV_SET_PHASE:
        LD   (GAME_PHASE),A

        XOR  A
        LD   (AMM_IDX),A

AMM_LOOP:
        ; POS_ORDER[AMM_IDX] からマスoffsetを取得 → B=row, C=col
        LD   A,(AMM_IDX)
        CP   64
        JP   NC,AMM_END
        LD   HL,POS_ORDER
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)          ; A = offset (0..63)
        LD   E,A             ; save offset
        AND  07H
        LD   C,A             ; col = offset & 7
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A             ; row = offset >> 3

        LD   A,(AiSide)
        LD   D,A

        PUSH BC
        PUSH DE
        CALL CountAllFlips
        POP  DE
        POP  BC

        OR   A
        JP   Z,AMM_NEXTCOL

        PUSH BC

        LD   HL,BOARD_SAVE1
        CALL SaveBoard

        LD   A,(AiSide)
        LD   D,A
        CALL ApplyMove

        LD   A,(HumSide)
        LD   D,A
        CALL OppBestScore_d2

        PUSH AF
        LD   A,(AiSide)
        LD   D,A
        CALL CountMobility

        ; 安定石カウント (Step3)
        LD   A,(AiSide)
        LD   D,A
        CALL CountStable
        LD   (AI_STABLE),A

        LD   A,(HumSide)
        LD   D,A
        CALL CountStable
        LD   (OPP_STABLE),A
        POP  AF

        LD   E,A
        LD   HL,BOARD_SAVE1
        CALL RestoreBoard

        POP  BC

        PUSH BC
        LD   A,B
        SLA  A
        SLA  A
        SLA  A
        ADD  A,C
        LD   C,A
        LD   B,0
        LD   HL,POS_WEIGHT
        ADD  HL,BC
        LD   A,(HL)
        POP  BC

        ; A = POS_WEIGHT[pos], E = opp_best
        LD   L,A             ; HL = POS_WEIGHT[pos]
        LD   H,0

        ; HL += (255 - opp_best)  [全フェーズ共通]
        LD   A,0FFH
        SUB  E
        LD   E,A
        LD   D,0
        ADD  HL,DE

        ; フェーズ別モビリティ係数で分岐
        LD   A,(GAME_PHASE)
        CP   1
        JP   Z,AMM_EVAL_MID
        CP   2
        JP   Z,AMM_EVAL_LATE

AMM_EVAL_EARLY:
        ; 序盤: HL += (mob_diff+64)*12 + (stable_diff+8)*30
        LD   A,(AI_MOB_COUNT)
        LD   D,A
        LD   A,(OBS_COUNT)
        LD   E,A
        LD   A,D
        SUB  E
        ADD  A,64            ; A = mob_diff+64 (0..128)
        PUSH HL
        LD   L,A
        LD   H,0
        ADD  HL,HL           ; ×2
        ADD  HL,HL           ; ×4
        LD   D,H
        LD   E,L
        ADD  HL,HL           ; ×8
        ADD  HL,DE           ; ×12
        LD   D,H
        LD   E,L
        POP  HL
        ADD  HL,DE           ; HL += mob_term

        ; stable_diff * 30 (= ×32 - ×2)
        PUSH BC
        LD   A,(AI_STABLE)
        LD   D,A
        LD   A,(OPP_STABLE)
        LD   E,A
        LD   A,D
        SUB  E
        ADD  A,8             ; A = stable_diff+8 (0..16)
        PUSH HL
        LD   L,A
        LD   H,0
        ADD  HL,HL           ; ×2
        LD   B,H
        LD   C,L             ; BC = ×2
        ADD  HL,HL           ; ×4
        ADD  HL,HL           ; ×8
        ADD  HL,HL           ; ×16
        ADD  HL,HL           ; ×32
        OR   A
        SBC  HL,BC           ; ×32-×2 = ×30
        LD   D,H
        LD   E,L
        POP  HL
        ADD  HL,DE
        POP  BC
        JP   AMM_SCORE_CMP

AMM_EVAL_MID:
        ; 中盤: HL += (mob_diff+64)*8 + (stable_diff+8)*50
        LD   A,(AI_MOB_COUNT)
        LD   D,A
        LD   A,(OBS_COUNT)
        LD   E,A
        LD   A,D
        SUB  E
        ADD  A,64
        PUSH HL
        LD   L,A
        LD   H,0
        ADD  HL,HL           ; ×2
        ADD  HL,HL           ; ×4
        ADD  HL,HL           ; ×8
        LD   D,H
        LD   E,L
        POP  HL
        ADD  HL,DE           ; HL += mob_term

        ; stable_diff * 50 (= ×32 + ×16 + ×2)
        PUSH BC
        LD   A,(AI_STABLE)
        LD   D,A
        LD   A,(OPP_STABLE)
        LD   E,A
        LD   A,D
        SUB  E
        ADD  A,8
        PUSH HL
        LD   L,A
        LD   H,0
        ADD  HL,HL           ; ×2
        LD   B,H
        LD   C,L             ; BC = ×2
        ADD  HL,HL           ; ×4
        ADD  HL,HL           ; ×8
        ADD  HL,HL           ; ×16
        LD   D,H
        LD   E,L             ; DE = ×16
        ADD  HL,HL           ; ×32
        ADD  HL,DE           ; ×32+×16 = ×48
        ADD  HL,BC           ; ×48+×2 = ×50
        LD   D,H
        LD   E,L
        POP  HL
        ADD  HL,DE
        POP  BC
        JP   AMM_SCORE_CMP

AMM_EVAL_LATE:
        ; 終盤: HL += (mob_diff+64)*4 + (stable_diff+8)*30
        LD   A,(AI_MOB_COUNT)
        LD   D,A
        LD   A,(OBS_COUNT)
        LD   E,A
        LD   A,D
        SUB  E
        ADD  A,64
        PUSH HL
        LD   L,A
        LD   H,0
        ADD  HL,HL           ; ×2
        ADD  HL,HL           ; ×4
        LD   D,H
        LD   E,L
        POP  HL
        ADD  HL,DE           ; HL += mob_term

        ; stable_diff * 30 (= ×32 - ×2)
        PUSH BC
        LD   A,(AI_STABLE)
        LD   D,A
        LD   A,(OPP_STABLE)
        LD   E,A
        LD   A,D
        SUB  E
        ADD  A,8
        PUSH HL
        LD   L,A
        LD   H,0
        ADD  HL,HL           ; ×2
        LD   B,H
        LD   C,L             ; BC = ×2
        ADD  HL,HL           ; ×4
        ADD  HL,HL           ; ×8
        ADD  HL,HL           ; ×16
        ADD  HL,HL           ; ×32
        OR   A
        SBC  HL,BC           ; ×30
        LD   D,H
        LD   E,L
        POP  HL
        ADD  HL,DE
        POP  BC

AMM_SCORE_CMP:
        PUSH HL
        LD   DE,(AI_BEST_SCORE)
        AND  A
        SBC  HL,DE
        POP  HL
        JR   C,AMM_NEXTCOL
        JR   Z,AMM_NEXTCOL

        LD   (AI_BEST_SCORE),HL
        LD   A,B
        LD   (AI_BEST_ROW),A
        LD   A,C
        LD   (AI_BEST_COL),A

AMM_NEXTCOL:
        LD   A,(AMM_IDX)
        INC  A
        LD   (AMM_IDX),A
        JP   AMM_LOOP

AMM_END:
        LD   A,(AI_BEST_ROW)
        CP   0FFH
        RET  Z

        LD   B,A
        LD   A,(AI_BEST_COL)
        LD   C,A
        LD   A,(AiSide)
        LD   D,A
        CALL ApplyMove

        LD   A,(AI_BEST_COL)
        ADD  A,'A'
        LD   (AImovePOS),A

        LD   A,(AI_BEST_ROW)
        ADD  A,'1'
        LD   (AImovePOS+1),A

        LD   DE,AImoveMSG
        CALL PrintString
        LD   DE,AImovePOS
        CALL PrintString
        CALL NEWLINE
        RET


; [EGCORE] 終盤完全読み (negamax + α-β) -------------------
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
