; =========================================================
; Super AKI-80 8x8 Othello  [Minimax depth-2 AI  Alpha-Beta pruning]
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
;   - AI move: Minimax depth-2  [Alpha-Beta pruning + 16bit eval + Mobility]
;       SaveBoard/RestoreBoard: HL=buffer address (2スロット対応)
;         BOARD_SAVE1: depth-1 (AIset外ループ用)
;         BOARD_SAVE2: depth-2 (OppBestScore_d2内ループ用) [TODO]
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
; α-β 枝刈り (OppBestScore_d2 内側ループ):
;   OBS_BEST (AI最善スコア) >= OBS2_MIN_AI (α値) になった時点で
;   内側ループを打ち切る。相手はこの外側手を選ばないため探索不要。
;
; vs RVS8_PIOSW: SaveBoard/RestoreBoard を HL パラメータ渡しに変更。
;                BOARD_SAVE1/BOARD_SAVE2 の2スロット化。
;
; Apr 8th, 2026 時間計測の処理を加えた
; Apr 9th, 2026 プレイヤー入力を PIOB スイッチ(SW0-SW4)に変更 -> RVS8_PIOSW.ASM
; Apr 11th, 2026 SaveBoard 2スロット化 (HL param)、depth-2準備 -> RVS8_MM2_AB.ASM
; Apr 14th, 2026 α-β 枝刈り実装 (ID2_END α-cutoff in OppBestScore_d2)
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
; BOARD_SAVE1/2  minimax用 盤面バックアップ (各64バイト)
;   BOARD_SAVE1: depth-1 AIset 外ループ用
;   BOARD_SAVE2: depth-2 OppBestScore_d2 内ループ用 (TODO)
; ---------------------------------------------------------
BOARD_SAVE1:
        DEFS BOARD_BYTES
BOARD_SAVE2:
        DEFS BOARD_BYTES

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
;
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
; Mode3 コマンドワード = 1111 1111B = FFH、続けて I/O 定義ワード FFH (1=入力)
; ※ Mode1 はストローブラッチ方式のためポーリング不可 → Mode3 を使用
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
; ループ構成: 外59回 × 内200回 × DJNZ(13T) ≈ 153400T ≈ 15.3ms
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
; スイッチ押下を待ち、デバウンス後に離れるまで待つ
; Returns: A = 押されたスイッチの bitmask (bit0=SW0 ... bit4=SW4)
;              アクティブLOW を反転済み (押した=1)
; Destroys: AF
; ---------------------------------------------------------
WaitSwPress:
WSP_WAIT:
        IN   A,(PIOB_DATA)
        CPL                 ; アクティブLOW反転
        AND  1FH            ; PB0-PB4 (SW0-SW4)
        JR   Z,WSP_WAIT     ; 何も押されていない → 待機

        ; デバウンス後に再確認
        PUSH AF
        CALL Debounce
        POP  AF
        IN   A,(PIOB_DATA)
        CPL
        AND  1FH
        JR   Z,WSP_WAIT     ; チャタリング → 再待機

        ; 有効な押下を保存して離れるまで待つ
        PUSH AF
WSP_RELEASE:
        CALL Debounce
        IN   A,(PIOB_DATA)
        CPL
        AND  1FH
        JR   NZ,WSP_RELEASE ; まだ押されている → 待機
        POP  AF
        RET


; ---------------------------------------------------------
; SW_PlayerMove
; PIOB スイッチでカーソル移動し Enter(SW4) で着手
; カーソル: PLR_COL(列 0-7), PLR_ROW(行 0-7)
; 違法手の場合はメッセージを出してリトライ
; Destroys: AF,BC,DE
; ---------------------------------------------------------
SW_PlayerMove:
        ; ガイドメッセージ表示
        LD   DE,MSG_SWGUIDE
        CALL PrintString

        ; カーソルを A1 (col=0, row=0) に初期化
        XOR  A
        LD   (PLR_COL),A
        LD   (PLR_ROW),A

SWP_REPRINT:
        ; 現在位置をフル表示: "Move: A1"  (初期表示・違法手後リプリント)
        LD   DE,MSG_SWPOS
        CALL PrintString
        LD   A,(PLR_COL)
        ADD  A,'A'
        CALL PutChar
        LD   A,(PLR_ROW)
        ADD  A,'1'
        CALL PutChar

SWP_LOOP:
        ; スイッチ入力待ち
        CALL WaitSwPress    ; A = bitmask
        LD   E,A            ; bitmask を E に退避 (以後 A が上書きされても OK)

        ; SW4(Enter) → 確定
        BIT  4,E
        JR   NZ,SWP_ENTER

        ; PB2(Up): 行--  (0→7 ラップ)
        BIT  2,E
        JR   Z,SWP_CHK1
        LD   A,(PLR_ROW)
        DEC  A
        AND  07H
        LD   (PLR_ROW),A

SWP_CHK1:
        ; PB3(Down): 行++  (7→0 ラップ)
        BIT  3,E
        JR   Z,SWP_CHK2
        LD   A,(PLR_ROW)
        INC  A
        AND  07H
        LD   (PLR_ROW),A

SWP_CHK2:
        ; PB0(Left): 列--  (0→7 ラップ)
        BIT  0,E
        JR   Z,SWP_CHK3
        LD   A,(PLR_COL)
        DEC  A
        AND  07H
        LD   (PLR_COL),A

SWP_CHK3:
        ; PB1(Right): 列++  (7→0 ラップ)
        BIT  1,E
        JR   Z,SWP_UPD
        LD   A,(PLR_COL)
        INC  A
        AND  07H
        LD   (PLR_COL),A

SWP_UPD:
        ; BSx2で位置2文字を上書き → 新しい位置を表示
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

        ; B=行, C=列 をセット
        LD   A,(PLR_ROW)
        LD   B,A
        LD   A,(PLR_COL)
        LD   C,A

        ; 合法手チェック
        LD   A,(HumSide)
        LD   D,A
        PUSH BC
        PUSH DE
        CALL IsLegalMove
        POP  DE
        POP  BC
        OR   A
        JR   Z,SWP_ILLEGAL

        ; 着手
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
; Input:  HL = 保存先アドレス (BOARD_SAVE1 or BOARD_SAVE2)
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
; Input:  HL = 復元元アドレス (BOARD_SAVE1 or BOARD_SAVE2)
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
; AI  (Minimax depth-1)
; =========================================================

; ---------------------------------------------------------
; CountAllFlips
;   ある手を打ったときに全方向でひっくり返せる石の合計を返す
;   (実際には置かない)
; Inputs:
;   D=player, B=row, C=col
; Output:
;   A = total flips (0 = illegal or no flips)
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


; ---------------------------------------------------------
; OppBestScore  [depth-1版: 盤面非破壊]
;
;   相手の全合法手について score=POS_WEIGHT+flips を計算し
;   最大値(opp_best)と合法手数(OBS_COUNT)を求める。
;   実際には着手せず CountAllFlips のみ使用 (盤面変更なし)。
;
;   【depth-2版への改造方針 (OppBestScore_d2)】
;     現在:  CountAllFlips のみ → スコアは1手先の評価のみ
;     depth-2: 各相手手に対して
;               LD HL,BOARD_SAVE2 / CALL SaveBoard
;               CALL ApplyMove(Opp)
;               AIの応手を探索 (簡易評価 or 再帰)
;               LD HL,BOARD_SAVE2 / CALL RestoreBoard
;             → opp_best = AIにとって最悪のスコア
;
;   【α-β枝刈り挿入ポイント】
;     OBS_BEST を更新した直後 (↓ "<<< β-CUTOFF HERE" の箇所) に
;     呼び出し元 (AIset) から渡された α 値と比較する:
;       if (255 - OBS_BEST) <= alpha_threshold: GOTO OBS_END (枝刈り)
;     OBS_BEST が大きいほど (255-OBS_BEST) は小さくなり
;     AIset での mm_score も下がるため、これ以上探索不要と判断できる。
;     α 値の受け渡し方法: グローバル変数 (例: OBS_ALPHA) か スタック渡し。
;
; Input:
;   D = opponent side
; Output:
;   A       = opp_best (0 if no legal moves)  ※8bit: max=184
;   OBS_COUNT = 相手合法手数
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
OppBestScore:
        ; ---- 初期化 ----
        XOR  A
        LD   (OBS_BEST),A       ; opp_best = 0
        LD   (OBS_COUNT),A      ; 合法手数 = 0

        ; ---- 64マス走査ループ ----
        LD   B,0                ; row=0
OBS_ROW:
        LD   C,0                ; col=0
OBS_COL:
        ; [depth-2] ここで ApplyMove(Opp) → AI応手評価 → RestoreBoard に拡張
        PUSH BC
        PUSH DE                 ; D=opponent を保護
        CALL CountAllFlips      ; A = flips (合法手なら>0, D は内部で変更)
        POP  DE                 ; D=opponent 復元
        POP  BC

        OR   A
        JR   Z,OBS_NEXTCOL      ; A=0 → 非合法手 → スキップ

        ; ---- 合法手カウントアップ ----
        PUSH AF
        LD   HL,OBS_COUNT
        INC  (HL)
        POP  AF

        ; ---- score = POS_WEIGHT[row*8+col] + flips ----
        LD   E,A                ; E = flip count

        PUSH BC                 ; row/col を保護 (BC をオフセット計算に流用)
        LD   A,B
        SLA  A
        SLA  A
        SLA  A                  ; A = row*8
        ADD  A,C                ; A = row*8+col = テーブルオフセット
        LD   C,A
        LD   B,0
        LD   HL,POS_WEIGHT
        ADD  HL,BC              ; HL = &POS_WEIGHT[offset]
        LD   A,(HL)             ; A = positional weight (5..120)
        ADD  A,E                ; A = score (最大 120+32=152, 8bit に収まる)
        POP  BC                 ; row/col 復元

        ; ---- OBS_BEST 更新 ----
        LD   E,A                ; E = score (比較のため退避)
        LD   A,(OBS_BEST)
        CP   E
        JR   NC,OBS_NEXTCOL     ; OBS_BEST >= score → 更新不要

        LD   A,E
        LD   (OBS_BEST),A       ; OBS_BEST = score (新最大値)
        ; <<< β-CUTOFF HERE: (255-OBS_BEST) <= alpha ならここで打ち切り

OBS_NEXTCOL:
        INC  C
        LD   A,C
        CP   8
        JR   C,OBS_COL          ; col < 8 → 次の列へ

        INC  B
        LD   A,B
        CP   8
        JR   C,OBS_ROW          ; row < 8 → 次の行へ

        ; ---- 結果返却 ----
OBS_END:
        LD   A,(OBS_BEST)       ; A = opp_best
        RET


; ---------------------------------------------------------
; OppBestScore_d2  [depth-2版]
;
;   相手の各合法手について実際に着手し、その局面でのAI最善スコア
;   max(POS_WEIGHT+flips) を求める。
;   相手はAI最善スコアが最小になる手を選ぶ (minimax)。
;
;   戻り値: opp_best = 255 - min_j(ai_best_j)
;     ai_best が低い (AIが苦しい) ほど opp_best が高くなり
;     AIset の (255-opp_best) 項が下がる。
;
;   速度注意: α-β なしでは外ループ×内ループ ≒ 4000倍のCAF呼び出し。
;             実用には OppBestScore_d2_AB (α-β版) への切り替えが必要。
;
; Input:
;   D = opponent side (= HumSide)
; Output:
;   A         = opp_best
;   OBS_COUNT = 相手合法手数
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
OppBestScore_d2:
        ; ---- 初期化 ----
        XOR  A
        LD   (OBS_COUNT),A      ; 相手合法手数 = 0
        LD   A,0FFH
        LD   (OBS2_MIN_AI),A    ; AI最善スコア最小値 = 255 (初期値)

        LD   B,0                ; outer row=0
OD2_ROW:
        LD   C,0                ; outer col=0
OD2_COL:
        ; 相手の合法手チェック (毎回 D=HumSide をロード: 内側ループで破壊されるため)
        LD   A,(HumSide)
        LD   D,A
        PUSH BC
        PUSH DE
        CALL CountAllFlips      ; A = flips
        POP  DE
        POP  BC

        OR   A
        JR   Z,OD2_NEXTCOL      ; 非合法 → スキップ

        ; ---- 相手合法手カウントアップ ----
        LD   HL,OBS_COUNT
        INC  (HL)

        ; ---- 相手が着手: BOARD_SAVE2 → ApplyMove ----
        PUSH BC                 ; outer row,col 保護 (ApplyMove が B,C を破壊)
        LD   HL,BOARD_SAVE2
        CALL SaveBoard          ; 全レジスタ保護
        LD   A,(HumSide)
        LD   D,A
        CALL ApplyMove          ; B,C 破壊

        ; ---- AI 最善スコア探索 (inner loop) ----
        XOR  A
        LD   (OBS_BEST),A       ; inner best = 0

        LD   B,0                ; inner row=0
ID2_ROW:
        LD   C,0                ; inner col=0
ID2_COL:
        LD   A,(AiSide)
        LD   D,A
        PUSH BC
        PUSH DE
        CALL CountAllFlips      ; A = flips for AI
        POP  DE
        POP  BC

        OR   A
        JR   Z,ID2_NEXT         ; AI の非合法手

        ; score = POS_WEIGHT[row*8+col] + flips
        LD   E,A                ; E = flips
        PUSH BC
        LD   A,B
        SLA  A
        SLA  A
        SLA  A                  ; A = row*8
        ADD  A,C                ; A = row*8+col
        LD   C,A
        LD   B,0
        LD   HL,POS_WEIGHT
        ADD  HL,BC
        LD   A,(HL)             ; A = POS_WEIGHT
        ADD  A,E                ; A = score
        POP  BC

        LD   HL,OBS_BEST
        CP   (HL)
        JR   C,ID2_NEXT         ; score < inner best → スキップ
        JR   Z,ID2_NEXT         ; 同点 → スキップ
        LD   (HL),A             ; inner best 更新
        ; α-cutoff: OBS_BEST >= OBS2_MIN_AI → 相手はこの手を選ばない → inner終了
        LD   HL,OBS2_MIN_AI
        CP   (HL)               ; OBS_BEST vs OBS2_MIN_AI (α)
        JR   NC,ID2_END         ; OBS_BEST >= α → 枝刈り

ID2_NEXT:
        INC  C
        LD   A,C
        CP   8
        JR   C,ID2_COL

        INC  B
        LD   A,B
        CP   8
        JR   C,ID2_ROW

ID2_END:
        ; inner loop 完了 (正常終了 or α-cutoff)
        ; OBS2_MIN_AI を更新 (相手は AI最善を最小化する手を選ぶ)
        LD   A,(OBS_BEST)
        LD   HL,OBS2_MIN_AI
        CP   (HL)
        JR   NC,OD2_RESTORE     ; A >= OBS2_MIN_AI → 更新不要
        LD   (HL),A             ; 新最小値

OD2_RESTORE:
        LD   HL,BOARD_SAVE2
        CALL RestoreBoard       ; 全レジスタ保護
        POP  BC                 ; outer row,col 復元

OD2_NEXTCOL:
        INC  C
        LD   A,C
        CP   8
        JP   C,OD2_COL          ; 内側ループが長いため JP 使用

        INC  B
        LD   A,B
        CP   8
        JP   C,OD2_ROW

        ; ---- 結果返却 ----
OD2_END:
        LD   A,(OBS_COUNT)
        OR   A
        JR   NZ,OD2_RETURN
        XOR  A                  ; 相手合法手なし → opp_best = 0
        RET

OD2_RETURN:
        LD   A,0FFH
        LD   HL,OBS2_MIN_AI
        SUB  (HL)               ; A = 255 - OBS2_MIN_AI
        RET


; ---------------------------------------------------------
; CountMobility
;   指定プレイヤーの合法手数を数えて返す
; Input:
;   D = player side
; Output:
;   A = legal move count (0..64)  AI_MOB_COUNT にも格納
; Destroys: AF,BC,DE,HL,IX,IY
; ---------------------------------------------------------
CountMobility:
        XOR  A
        LD   (AI_MOB_COUNT),A   ; カウンタ初期化

        LD   B,0                ; row=0
CMB_ROW:
        LD   C,0                ; col=0
CMB_COL:
        PUSH BC
        PUSH DE
        CALL CountAllFlips      ; A = flips
        POP  DE
        POP  BC

        OR   A
        JR   Z,CMB_NEXT         ; 非合法手

        LD   HL,AI_MOB_COUNT
        INC  (HL)               ; 合法手 -> カウントアップ

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
; AIset  (Minimax depth-1  16bit evaluation + Mobility)
;
;   各合法手について:
;     1. SaveBoard
;     2. 仮着手 (ApplyMove)
;     3. OppBestScore -> opp_best (8bit), OBS_COUNT = 相手合法手数
;     4. CountMobility(AI) -> AI_MOB_COUNT = AI合法手数
;     5. RestoreBoard
;     6. mm_score = POS_WEIGHT[ai_pos] + (255-opp_best) + (ai_mob-opp_mob+64)
;   mm_score 最大の手を選択して実際に打つ。
;
;   mm_score が同点の場合は先に見つかった手（左上優先）を採用。
;
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
AIset:
        ; ベスト初期化 (16bit)
        LD   HL,0000H
        LD   (AI_BEST_SCORE),HL
        LD   A,0FFH
        LD   (AI_BEST_ROW),A    ; FFH = 未発見

        LD   B,0                ; row=0
AMM_ROW:
        LD   C,0                ; col=0
AMM_COL:
        ; D = AiSide を毎回ロード (ループ中にDが変わるため)
        LD   A,(AiSide)
        LD   D,A

        PUSH BC
        PUSH DE
        CALL CountAllFlips      ; A = AI の flips at (B,C)
        POP  DE
        POP  BC

        OR   A
        JR   Z,AMM_NEXTCOL      ; 非合法手 -> スキップ

        ; ---- 1手先読み ----
        ; ApplyMove は内部で LD B,DIR_CNT と PlaceAtOffset により
        ; B,C を破壊するため、呼び出し前にスタックで保護する
        PUSH BC                 ; row/col 保護 ← ApplyMove の前

        ; (1) 盤面保存 (スロット1)
        LD   HL,BOARD_SAVE1
        CALL SaveBoard

        ; (2) 仮着手
        LD   A,(AiSide)
        LD   D,A
        CALL ApplyMove          ; B,C が破壊される

        ; (3) 相手の最善スコアと合法手数を求める [depth-2: BOARD_SAVE2使用]
        ;     opp_best = 255 - min_j(AI最善スコア) over 相手合法手 j
        LD   A,(HumSide)
        LD   D,A
        CALL OppBestScore_d2    ; A=opp_best, OBS_COUNT=相手合法手数

        ; (4) AI合法手数を求める（仮着手後の盤面で）
        PUSH AF                 ; opp_best をスタックに退避
        LD   A,(AiSide)
        LD   D,A
        CALL CountMobility      ; A=AI合法手数 (AI_MOB_COUNTに保存)
        POP  AF                 ; A = opp_best 復元

        ; (5) 盤面復元 (スロット1)
        LD   E,A                ; E = opp_best (RestoreBoard前に退避)
        LD   HL,BOARD_SAVE1
        CALL RestoreBoard

        POP  BC                 ; row/col 復元 ← RestoreBoard の後

        ; (6) mm_score = POS_WEIGHT[ai_pos] + (255-opp_best) + (ai_mob-opp_mob+64)
        ;     16bit範囲: 最大 120+255+128=503 < 65536  最小 5+0+0=5 > 0
        PUSH BC                 ; row/col 保護 (POS_WEIGHT 参照でBC使用)
        LD   A,B
        SLA  A
        SLA  A
        SLA  A
        ADD  A,C                ; A = row*8+col = offset
        LD   C,A
        LD   B,0
        LD   HL,POS_WEIGHT
        ADD  HL,BC
        LD   A,(HL)             ; A = POS_WEIGHT[ai_pos]
        POP  BC

        LD   L,A
        LD   H,0                ; HL = ai_weight (16bit)

        LD   A,0FFH
        SUB  E                  ; A = 255 - opp_best
        LD   E,A
        LD   D,0                ; DE = (255 - opp_best) (16bit)

        ADD  HL,DE              ; HL = ai_weight + (255-opp_best)

        ; モビリティ項: ai_mob - opp_mob + 64  (範囲 0..128)
        LD   A,(AI_MOB_COUNT)   ; A = ai_mob
        LD   D,A
        LD   A,(OBS_COUNT)      ; A = opp_mob
        LD   E,A
        LD   A,D
        SUB  E                  ; A = ai_mob - opp_mob (符号付き)
        ADD  A,64               ; +64 でオフセット -> 0..128
        LD   E,A
        LD   D,0
        ADD  HL,DE              ; HL = mm_score (16bit, 最大503)

        ; ---- ベストと比較 (16bit) ----
        PUSH HL                 ; mm_score 保護
        LD   DE,(AI_BEST_SCORE)
        AND  A                  ; carry クリア
        SBC  HL,DE              ; mm_score - best (flags更新, HL消費)
        POP  HL                 ; mm_score 復元 (POP は flags を変化させない)
        JR   C,AMM_NEXTCOL      ; mm_score < best -> スキップ
        JR   Z,AMM_NEXTCOL      ; mm_score == best -> スキップ（同点は先着優先）

        ; 新ベスト更新
        LD   (AI_BEST_SCORE),HL
        LD   A,B
        LD   (AI_BEST_ROW),A
        LD   A,C
        LD   (AI_BEST_COL),A

AMM_NEXTCOL:
        INC  C
        LD   A,C
        CP   8
        JR   C,AMM_COL

        INC  B
        LD   A,B
        CP   8
        JP   C,AMM_ROW

        ; ---- 合法手があったか？ ----
        LD   A,(AI_BEST_ROW)
        CP   0FFH
        RET  Z                  ; なし -> DoTurn 側で PASS 処理

        ; ---- ベスト手を実際に打つ ----
        LD   B,A                ; B = best row
        LD   A,(AI_BEST_COL)
        LD   C,A                ; C = best col
        LD   A,(AiSide)
        LD   D,A
        CALL ApplyMove

        ; ---- 表示 "AI moves to XX" ----
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


; ---------------------------------------------------------
; HasAnyLegalMove
; Input:
;   D = player
; Output:
;   A = 1 あり / 0 なし
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


; =========================================================
; Turn control: DecideFirstTurn / DoTurn
; =========================================================
DecideFirstTurn:
        LD   DE,MsgChooseOrder
        CALL PrintString

        ; SW0(bit0)=先手(X) / SW2(bit2)=後手(O)
        ; SIOA キーボード: '1'=先手 / '2'=後手
DFT_WAIT:
        ; SIOA ノンブロッキングポーリング
        XOR  A
        OUT  (SIOA_CTL),A
        IN   A,(SIOA_CTL)
        BIT  0,A
        JR   NZ,DFT_SIOA

        ; PIOB ポーリング
        IN   A,(PIOB_DATA)
        CPL
        AND  05H                ; bit0=SW0(先手), bit2=SW2(後手)
        JR   Z,DFT_WAIT

        CALL Debounce           ; AF は破壊されない (BC のみ)
        IN   A,(PIOB_DATA)      ; チャタリング確認
        CPL
        AND  05H
        JR   Z,DFT_WAIT

        LD   E,A                ; 押されたボタンを退避

DFT_SW_REL:
        CALL Debounce
        IN   A,(PIOB_DATA)
        CPL
        AND  05H
        JR   NZ,DFT_SW_REL     ; 離し待ち

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
        CALL AIset
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
