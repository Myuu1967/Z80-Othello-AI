; =========================================================
; Super AKI-80 8x8 Othello  [ROM standalone version]
;                            [Minimax depth-3 + Alpha-Beta + Move Ordering + Evaluation]
;                            [Player input: PIOB switch SW0-SW4]
; ---------------------------------------------------------
; Target : Z80 (Super AKI-80)  ROM boot (28C256 / 0000H-7FFFH)
; Serial : SIOA  DAT=18h  CTL=19h  (InitSIOA called at reset)
; PIO-B  : CMD=1Fh  DATA=1Eh  SW0:PB0(Lt) SW1:PB1(Rt) SW2:PB2(Up) SW3:PB3(Dn) SW4:PB4(Enter)
; RAM    : 8000H-  (BOARD/変数)
;
; vs MM2_AB_D3: ROM化対応
;   - ORG 0000H (リセットベクタ) + InitSIOA 追加
;   - 変数/BOARD を ORG 8000H (RAM) セクションに移動
;   - BOARD_INIT (初期盤面定数) は ROM 側に保持
;   - START: CALL InitSIOA + CALL InitBoard を追加
;   - RST 00H (quit) → 0000H = JP START でリセット再起動
;
; Apr 22nd, 2026 ROM standalone 化 -> MM2_AB_ROM.ASM
; =========================================================

        ORG  0000H
        JP   START          ; リセットベクタ

; ---------------------------------------------------------
; InitCTC3
;   CTC3 (port 13H) をタイマーモードで起動
;   10MHz / 16 / 4 = 156250Hz → SIOA RXCA/TXCA へ供給
;   SIOA x16モードで 156250/16 ≈ 9600bps
; Destroys: AF
; ---------------------------------------------------------
InitCTC3:
        LD   A,17H              ; タイマーモード / プリスケーラ/16 / TC続く / リセット
        OUT  (13H),A            ; CTC3 コントロールワード
        LD   A,04H              ; 時定数 = 4 (/4) → タイマー起動
        OUT  (13H),A            ; CTC3 時定数
        RET

; ---------------------------------------------------------
; InitSIOA
;   SIOA を 9600bps/8bit/1stop で初期化
;   CTC3 起動後に呼ぶこと
; Destroys: AF, BC, HL
; ---------------------------------------------------------
InitSIOA:
        LD   HL,SIOA_INIT_TBL
        LD   B,9
        LD   C,19H              ; SIOA_CTL
        OTIR
        RET

SIOA_INIT_TBL:
        DEFB 18H    ; WR0: チャンネルリセット
        DEFB 04H    ; WR0: WR4 選択
        DEFB 44H    ; WR4: x16クロック, 1ストップ, パリティなし
        DEFB 03H    ; WR0: WR3 選択
        DEFB 0C1H   ; WR3: 受信有効, 8bit
        DEFB 05H    ; WR0: WR5 選択
        DEFB 6AH    ; WR5: 送信有効, 8bit, RTS
        DEFB 01H    ; WR0: WR1 選択
        DEFB 00H    ; WR1: 割り込みなし


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

; depth切り替え閾値
D3_THRESHOLD EQU 25         ; 空き < 25 → depth-3 / 空き >= 25 → depth-2


; =========================================================
; Strings (0-terminated)  ← ROM 領域
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

MSG_RETRYQ:     DEFM CR,LF,"r:Retry or q:Quit ? ",0
MSG_BYE:        DEFM CR,LF,"Bye.",CR,LF,0

MSG_PASSEND:    DEFM CR,LF,"Game ended by consecutive passes.",CR,LF,0

MSG_STARTUP:    DEFM CR,LF,"Reversi AI Started",CR,LF,CR,LF,0

; =========================================================
; Tables  ← ROM 領域
; =========================================================
STONE_CHAR:
        DEFB '.', 'X', 'O'

; ---------------------------------------------------------
; POS_WEIGHT  (64 bytes, row-major 8x8)
;   GA最適化テーブル (2026-04-22, depth-2 AI同士 50世代)
; ---------------------------------------------------------
POS_WEIGHT:
        ;       A    B    C    D    E    F    G    H
        DEFB  128,   3,  17,  30,  30,  17,   3, 128  ; 1
        DEFB    3,   1,  36,  15,  15,  36,   1,   3  ; 2
        DEFB   17,  36,  18,  29,  29,  18,  36,  17  ; 3
        DEFB   30,  15,  29,   1,   1,  29,  15,  30  ; 4
        DEFB   30,  15,  29,   1,   1,  29,  15,  30  ; 5
        DEFB   17,  36,  18,  29,  29,  18,  36,  17  ; 6
        DEFB    3,   1,  36,  15,  15,  36,   1,   3  ; 7
        DEFB  128,   3,  17,  30,  30,  17,   3, 128  ; 8

; ムーブオーダリング用: POS_WEIGHT降順のマスoffset一覧
POS_ORDER:
        ; weight=128: コーナー
        DEFB  0,  7, 56, 63
        ; weight=36: near_x (C2/B3 etc.)
        DEFB 10, 13, 50, 53, 17, 22, 41, 46
        ; weight=30: 辺中央 (D1/A4 etc.)
        DEFB  3,  4, 59, 60, 24, 31, 32, 39
        ; weight=29: inner2 (D3/C4 etc.)
        DEFB 19, 20, 43, 44, 26, 29, 34, 37
        ; weight=18: inner (C3 etc.)
        DEFB 18, 21, 42, 45
        ; weight=17: 辺 (C1/A3 etc.)
        DEFB  2,  5, 58, 61, 16, 23, 40, 47
        ; weight=15: 辺内側 (D2/B4 etc.)
        DEFB 11, 12, 51, 52, 25, 30, 33, 38
        ; weight=3: Cマス (B1/A2 etc.)
        DEFB  1,  6, 57, 62,  8, 15, 48, 55
        ; weight=1: Xマス + 中央
        DEFB  9, 14, 49, 54, 27, 28, 35, 36

; 安定石コーナーテーブル (3バイト x 4コーナー)
CS_CORNER_TBL:
        DEFB  0, 01H, 01H   ; A1: dc=+1(右), dr=+1(下)
        DEFB  7, 0FFH,01H   ; H1: dc=-1(左), dr=+1(下)
        DEFB 56, 01H, 0FFH  ; A8: dc=+1(右), dr=-1(上)
        DEFB 63, 0FFH,0FFH  ; H8: dc=-1(左), dr=-1(上)

DIR_DR:
        DEFB -1,-1,-1, 0,0, 1,1,1
DIR_DC:
        DEFB -1, 0, 1,-1,1,-1,0,1

; ---------------------------------------------------------
; BOARD_INIT  ← ROM 領域 (読み取り専用初期盤面)
;   InitBoard が RAM の BOARD へ LDIR でコピーする
; ---------------------------------------------------------
BOARD_INIT:
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,WHITE,BLACK,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,BLACK,WHITE,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY,EMPTY


; =========================================================
; Main entry / game loop
; =========================================================

START:
        LD   SP,0FFF0H
        DI
        CALL InitCTC3           ; CTC3 起動 (SIOA ボーレートクロック供給)
        CALL InitSIOA           ; SIOA 初期化

        CALL InitPIOB           ; PIOB: SW0-SW4 入力モード
        CALL InitBoard          ; RAM の BOARD を初期値でクリア

        LD   DE,MSG_STARTUP
        CALL PrintString

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
        JR   GO_CHK

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
        RST  00H                ; 0000H = JP START → リセット再起動
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
; StartTimer / StopTimer  (PIOA D7 → Pico 計測)
; ---------------------------------------------------------
StartTimer:
        PUSH AF
        LD   A,00001111B
        OUT  (PIOA_CMD),A
        LD   A,0
        OUT  (PIOA_DATA),A
        LD   A,80H
        OUT  (PIOA_DATA),A
        POP  AF
        RET

StopTimer:
        PUSH AF
        LD   A,0
        OUT  (PIOA_DATA),A
        POP  AF
        RET


; =========================================================
; PIOB スイッチ入力 ルーティン群
; =========================================================

; ---------------------------------------------------------
; InitPIOB
; ---------------------------------------------------------
InitPIOB:
        PUSH AF
        LD   A,0FFH
        OUT  (PIOB_CMD),A
        LD   A,0FFH
        OUT  (PIOB_CMD),A
        POP  AF
        RET


; ---------------------------------------------------------
; Debounce  ≈15ms
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

SaveBoard:
        PUSH HL
        PUSH DE
        PUSH BC
        PUSH AF
        EX   DE,HL
        LD   HL,BOARD
        LD   BC,BOARD_BYTES
        LDIR
        POP  AF
        POP  BC
        POP  DE
        POP  HL
        RET

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
; AI  (Minimax depth-3 + Alpha-Beta + Move Ordering)
; =========================================================

; ---------------------------------------------------------
; CountAllFlips
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
; OppBestScore  [depth-1版]
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
; OppBestScore_d2  [depth-2版 + α-β]
; ---------------------------------------------------------
OppBestScore_d2:
        XOR  A
        LD   (OBS_COUNT),A
        LD   A,0FFH
        LD   (OBS2_MIN_AI),A

        XOR  A
        LD   (OD2_IDX),A

OD2_LOOP:
        LD   A,(OD2_IDX)
        CP   64
        JP   NC,OD2_END
        LD   HL,POS_ORDER
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)
        LD   E,A
        AND  07H
        LD   C,A
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A

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
        LD   A,(ID2_IDX)
        CP   64
        JP   NC,ID2_END
        LD   HL,POS_ORDER
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)
        LD   E,A
        AND  07H
        LD   C,A
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A

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
        ; α-cutoff
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
; OppBestScore_d3  [depth-3版 + α-β]
; ---------------------------------------------------------
OppBestScore_d3:
        XOR  A
        LD   (OBS_COUNT),A
        LD   A,0FFH
        LD   (OBS2_MIN_AI),A

        XOR  A
        LD   (OD2_IDX),A

OD3_LOOP:
        LD   A,(OD2_IDX)
        CP   64
        JP   NC,OD3_END
        LD   HL,POS_ORDER
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)
        LD   E,A
        AND  07H
        LD   C,A
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A

        LD   A,(HumSide)
        LD   D,A
        PUSH BC
        PUSH DE
        CALL CountAllFlips
        POP  DE
        POP  BC

        OR   A
        JP   Z,OD3_NEXTCOL

        LD   HL,OBS_COUNT
        INC  (HL)

        PUSH BC
        LD   HL,BOARD_SAVE2
        CALL SaveBoard
        LD   A,(HumSide)
        LD   D,A
        CALL ApplyMove

        CALL AiBestScore_d3

        LD   A,(D3_AI_BEST)
        LD   HL,OBS2_MIN_AI
        CP   (HL)
        JR   NC,OD3_RESTORE
        LD   (HL),A

OD3_RESTORE:
        LD   HL,BOARD_SAVE2
        CALL RestoreBoard
        POP  BC

OD3_NEXTCOL:
        LD   A,(OD2_IDX)
        INC  A
        LD   (OD2_IDX),A
        JP   OD3_LOOP

OD3_END:
        LD   A,(OBS_COUNT)
        OR   A
        JR   NZ,OD3_RETURN
        XOR  A
        RET

OD3_RETURN:
        LD   A,0FFH
        LD   HL,OBS2_MIN_AI
        SUB  (HL)
        RET


; ---------------------------------------------------------
; ID3_LOOP  [depth-3 leaf: OPP視点]
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
        LD   A,(HL)
        LD   E,A
        AND  07H
        LD   C,A
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A

        LD   A,(HumSide)
        LD   D,A
        PUSH BC
        PUSH DE
        CALL CountAllFlips
        POP  DE
        POP  BC

        OR   A
        JR   Z,ID3_NEXT

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

        LD   HL,OBS3_BEST
        CP   (HL)
        JR   C,ID3_NEXT
        JR   Z,ID3_NEXT
        LD   (HL),A

        ; α-cutoff
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
; ---------------------------------------------------------
AiBestScore_d3:
        XOR  A
        LD   (D3_AI_BEST),A

        XOR  A
        LD   (ID2_IDX),A

AB_D3_LOOP:
        LD   A,(ID2_IDX)
        CP   64
        JP   NC,AB_D3_END

        LD   HL,POS_ORDER
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)
        LD   E,A
        AND  07H
        LD   C,A
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A

        LD   A,(AiSide)
        LD   D,A
        PUSH BC
        PUSH DE
        CALL CountAllFlips
        POP  DE
        POP  BC

        OR   A
        JP   Z,AB_D3_NEXT

        PUSH BC

        LD   HL,BOARD_SAVE3
        CALL SaveBoard

        LD   A,(AiSide)
        LD   D,A
        CALL ApplyMove

        LD   A,0FFH
        LD   HL,D3_AI_BEST
        SUB  (HL)
        LD   (D3_AI_ALPHA),A

        CALL ID3_LOOP

        LD   HL,BOARD_SAVE3
        CALL RestoreBoard

        LD   A,0FFH
        LD   HL,OBS3_BEST
        SUB  (HL)

        LD   HL,D3_AI_BEST
        CP   (HL)
        JR   C,AB_D3_POP
        JR   Z,AB_D3_POP
        LD   (HL),A

        ; β-cutoff
        LD   HL,OBS2_MIN_AI
        CP   (HL)
        POP  BC
        JP   NC,AB_D3_END
        JP   AB_D3_NEXT

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
; ---------------------------------------------------------
CountStable:
        LD   A,D
        LD   (CS_SIDE),A
        XOR  A
        LD   (CS_COUNT),A

        LD   HL,CS_CORNER_TBL
        LD   B,4

CS_CRN_LOOP:
        PUSH BC
        PUSH HL

        LD   A,(HL)
        LD   (CS_OFF),A
        INC  HL
        LD   A,(HL)
        LD   (CS_DC),A
        INC  HL
        LD   A,(HL)
        LD   (CS_DR),A

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

        LD   HL,CS_COUNT
        INC  (HL)

        LD   A,(CS_OFF)
        LD   E,A
        AND  07H
        LD   C,A
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A

CS_ROW_LOOP:
        LD   A,C
        LD   E,A
        LD   A,(CS_DC)
        ADD  A,E
        LD   C,A
        CP   8
        JP   NC,CS_COL_INIT
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
        JP   NZ,CS_COL_INIT
        LD   HL,CS_COUNT
        INC  (HL)
        JP   CS_ROW_LOOP

CS_COL_INIT:
        LD   A,(CS_OFF)
        LD   E,A
        AND  07H
        LD   C,A
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A

CS_COL_LOOP:
        LD   A,B
        LD   E,A
        LD   A,(CS_DR)
        ADD  A,E
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
        POP  HL
        LD   DE,3
        ADD  HL,DE
        POP  BC
        DEC  B
        JP   NZ,CS_CRN_LOOP

        LD   A,(CS_COUNT)
        RET


; ---------------------------------------------------------
; EG_GetSaveAddr
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
        SUB  2
        LD   C,A
        LD   B,0
        SLA  C
        SLA  C
        SLA  C
        SLA  C
        SLA  C
        SLA  C
        LD   HL,BOARD_EG_SAVES
        ADD  HL,BC
        RET


; ---------------------------------------------------------
; AIset  (Minimax depth-2/3 + α-β + Move Ordering + Eval)
; ---------------------------------------------------------
AIset:
        LD   HL,0000H
        LD   (AI_BEST_SCORE),HL
        LD   A,0FFH
        LD   (AI_BEST_ROW),A

        CALL CountEmpty
        LD   (EMPTY_CACHE),A

        CP   EARLY_GAME
        JP   NC,AEV_EARLY
        CP   MID_GAME
        JP   NC,AEV_MID
        LD   A,2
        JP   AEV_SET_PHASE
AEV_EARLY:
        LD   A,0
        JP   AEV_SET_PHASE
AEV_MID:
        LD   A,1
AEV_SET_PHASE:
        LD   (GAME_PHASE),A

        LD   A,(EMPTY_CACHE)
        CP   D3_THRESHOLD
        LD   A,0
        JR   NC,AMM_SET_DEPTH
        INC  A
AMM_SET_DEPTH:
        LD   (USE_DEPTH3),A

        XOR  A
        LD   (AMM_IDX),A

AMM_LOOP:
        LD   A,(AMM_IDX)
        CP   64
        JP   NC,AMM_END
        LD   HL,POS_ORDER
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   A,(HL)
        LD   E,A
        AND  07H
        LD   C,A
        LD   A,E
        RRCA
        RRCA
        RRCA
        AND  07H
        LD   B,A

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
        LD   A,(USE_DEPTH3)
        OR   A
        JP   Z,AMM_CALL_D2
        CALL OppBestScore_d3
        JP   AMM_AFTER_OBS
AMM_CALL_D2:
        CALL OppBestScore_d2
AMM_AFTER_OBS:

        PUSH AF
        LD   A,(AiSide)
        LD   D,A
        CALL CountMobility

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

        LD   L,A
        LD   H,0

        LD   A,0FFH
        SUB  E
        LD   E,A
        LD   D,0
        ADD  HL,DE

        LD   A,(GAME_PHASE)
        CP   1
        JP   Z,AMM_EVAL_MID
        CP   2
        JP   Z,AMM_EVAL_LATE

AMM_EVAL_EARLY:
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
        ADD  HL,HL
        ADD  HL,HL
        LD   D,H
        LD   E,L
        ADD  HL,HL
        ADD  HL,DE
        LD   D,H
        LD   E,L
        POP  HL
        ADD  HL,DE

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
        ADD  HL,HL
        LD   B,H
        LD   C,L
        ADD  HL,HL
        ADD  HL,HL
        ADD  HL,HL
        ADD  HL,HL
        ADD  HL,HL
        OR   A
        SBC  HL,BC
        LD   D,H
        LD   E,L
        POP  HL
        ADD  HL,DE
        POP  BC
        JP   AMM_SCORE_CMP

AMM_EVAL_MID:
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
        ADD  HL,HL
        ADD  HL,HL
        ADD  HL,HL
        LD   D,H
        LD   E,L
        POP  HL
        ADD  HL,DE

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
        ADD  HL,HL
        LD   B,H
        LD   C,L
        ADD  HL,HL
        ADD  HL,HL
        ADD  HL,HL
        LD   D,H
        LD   E,L
        ADD  HL,HL
        ADD  HL,DE
        ADD  HL,BC
        LD   D,H
        LD   E,L
        POP  HL
        ADD  HL,DE
        POP  BC
        JP   AMM_SCORE_CMP

AMM_EVAL_LATE:
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
        ADD  HL,HL
        ADD  HL,HL
        LD   D,H
        LD   E,L
        POP  HL
        ADD  HL,DE

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
        ADD  HL,HL
        LD   B,H
        LD   C,L
        ADD  HL,HL
        ADD  HL,HL
        ADD  HL,HL
        ADD  HL,HL
        ADD  HL,HL
        OR   A
        SBC  HL,BC
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


; ---------------------------------------------------------
; SearchFull  (negamax + α-β)
; ---------------------------------------------------------
SearchFull:
        PUSH DE
        CALL HasAnyLegalMove
        POP  DE
        OR   A
        JR   NZ,SF_HasMove

        LD   A,3
        SUB  D
        LD   D,A
        PUSH DE
        CALL HasAnyLegalMove
        POP  DE
        OR   A
        JR   NZ,SF_Pass

        CALL CountStones
        LD   A,(SF_SIDE_TMP)
        CP   BLACK
        JR   Z,SF_CurrIsBlack
SF_CurrIsWhite:
        LD   A,C
        SUB  B
        RET
SF_CurrIsBlack:
        LD   A,B
        SUB  C
        RET

SF_Pass:
        LD   A,(EG_DEPTH)
        INC  A
        LD   (EG_DEPTH),A
        LD   A,D
        LD   (SF_SIDE_TMP),A
        CALL SearchFull
        PUSH AF
        LD   A,(EG_DEPTH)
        DEC  A
        LD   (EG_DEPTH),A
        LD   A,(SF_SIDE_TMP)
        LD   E,A
        LD   A,3
        SUB  E
        LD   (SF_SIDE_TMP),A
        POP  AF
        NEG
        RET

SF_HasMove:
        LD   A,81H
        LD   (EG_BESTSCORE),A

        PUSH BC
        LD   HL,SF_ALPHA_TBL
        LD   A,(EG_DEPTH)
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   (HL),81H
        POP  BC

        LD   B,0
SF_ROW:
        LD   C,0
SF_COL:
        LD   A,(SF_SIDE_TMP)
        LD   D,A

        PUSH BC
        PUSH DE
        CALL CountAllFlips
        POP  DE
        POP  BC
        OR   A
        JR   Z,SF_NEXTCOL

        PUSH BC
        LD   A,(EG_DEPTH)
        CALL EG_GetSaveAddr
        CALL SaveBoard

        LD   A,(SF_SIDE_TMP)
        LD   D,A
        CALL ApplyMove

        LD   A,(EG_DEPTH)
        INC  A
        LD   (EG_DEPTH),A
        LD   A,(SF_SIDE_TMP)
        LD   E,A
        LD   A,3
        SUB  E
        LD   D,A
        LD   (SF_SIDE_TMP),A

        LD   A,(EG_BESTSCORE)
        PUSH AF

        CALL SearchFull
        NEG
        LD   E,A

        POP  AF
        LD   (EG_BESTSCORE),A

        LD   A,(EG_DEPTH)
        DEC  A
        LD   (EG_DEPTH),A
        LD   A,(SF_SIDE_TMP)
        LD   B,A
        LD   A,3
        SUB  B
        LD   (SF_SIDE_TMP),A

        LD   A,(EG_DEPTH)
        CALL EG_GetSaveAddr
        CALL RestoreBoard

        POP  BC

        LD   A,(EG_BESTSCORE)
        CP   81H
        JR   Z,SF_DO_UPDATE
        LD   D,A
        LD   A,E
        SUB  D
        JP   M,SF_NEXTCOL
        JR   Z,SF_NEXTCOL
SF_DO_UPDATE:
        LD   A,E
        LD   (EG_BESTSCORE),A

        PUSH BC
        LD   HL,SF_ALPHA_TBL
        LD   A,(EG_DEPTH)
        LD   C,A
        LD   B,0
        ADD  HL,BC
        LD   (HL),E
        DEC  HL
        LD   A,(HL)
        NEG
        LD   D,A
        LD   A,E
        SUB  D
        POP  BC
        JP   P,SF_RET
        JR   Z,SF_RET

SF_NEXTCOL:
        INC  C
        LD   A,C
        CP   8
        JP   C,SF_COL

        INC  B
        LD   A,B
        CP   8
        JP   C,SF_ROW

        LD   A,(EG_BESTSCORE)
SF_RET:
        RET


; ---------------------------------------------------------
; AIset_EG  (終盤完全読み外ループ)
; ---------------------------------------------------------
AIset_EG:
        LD   A,81H
        LD   (EG_BESTSCORE),A
        LD   A,0FFH
        LD   (EG_BESTROW),A

        LD   B,0
AEGM_ROW:
        LD   C,0
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

        PUSH BC
        LD   HL,BOARD_SAVE1
        CALL SaveBoard
        LD   A,(AiSide)
        LD   D,A
        CALL ApplyMove

        LD   A,1
        LD   (EG_DEPTH),A
        LD   A,(EG_BESTSCORE)
        LD   (SF_ALPHA_TBL),A
        PUSH AF
        LD   A,(HumSide)
        LD   D,A
        LD   (SF_SIDE_TMP),A
        CALL SearchFull
        NEG
        LD   E,A

        LD   HL,BOARD_SAVE1
        CALL RestoreBoard
        POP  AF
        LD   (EG_BESTSCORE),A
        POP  BC

        LD   A,(EG_BESTROW)
        CP   0FFH
        JR   Z,AEGM_UPDATE
        LD   A,(EG_BESTSCORE)
        LD   D,A
        LD   A,E
        SUB  D
        JP   M,AEGM_NEXTCOL
        JR   Z,AEGM_NEXTCOL
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

        LD   A,(EG_BESTROW)
        CP   0FFH
        RET  Z

        LD   B,A
        LD   A,(EG_BESTCOL)
        LD   C,A
        LD   A,(AiSide)
        LD   D,A
        CALL ApplyMove

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

        CALL CountEmpty
        CP   ENDGAME_THRESHOLD + 1
        JR   NC,DT_AI_Normal

        CALL AIset_EG
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


; =========================================================
; RAM variables  (ORG 8000H)
; =========================================================
        ORG  8000H

; ---------------------------------------------------------
; 盤面バッファ
; ---------------------------------------------------------
BOARD:          DEFS BOARD_BYTES        ; 現在の盤面 (64B)
BOARD_SAVE1:    DEFS BOARD_BYTES        ; ply1 AIset 外ループ用
BOARD_SAVE2:    DEFS BOARD_BYTES        ; ply2 OppBestScore 外ループ用
BOARD_SAVE3:    DEFS BOARD_BYTES        ; ply3 AiBestScore_d3 ループ用
BOARD_EG_SAVES: DEFS BOARD_BYTES * 8   ; 終盤完全読み用 (512B)

; ---------------------------------------------------------
; I/O バッファ・表示用
; ---------------------------------------------------------
RXBUF:          DEFS BUF_MAX            ; GETLINE 受信バッファ
AImovePOS:      DEFS 3                  ; "XX\0" AI着手位置文字列

; ---------------------------------------------------------
; ゲーム状態
; ---------------------------------------------------------
AiSide:         DEFS 1
HumSide:        DEFS 1
TurnSide:       DEFS 1
PassStreak:     DEFS 1

; ---------------------------------------------------------
; IsLegalMove / TryDirCount / FlipDirN 作業用
; ---------------------------------------------------------
WORK_PLAYER:    DEFS 1
WORK_ROW:       DEFS 1
WORK_COL:       DEFS 1
TD_R:           DEFS 1
TD_C:           DEFS 1
TD_OPP:         DEFS 1
TD_DR:          DEFS 1
TD_DC:          DEFS 1
TD_COUNT:       DEFS 1
TD_N:           DEFS 1
AM_DIDFLIP:     DEFS 1

; ---------------------------------------------------------
; スイッチ入力カーソル
; ---------------------------------------------------------
PLR_COL:        DEFS 1
PLR_ROW:        DEFS 1

; ---------------------------------------------------------
; Minimax AI 作業用
; ---------------------------------------------------------
AI_BEST_ROW:    DEFS 1
AI_BEST_COL:    DEFS 1
AI_BEST_SCORE:  DEFS 2

OBS_BEST:       DEFS 1
OBS_COUNT:      DEFS 1
OBS2_MIN_AI:    DEFS 1
AI_MOB_COUNT:   DEFS 1

; ---------------------------------------------------------
; CountStable 作業用
; ---------------------------------------------------------
CS_SIDE:        DEFS 1
CS_COUNT:       DEFS 1
CS_OFF:         DEFS 1
CS_DC:          DEFS 1
CS_DR:          DEFS 1
AI_STABLE:      DEFS 1
OPP_STABLE:     DEFS 1

; ---------------------------------------------------------
; フェーズ管理・depth選択
; ---------------------------------------------------------
GAME_PHASE:     DEFS 1
EMPTY_CACHE:    DEFS 1
USE_DEPTH3:     DEFS 1

; ---------------------------------------------------------
; ムーブオーダリング用ループインデックス
; ---------------------------------------------------------
AMM_IDX:        DEFS 1
OD2_IDX:        DEFS 1
ID2_IDX:        DEFS 1
LD3_IDX:        DEFS 1

; ---------------------------------------------------------
; depth-3 作業用
; ---------------------------------------------------------
D3_AI_BEST:     DEFS 1
D3_AI_ALPHA:    DEFS 1
OBS3_BEST:      DEFS 1

; ---------------------------------------------------------
; 終盤完全読み用
; ---------------------------------------------------------
EG_DEPTH:       DEFS 1
EG_BESTSCORE:   DEFS 1
EG_BESTROW:     DEFS 1
EG_BESTCOL:     DEFS 1
EG_ALPHA:       DEFS 1
SF_SIDE_TMP:    DEFS 1
SF_ALPHA_TBL:   DEFS 10

        END  START
