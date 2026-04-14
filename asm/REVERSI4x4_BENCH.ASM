; =========================================================
; Super AKI-80 4x4 Othello  --  AI vs AI Benchmark
; ---------------------------------------------------------
; Target : Z80 (Super AKI-80)
; Serial : SIOA  DAT=18h  CTL=19h  (SIO init by monitor)
;
; 変更箇所: START / MAIN_LOOP / GameOver のみ
;           全サブルーチンは元コードをそのまま使用
;
; 動作概要:
;   BM_COUNT 回だけ AI(BLACK) vs AI(WHITE) を自動対戦し
;   終了後に  Games / BLACK wins / WHITE wins / Draw を表示
;   その後 r:もう一度 / q:終了 を受け付ける
; =========================================================

        ORG 8000H
        JP  START


; =========================================================
; I/O ports (SIOA)
; =========================================================
SIOA_DAT        EQU 18H
SIOA_CTL        EQU 19H


; =========================================================
; I/O ports (CTC)
; =========================================================
CTC_CH0         EQU 10H
CTC_CH1         EQU 11H
CTC_CH2         EQU 12H
CTC_CH3         EQU 13H

CTC_BENCH       EQU CTC_CH0
CTC_TC          EQU 0FFH        ; 時定数 255 → 1周期=255×1.6μs=408μs
CTC_CTRL        EQU 10001001B   ; INT enable / timer / ÷16 / TC follows
CTC_STOP        EQU 00000011B   ; INT disable / reset


; =========================================================
; PIO 
; =========================================================
PIOA_DATA       EQU 1CH
PIOA_CMD        EQU 1DH

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
BOARD_W         EQU 4
BOARD_H         EQU 4
BOARD_BYTES     EQU BOARD_W*BOARD_H

EMPTY           EQU 0
BLACK           EQU 1
WHITE           EQU 2

DIR_CNT         EQU 8

BUF_MAX         EQU 64
LINE_MAX        EQU 20

; ---------------------------------------------------------
; ★ 対戦回数設定
;    10 / 50 / 100 など自由に変更してください
; ---------------------------------------------------------
BENCH_TOTAL     EQU 50


; =========================================================
; Strings (0-terminated)  ※元コードと同一
; =========================================================
COL_HEADER:     DEFM "  A B C D",0
MSG_NEWLINE:    DEFM CR,LF,0

MSG_PROMPT:     DEFM "Your move (A1-D4) > ",0
MSG_BADFMT:     DEFM CR,LF,"Bad input. Use A1-D4.",CR,LF,0
MSG_ILLEGAL:    DEFM CR,LF,"NG (illegal move).",CR,LF,0
MSG_ILLEGAL2:   DEFM CR,LF,"NG2 (illegal move).",CR,LF,0

MSG_GAMEOVER:   DEFM CR,LF,"GAME OVER",CR,LF,0

MsgAiDecides:   DEFM "AI decides who goes first...",CR,LF,0
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

; ★ ベンチマーク専用メッセージ
MSG_BENCH_HDR:  DEFM CR,LF,"=== AI vs AI Benchmark ===",CR,LF,0
MSG_BENCH_RUN:  DEFM "Game #",0
MSG_BENCH_SEP:  DEFM "/",0
MSG_BENCH_NL:   DEFM CR,LF,0
MSG_RESULT_HDR: DEFM CR,LF,"--- Results ---",CR,LF,0
MSG_GAMES:      DEFM "Games : ",0
MSG_WIN_B:      DEFM "BLACK : ",0
MSG_WIN_W:      DEFM "WHITE : ",0
MSG_DRAWS:      DEFM "Draw  : ",0

MSG_MOVES:      DEFM " Moves:",0
MSG_TOTALMOV:   DEFM "Total moves : ",0
MSG_TICKS:      DEFM "Total ticks : ",0
MSG_TICK_UNIT:  DEFM " (1tick=1.6us)",CR,LF,0

; =========================================================
; Tables  ※元コードと同一
; =========================================================
STONE_CHAR:
        DEFB '.', 'X', 'O'

DIR_DR:
        DEFB -1,-1,-1, 0,0, 1,1,1
DIR_DC:
        DEFB -1, 0, 1,-1,1,-1,0,1


; =========================================================
; Board  ※元コードと同一
; =========================================================
BOARD:
        DEFB EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,WHITE,BLACK,EMPTY
        DEFB EMPTY,BLACK,WHITE,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY

BOARD_INIT:
        DEFB EMPTY,EMPTY,EMPTY,EMPTY
        DEFB EMPTY,WHITE,BLACK,EMPTY
        DEFB EMPTY,BLACK,WHITE,EMPTY
        DEFB EMPTY,EMPTY,EMPTY,EMPTY


; =========================================================
; Variables  ※元コードと同一
; =========================================================
RXBUF:          DEFS BUF_MAX

AiSide:         DEFB 0
HumSide:        DEFB 0
TurnSide:       DEFB 0

PassStreak:     DEFB 0

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

AM_DIDFLIP:     DEFB 0

; ★ ベンチマーク集計変数
BM_GAME:        DEFB 0          ; 現在の試合番号 (1..BENCH_TOTAL)
BM_WIN_B:       DEFB 0          ; BLACK 勝利数
BM_WIN_W:       DEFB 0          ; WHITE 勝利数
BM_DRAW:        DEFB 0          ; 引き分け数

BM_MOVES_CUR:   DEFB 0          ; そのゲームの手数
BM_MOVES_LO:    DEFB 0          ; 合計手数 L
BM_MOVES_HI:    DEFB 0          ; 合計手数 H

; 総tick数 (32bit)
BM_TICK0:       DEFB 0          ; LSB
BM_TICK1:       DEFB 0
BM_TICK2:       DEFB 0
BM_TICK3:       DEFB 0          ; MSB

CTC_OVF:        DEFB 0          ; オーバーフロー回数 (割り込みごとにインクリメント)
CTC_REMAIN:     DEFB 0          ; StopTimer時のCTC残カウント値
CTC_TOTAL:      DEFW 0          ; 総ティック数 = OVF*256 + (255-REMAIN)
TIMER_ACTIVE:   DEFB 0          ; 1=タイマー動作中, 0=停止中
CTC_ACCUM:      DEFW 0          ; 区間累積ティック

; =========================================================
; ★ START  (メインルーチン全面変更)
; =========================================================
START:
        LD   SP,0FFF0H
        DI

        ; ヘッダ表示
        LD   DE,MSG_BENCH_HDR
        CALL PrintString

        ; ベンチマーク開始
BENCH_START:
        ; 集計をゼロクリア
        XOR  A
        LD   (BM_GAME),A
        LD   (BM_WIN_B),A
        LD   (BM_WIN_W),A
        LD   (BM_DRAW),A
        LD   (BM_MOVES_CUR),A
        LD   (BM_MOVES_LO),A
        LD   (BM_MOVES_HI),A
        LD   (BM_TICK0),A
        LD   (BM_TICK1),A
        LD   (BM_TICK2),A
        LD   (BM_TICK3),A
        LD   HL,0000H
        LD   (CTC_ACCUM),HL

        CALL StartTimer


; ---------------------------------------------------------
; BENCH_NEXT : 1ゲーム開始
; ---------------------------------------------------------
BENCH_NEXT:
        ; 試合番号をインクリメント
        LD   A,(BM_GAME)
        INC  A
        LD   (BM_GAME),A

        ; 上限チェック (BM_GAME > BENCH_TOTAL なら結果表示へ)
        CP   BENCH_TOTAL+1
        JP   NC,BENCH_SHOW

        ; "Game #nn/99" を表示
        LD   DE,MSG_BENCH_RUN
        CALL PrintString
        LD   A,(BM_GAME)
        CALL PrintDec2
        LD   DE,MSG_BENCH_SEP
        CALL PrintString
        LD   A,BENCH_TOTAL
        CALL PrintDec2
        LD   DE,MSG_BENCH_NL
        CALL PrintString

        ; ボードリセット
        CALL InitBoard

        ; そのゲームの手数クリア
        XOR  A
        LD   (BM_MOVES_CUR),A

        ; 両方AI化の初期状態
        LD   A,BLACK
        LD   (AiSide),A
        LD   A,WHITE
        LD   (HumSide),A
        LD   A,BLACK
        LD   (TurnSide),A


; ---------------------------------------------------------
; BM_LOOP : 1ゲームのターンループ
; ---------------------------------------------------------
BM_LOOP:
        ; 経過tickを積算
        CALL BenchAccumTick

        ; AiSide を TurnSide に合わせる（両方AI化）
        LD   A,(TurnSide)
        LD   (AiSide),A

        ; 1手進める（またはパス）
        CALL DoTurn
        OR   A
        JR   NZ,BM_GAMEOVER        ; A=1 → 連続パスでゲーム終了

        ; DoTurn後 PassStreak==0 なら実際に手が打たれた → 手数カウント
        ; PassStreak>0 はパスだったので手数に含めない
        LD   A,(PassStreak)
        OR   A
        JR   NZ,BM_NO_MOVE

        LD   A,(BM_MOVES_CUR)
        INC  A
        LD   (BM_MOVES_CUR),A
        CALL AddTotalMoves1

BM_NO_MOVE:
        ; 満盤チェック
        CALL IsBoardFull
        OR   A
        JR   NZ,BM_GAMEOVER

        JR   BM_LOOP


; ---------------------------------------------------------
; BM_GAMEOVER : 1ゲーム終了 → 結果を集計
; ---------------------------------------------------------
BM_GAMEOVER:
        ; 念のため最後にも tick を積算
        CALL BenchAccumTick

        ; そのゲームの手数表示
        LD   DE,MSG_BENCH_RUN
        CALL PrintString
        LD   A,(BM_GAME)
        CALL PrintDec2
        LD   DE,MSG_MOVES
        CALL PrintString
        LD   A,(BM_MOVES_CUR)
        CALL PrintDec2
        CALL NEWLINE

        CALL CountStones           ; B=BLACK数, C=WHITE数

        LD   A,B
        CP   C
        JR   Z,BM_IS_DRAW
        JR   NC,BM_BLACK_WIN

BM_WHITE_WIN:
        LD   A,(BM_WIN_W)
        INC  A
        LD   (BM_WIN_W),A
        JR   BM_NEXT_GAME

BM_BLACK_WIN:
        LD   A,(BM_WIN_B)
        INC  A
        LD   (BM_WIN_B),A
        JR   BM_NEXT_GAME

BM_IS_DRAW:
        LD   A,(BM_DRAW)
        INC  A
        LD   (BM_DRAW),A

BM_NEXT_GAME:
        JP   BENCH_NEXT


; ---------------------------------------------------------
; BENCH_SHOW : 全試合終了 → 集計結果表示
; ---------------------------------------------------------
BENCH_SHOW:

        CALL BenchAccumTick

        LD   DE,MSG_RESULT_HDR
        CALL PrintString

        ; Games : nn
        LD   DE,MSG_GAMES
        CALL PrintString
        LD   A,BENCH_TOTAL
        CALL PrintDec2
        CALL NEWLINE

        ; BLACK : nn
        LD   DE,MSG_WIN_B
        CALL PrintString
        LD   A,(BM_WIN_B)
        CALL PrintDec2
        CALL NEWLINE

        ; WHITE : nn
        LD   DE,MSG_WIN_W
        CALL PrintString
        LD   A,(BM_WIN_W)
        CALL PrintDec2
        CALL NEWLINE

        ; Draw  : nn
        LD   DE,MSG_DRAWS
        CALL PrintString
        LD   A,(BM_DRAW)
        CALL PrintDec2
        CALL NEWLINE

        ; Total moves : nnnn
        LD   DE,MSG_TOTALMOV
        CALL PrintString
        CALL PrintTotalMoves
        CALL NEWLINE

        ; Total ticks : xxxxxxxx (1tick=1.6us)
        LD   DE,MSG_TICKS
        CALL PrintString
        CALL PrintTick32
        LD   DE,MSG_TICK_UNIT
        CALL PrintString


; ---------------------------------------------------------
; BS_ASK : r=もう一度 / q=終了
; ---------------------------------------------------------
BS_ASK:
        LD   DE,MSG_RETRYQ
        CALL PrintString

        CALL StopTimer

BS_WAIT:
        CALL GetChar
        CALL PutChar

        CP   'A'
        JR   C,BS_CHK
        CP   'Z'+1
        JR   NC,BS_CHK
        ADD  A,20H

BS_CHK:
        CP   'r'
        JR   Z,BS_RETRY
        CP   'q'
        JR   Z,BS_QUIT

        LD   A,BEL
        CALL PutChar
        JR   BS_WAIT

BS_RETRY:
        CALL NEWLINE
        JP   BENCH_START

BS_QUIT:
        CALL NEWLINE
        LD   DE,MSG_BYE
        CALL PrintString
        RST  00H
        HALT


; =========================================================
; 以下は元コードのサブルーチン群をそのまま貼り付ける
; (変更一切なし)
; =========================================================

; ---------------------------------------------------------
; InitBoard
; ---------------------------------------------------------
InitBoard:
        XOR  A
        LD   (PassStreak),A
        LD   HL,BOARD_INIT
        LD   DE,BOARD
        LD   BC,BOARD_BYTES
        LDIR
        RET

; ---------------------------------------------------------
; PrintBoard
; ---------------------------------------------------------
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
        LD   A,'5'
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

; ---------------------------------------------------------
; PutChar
; ---------------------------------------------------------
PutChar:
        PUSH AF
PC_WAITTX:
        IN   A,(SIOA_CTL)
        BIT  2,A
        JR   Z,PC_WAITTX
        POP  AF
        OUT  (SIOA_DAT),A
        RET

; ---------------------------------------------------------
; PrintString
; ---------------------------------------------------------
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

; ---------------------------------------------------------
; NEWLINE
; ---------------------------------------------------------
NEWLINE:
        LD   A,CR
        CALL PutChar
        LD   A,LF
        CALL PutChar
        RET

; ---------------------------------------------------------
; GetChar
; ---------------------------------------------------------
GetChar:
GC_WRX:
        XOR  A
        OUT  (SIOA_CTL),A
        IN   A,(SIOA_CTL)
        BIT  0,A
        JR   Z,GC_WRX
        IN   A,(SIOA_DAT)
        RET

; ---------------------------------------------------------
; GETLINE
; ---------------------------------------------------------
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
; ParseMove
; ---------------------------------------------------------
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
        CP   4
        JR   NC,PM_BEEPFAIL
        LD   B,A
        LD   A,(RXBUF+1)
        SUB  '1'
        CP   4
        JR   NC,PM_BEEPFAIL
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

; ---------------------------------------------------------
; PlayerMove
; ---------------------------------------------------------
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

; ---------------------------------------------------------
; AIset
; ---------------------------------------------------------
AIset:
        LD   A,(AiSide)
        LD   D,A
        LD   B,0
AI_ROW:
        LD   C,0
AI_COL:
        PUSH BC
        PUSH DE
        CALL IsLegalMove
        POP  DE
        POP  BC
        OR   A
        JR   Z,AI_NEXTCOL
        PUSH BC
        PUSH DE
        CALL ApplyMove
        POP  DE
        POP  BC
        LD   A,C
        ADD  A,'A'
        LD   (AImovePOS),A
        LD   A,B
        ADD  A,'1'
        LD   (AImovePOS+1),A
        LD   DE,AImoveMSG
        CALL PrintString
        LD   DE,AImovePOS
        CALL PrintString
        CALL NEWLINE
        RET
AI_NEXTCOL:
        INC  C
        LD   A,C
        CP   4
        JR   C,AI_COL
        INC  B
        LD   A,B
        CP   4
        JR   C,AI_ROW
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
        CP   4
        JR   C,HAM_COL
        INC  B
        LD   A,B
        CP   4
        JR   C,HAM_ROW
        XOR  A
        RET
HAM_FOUND:
        LD   A,1
        RET

; ---------------------------------------------------------
; OffsetToRowCol
; ---------------------------------------------------------
OffsetToRowCol:
        LD   A,C
        LD   B,A
        SRL  B
        SRL  B
        AND  3
        LD   C,A
        RET

; ---------------------------------------------------------
; RowColToOffset
; ---------------------------------------------------------
RowColToOffset:
        LD   A,B
        SLA  A
        SLA  A
        ADD  A,C
        LD   C,A
        RET

; ---------------------------------------------------------
; InRange
; ---------------------------------------------------------
InRange:
        BIT  7,B
        JR   NZ,IR_Fail
        LD   A,B
        CP   4
        JR   NC,IR_Fail
        BIT  7,C
        JR   NZ,IR_Fail
        LD   A,C
        CP   4
        JR   NC,IR_Fail
        LD   A,1
        RET
IR_Fail:
        XOR  A
        RET

; ---------------------------------------------------------
; PlaceAtOffset
; ---------------------------------------------------------
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

; ---------------------------------------------------------
; IsBoardFull
; ---------------------------------------------------------
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

; ---------------------------------------------------------
; TryDirCount
; ---------------------------------------------------------
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

; ---------------------------------------------------------
; IsLegalMove
; ---------------------------------------------------------
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

; ---------------------------------------------------------
; FlipDirN
; ---------------------------------------------------------
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

; ---------------------------------------------------------
; ApplyMove
; ---------------------------------------------------------
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

; ---------------------------------------------------------
; CountStones
; ---------------------------------------------------------
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

; ---------------------------------------------------------
; PrintDec2
; ---------------------------------------------------------
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
; PrintCounts
; ---------------------------------------------------------
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

; ---------------------------------------------------------
; ShowWinner
; ---------------------------------------------------------
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

; ---------------------------------------------------------
; DecideFirstTurn  ※呼ばれないが残しておく
; ---------------------------------------------------------
DecideFirstTurn:
        LD   DE,MsgAiDecides
        CALL PrintString
        LD   A,R
        AND  1
        JR   Z,DFT_AiFirst
DFT_HumFirst:
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
        LD   A,BLACK
        LD   (AiSide),A
        LD   A,WHITE
        LD   (HumSide),A
        LD   A,BLACK
        LD   (TurnSide),A
        LD   DE,MsgAiFirst
        CALL PrintString
        RET

; ---------------------------------------------------------
; DoTurn  ※変更なし
; ---------------------------------------------------------
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
        CALL PlayerMove
        JR   DT_SwitchReturn0
DT_DoAI:
        CALL AIset
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


        ; ---------------------------------------------------------
; AddTotalMoves1
;   16bit 合計手数を +1
; ---------------------------------------------------------
AddTotalMoves1:
        LD   HL,BM_MOVES_LO
        INC  (HL)
        RET  NZ
        INC  HL
        INC  (HL)
        RET


; ---------------------------------------------------------
; CTC_HANDLER (起動時に 38H へコピーされる割り込みハンドラ)
;   CTC CH0 オーバーフロー割り込みごとに CTC_OVF をインクリメント
; ---------------------------------------------------------
CTC_HANDLER:
        PUSH AF
        LD   A,(CTC_OVF)
        INC  A
        LD   (CTC_OVF),A
        POP  AF
        EI
        RETI
CTC_HANDLER_END:
CTC_HANDLER_SIZE EQU CTC_HANDLER_END - CTC_HANDLER


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

; ---------------------------------------------------------
; AccumTimer
;   TIMER_ACTIVE=1 であれば StopTimer して CTC_TOTAL を CTC_ACCUM に加算
;   TIMER_ACTIVE=0 なら何もしない (二重停止防止)
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
AccumTimer:
        LD   A,(TIMER_ACTIVE)
        OR   A
        RET  Z                  ; 既に停止済み → 何もしない
        XOR  A
        LD   (TIMER_ACTIVE),A   ; 動作中フラグ OFF
;       CALL StopTimer
        LD   HL,(CTC_ACCUM)
        LD   DE,(CTC_TOTAL)
        ADD  HL,DE
        LD   (CTC_ACCUM),HL
        RET


; ---------------------------------------------------------
; BenchAccumTick
;   AccumTimer → CTC_ACCUM (16bit) を BM_TICK (32bit) に加算
;              → CTC_ACCUM リセット → StartTimer
;   旧 BenchTimerPoll の代替。呼び出し間隔が 255tick を超えても正確。
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
BenchAccumTick:
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL

        CALL AccumTimer

        ; CTC_ACCUM (16bit HL) を BM_TICK (32bit) に加算
        LD   HL,(CTC_ACCUM)
        LD   DE,BM_TICK0
        LD   A,(DE)
        ADD  A,L
        LD   (DE),A
        INC  DE
        LD   A,(DE)
        ADC  A,H
        LD   (DE),A
        INC  DE
        LD   A,(DE)
        ADC  A,0
        LD   (DE),A
        INC  DE
        LD   A,(DE)
        ADC  A,0
        LD   (DE),A

        ; CTC_ACCUM リセット
        LD   HL,0000H
        LD   (CTC_ACCUM),HL

;        CALL StartTimer

        POP  HL
        POP  DE
        POP  BC
        POP  AF
        RET


; ---------------------------------------------------------
; PrintTotalMoves
;   BM_MOVES_HI:BM_MOVES_LO を10進表示
; ---------------------------------------------------------
PrintTotalMoves:
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL

        LD   A,(BM_MOVES_LO)
        LD   L,A
        LD   A,(BM_MOVES_HI)
        LD   H,A

        CALL PrintHLu

        POP  HL
        POP  DE
        POP  BC
        POP  AF
        RET


; ---------------------------------------------------------
; PrintTick32
;   BM_TICK3..0 を16進8桁表示
; ---------------------------------------------------------
PrintTick32:
        PUSH AF
        PUSH HL

        LD   HL,BM_TICK3
        LD   A,(HL)
        CALL PrintHex8
        DEC  HL
        LD   A,(HL)
        CALL PrintHex8
        DEC  HL
        LD   A,(HL)
        CALL PrintHex8
        DEC  HL
        LD   A,(HL)
        CALL PrintHex8

        POP  HL
        POP  AF
        RET


; ---------------------------------------------------------
; PrintHex8
; ---------------------------------------------------------
PrintHex8:
        PUSH AF
        RRCA
        RRCA
        RRCA
        RRCA
        AND  0FH
        CALL PrintHexNibble
        POP  AF
        AND  0FH
        CALL PrintHexNibble
        RET


; ---------------------------------------------------------
; PrintHexNibble
; ---------------------------------------------------------
PrintHexNibble:
        ADD  A,'0'
        CP   '9'+1
        JR   C,PHN_OUT
        ADD  A,7
PHN_OUT:
        CALL PutChar
        RET


; ---------------------------------------------------------
; PrintHLu
;   HL (0..65535) を10進表示
; ---------------------------------------------------------
PrintHLu:
        PUSH AF
        PUSH BC
        PUSH DE

        LD   B,0                  ; printed flag

        LD   DE,10000
        CALL PHLU_DIGIT
        LD   DE,1000
        CALL PHLU_DIGIT
        LD   DE,100
        CALL PHLU_DIGIT
        LD   DE,10
        CALL PHLU_DIGIT

        LD   A,L
        ADD  A,'0'
        CALL PutChar

        POP  DE
        POP  BC
        POP  AF
        RET

PHLU_DIGIT:
        LD   C,0
PHLU_LOOP:
        OR   A
        SBC  HL,DE
        JR   C,PHLU_END
        INC  C
        JR   PHLU_LOOP
PHLU_END:
        ADD  HL,DE
        LD   A,C
        OR   B
        JR   Z,PHLU_SKIP
        LD   A,C
        ADD  A,'0'
        CALL PutChar
        LD   B,1
PHLU_SKIP:
        RET



        END START
