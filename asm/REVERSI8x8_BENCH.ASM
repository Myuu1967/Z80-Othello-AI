; =========================================================
; Super AKI-80 8x8 REVERSI
; ---------------------------------------------------------
; Target : Z80 (Super AKI-80)
; Serial : SIOA  DAT=18h  CTL=19h  (SIO init by monitor)
;
; Board model:
;   0 = EMPTY, 1 = BLACK('X'), 2 = WHITE('O')
;
; Features:
;   - Board print (8x8)
;   - Player input: "A1" .. "H8"
;   - AI move: scan order (A1->H8), plays first legal move
;   - Legal check + flipping (ApplyMove)
;   - Counts display "X:nn O:nn"
;   - Game end: board full OR 2 consecutive passes
;   - r: retry / q: quit after game over
; 
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
BOARD_W         EQU 8
BOARD_H         EQU 8
BOARD_BYTES     EQU BOARD_W*BOARD_H

EMPTY           EQU 0
BLACK           EQU 1
WHITE           EQU 2

DIR_CNT         EQU 8

BUF_MAX         EQU 64
LINE_MAX        EQU 20

BENCH_TOTAL     EQU 15      ; �܂�10��B�K�v�ɉ����� 50 / 99 �ɕύX

; =========================================================
; Strings (0-terminated)
; =========================================================
COL_HEADER:     DEFM "  A B C D E F G H",0
MSG_NEWLINE:    DEFM CR,LF,0

MSG_PROMPT:     DEFM "Your move (A1-H8) > ",0
MSG_BADFMT:     DEFM CR,LF,"Bad input. Use A1-H8.",CR,LF,0
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

MSG_BENCH_HDR:  DEFM CR,LF,"8x8 REVERSI BENCH",CR,LF,0
MSG_BENCH_DONE: DEFM CR,LF,"BENCH DONE",CR,LF,0

MSG_G:          DEFM "G",0
MSG_X:          DEFM " X:",0
MSG_O:          DEFM " O:",0
MSG_M:          DEFM " M:",0
MSG_W:          DEFM " W:",0

MSG_TOTAL_G:    DEFM "TOTAL G:",0
MSG_TOTAL_M:    DEFM " TOTAL M:",0
MSG_TOTAL_MS:   DEFM " TOTAL ms:",0
MSG_MSPM:       DEFM " ms/M:",0
MSG_T:          DEFM " T:",0
MSG_MS:         DEFM "ms",0

MSG_BENCH_RETRYQ: DEFM CR,LF,"r:Retry or q:Quit ? ",0

; =========================================================
; Tables
; =========================================================
; index: 0=EMPTY, 1=BLACK, 2=WHITE -> printable char
STONE_CHAR:
        DEFB '.', 'X', 'O'

DIR_DR:
        DEFB -1,-1,-1, 0,0, 1,1,1
DIR_DC:
        DEFB -1, 0, 1,-1,1,-1,0,1


; =========================================================
; Board (current state)
; NOTE: If you want a clean "initial position", replace
;       these bytes (or later add InitBoard routine).
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

; ---- Benchmark work ----
BenchGamesLeft: DEFB 0      ; �c�Q�[����
BenchGameNo:    DEFB 0      ; ���݃Q�[���ԍ� (1..99�z��)

GM_MOVES_LO:    DEFB 0      ; ���̃Q�[���̎萔�iPASS���݁j
GM_MOVES_HI:    DEFB 0

BM_MOVES_LO:    DEFB 0      ; �S�Q�[�����萔
BM_MOVES_HI:    DEFB 0

WIN_CHAR:       DEFB 0      ; 'X' / 'O' / '='
TMP_U16_LO:     DEFB 0      ; PrintU16 work
TMP_U16_HI:     DEFB 0

; ---- Software ms counter (incremented by CTC ISR) ----
TICK_LO:        DEFB 0      ; 16-bit ms counter (lo)
TICK_HI:        DEFB 0      ; 16-bit ms counter (hi)

; ---- Per-game / total time (ms) ----
TK_SNAP_LO:     DEFB 0      ; snapshot at game start (lo)
TK_SNAP_HI:     DEFB 0      ; snapshot at game start (hi)
GM_TIME_LO:     DEFB 0      ; this game elapsed ms (lo)
GM_TIME_HI:     DEFB 0      ; this game elapsed ms (hi)
BM_TIME_LO:     DEFB 0      ; total benchmark ms (lo)
BM_TIME_HI:     DEFB 0      ; total benchmark ms (hi)


; =========================================================
; Main entry / benchmark loop
;   ������ r:Retry / q:Quit
; =========================================================

START:
BENCH_RESTART:
        LD   SP,0FFF0H
        DI

        ; IM2 setup: I register = FEH -> vector table at FE00H
        LD   A,0FEH
        LD   I,A
        IM   2

        ; Clear ms counter
        XOR  A
        LD   (TICK_LO),A
        LD   (TICK_HI),A

        CALL InitTimerCTC       ; start ~1ms interrupt

        DI

        LD   A,00001111B    ; PIOA: 全ビット出力モード
        OUT  (PIOA_CMD),A
        LD   A,0            ; PIOA: 全ビット LOW
        OUT  (PIOA_DATA),A

        CALL  StartTimer

        LD   DE,MSG_BENCH_HDR
        CALL PrintString

        LD   DE,MSG_BENCH_HDR
        CALL PrintString

        ; 総手数クリア
        XOR  A
        LD   (BM_MOVES_LO),A
        LD   (BM_MOVES_HI),A

        ; 総時間クリア
        LD   (BM_TIME_LO),A
        LD   (BM_TIME_HI),A

        ; ゲーム番号 = 0
        LD   (BenchGameNo),A

        ; 残ゲーム数セット
        LD   A,BENCH_TOTAL
        LD   (BenchGamesLeft),A

BENCH_GAME_LOOP:

        CALL  StartTimer

        ; 盤面初期化
        CALL InitBoard

        ; ゲーム開始時刻スナップショット
        CALL GetTick            ; HL = current ms
        LD   (TK_SNAP_LO),HL

        ; この試合の手数クリア
        XOR  A
        LD   (GM_MOVES_LO),A
        LD   (GM_MOVES_HI),A

        ; ���Œ�: BLACK
        LD   A,BLACK
        LD   (TurnSide),A

        ; �Q�[���ԍ�++
        LD   A,(BenchGameNo)
        INC  A
        LD   (BenchGameNo),A

BENCH_TURN_LOOP:
        CALL DoTurnBench
        OR   A
        JR   NZ,BENCH_GAME_END

        CALL IsBoardFull
        OR   A
        JR   NZ,BENCH_GAME_END

        JR   BENCH_TURN_LOOP

BENCH_GAME_END:
        ; ゲーム経過時間 = 現在ms - スナップショット
        CALL GetTick            ; HL = current ms
        LD   DE,(TK_SNAP_LO)
        OR   A
        SBC  HL,DE              ; HL = elapsed ms
        LD   (GM_TIME_LO),HL

        CALL StopTimer


        ; 総時間に加算
        CALL AddGameTimeToTotal

        CALL AddGameMovesToTotal
        CALL PrintBenchResultLine

        LD   A,(BenchGamesLeft)
        DEC  A
        LD   (BenchGamesLeft),A
        JR   NZ,BENCH_GAME_LOOP

        LD   DE,MSG_BENCH_DONE
        CALL PrintString
        CALL PrintBenchSummary

BENCH_ASK:
        LD   DE,MSG_BENCH_RETRYQ
        CALL PrintString

BENCH_WAIT:
        CALL GetChar
        CALL PutChar

        CP   'A'
        JR   C,BENCH_CHK
        CP   'Z'+1
        JR   NC,BENCH_CHK
        ADD  A,20H

BENCH_CHK:

        CALL StopTimer

        CP   'r'
        JR   Z,BENCH_DO_RETRY
        CP   'q'
        JR   Z,BENCH_DO_QUIT

        LD   A,BEL
        CALL PutChar
        JR   BENCH_WAIT

BENCH_DO_RETRY:
        CALL NEWLINE
        JP   BENCH_RESTART

BENCH_DO_QUIT:
        CALL NEWLINE
        LD   DE,MSG_BYE
        CALL PrintString

        DI

        RST  00H
        HALT


; ---------------------------------------------------------
; InitBoard
;   BOARD �������z�u�ɖ߂��i64�o�C�g�R�s�[�j
;   PassStreak �� 0 �ɖ߂�
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
;   BOARD(64 bytes) �� 8x8 �ŕ\��
;     �� '.' / �� 'X' / �� 'O'
; Destroys: AF,BC,DE,HL (saved internally)
; =========================================================
PrintBoard:
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL

        ; 1�s�󂯂�
        LD   DE,MSG_NEWLINE
        CALL PrintString

        ; ��w�b�_
        LD   DE,COL_HEADER
        CALL PrintString

        ; ���s
        LD   DE,MSG_NEWLINE
        CALL PrintString

        ; HL = BOARD �擪
        LD   HL,BOARD

        ; B = �s�J�E���^ (4)
        LD   B,BOARD_H

PB_ROW_LOOP:
        ; �s�ԍ� '1'..'4'
        LD   A,'9'
        SUB  B                  ; B=4->'1',3->'2',2->'3',1->'4'
        CALL PutChar

        ; �X�y�[�X
        LD   A,' '
        CALL PutChar

        ; C = ��J�E���^ (4)
        LD   C,BOARD_W

PB_COL_LOOP:
        ; A = cell (0/1/2)
        LD   A,(HL)
        INC  HL

        ; �����ϊ�: STONE_CHAR[cell]
        LD   E,A
        LD   D,0
        PUSH HL                 ; BOARD�����pHL��ی�
        LD   HL,STONE_CHAR
        ADD  HL,DE
        LD   A,(HL)
        POP  HL

        CALL PutChar

        ; �e�}�X�̌��ɃX�y�[�X
        LD   A,' '
        CALL PutChar

        DEC  C
        JR   NZ,PB_COL_LOOP

        ; �s�����s
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

; ---------------------------------------------------------
; PutChar
;   A = 1�������M
; Destroys: AF
; ---------------------------------------------------------
PutChar:
        PUSH AF
PC_WAITTX:
        IN   A,(SIOA_CTL)
        BIT  2,A                ; Tx Ready ?
        JR   Z,PC_WAITTX
        POP  AF
        OUT  (SIOA_DAT),A
        RET


; ---------------------------------------------------------
; PrintString
;   DE = 0�I�[������
; Destroys: AF,DE
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
;   CRLF ���o��
; Destroys: AF
; ---------------------------------------------------------
NEWLINE:
        LD   A,CR
        CALL PutChar
        LD   A,LF
        CALL PutChar
        RET

; =========================================================
; Serial input / line editor
; =========================================================

; ---------------------------------------------------------
; GetChar
;   1������M���� A �ɕԂ��i�u���b�L���O�j
; Destroys: AF
; ---------------------------------------------------------
GetChar:
GC_WRX:
        XOR  A
        OUT  (SIOA_CTL),A       ; RR0�I��
        IN   A,(SIOA_CTL)
        BIT  0,A                ; Rx Ready ?
        JR   Z,GC_WRX
        IN   A,(SIOA_DAT)
        RET


; ---------------------------------------------------------
; GETLINE
;   HL = �o�b�t�@�擪�i��: RXBUF�j
;   CR/LF�Ŋm�肵�A�Ō�� 0 �I�[��t����
;   - 20�����܂ŕۑ����G�R�[
;   - 21�����ڈȍ~�͕ۑ����Ȃ��� BEL
;   - BS/DEL ��1�����폜�i��ʂ������j
;
; �߂�:
;   A = ��M���i0..BUF_MAX-1�j
; Destroys:
;   AF,BC,DE,HL
; ---------------------------------------------------------
GETLINE:
        LD   B,0                ; length

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

        ; ---- �ʏ핶�� ----
        LD   E,A                ; ��M������ޔ�

        ; 20�������Ȃ�̂Ă�BEL
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
        CALL PutChar            ; �G�R�[
        JR   GL_LOOP

GL_BS:
        LD   A,B
        OR   A
        JR   Z,GL_LOOP          ; 0�����Ȃ疳��

        DEC  HL
        DEC  B

        ; ��ʏ��1���������iBS, space, BS�j
        LD   A,BS
        CALL PutChar
        LD   A,' '
        CALL PutChar
        LD   A,BS
        CALL PutChar

        JR   GL_LOOP

GL_DONE:
        XOR  A
        LD   (HL),A             ; 0�I�[

        LD   A,B                ; length
        RET


; ---------------------------------------------------------
; StartTimer
;
; Destroys: AF
; ---------------------------------------------------------
StartTimer:
        PUSH AF
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
; Move parsing / Player move
; =========================================================

; ---------------------------------------------------------
; ParseMove
;   RXBUF �擪2������ "A1" �̂悤�ɉ��߂��� offset(0..63) �����
;   - ��: 'A'..'H' / 'a'..'h' �� 0..7
;   - �s: '1'..'8'            �� 0..7
; �߂�:
;   ����: A=1, C=offset(0..63)
;   ���s: A=0�iBEL��炷�j
; Destroys: AF,BC
; ---------------------------------------------------------
ParseMove:
        ; 2�������邩�i��s�΍�j
        LD   A,(RXBUF)
        OR   A
        JR   Z,PM_BEEPFAIL
        LD   A,(RXBUF+1)
        OR   A
        JR   Z,PM_BEEPFAIL

        ; --- �� ---
        LD   A,(RXBUF)          ; 'A'..'H' or 'a'..'h'

        ; ���������啶��
        CP   'a'
        JR   C,PM_COLUPPER
        CP   'z'+1
        JR   NC,PM_COLUPPER
        AND  11011111b
PM_COLUPPER:
        SUB  'A'
        CP   8
        JR   NC,PM_BEEPFAIL
        LD   B,A                ; B=col(0..7)

        ; --- �s ---
        LD   A,(RXBUF+1)        ; '1'..'8'
        SUB  '1'
        CP   8
        JR   NC,PM_BEEPFAIL     ; 0..7�̂�

        ; offset = row*8 + col
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


; ---------------------------------------------------------
; PlayerMove
;   ���́�Parse�����@���聨ApplyMove(���]+����)
;   �s���Ȃ烁�b�Z�[�W���o���čē���
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
PlayerMove:
PM_LOOP:
        LD   DE,MSG_PROMPT
        CALL PrintString
        CALL NEWLINE

        LD   HL,RXBUF
        CALL GETLINE
        CALL NEWLINE

        CALL ParseMove          ; ���� A=1, C=offset
        OR   A
        JR   Z,PM_BADINPUT

        CALL OffsetToRowCol     ; B=row, C=col

        LD   A,(HumSide)
        LD   D,A                ; D=player side

        PUSH BC
        PUSH DE
        CALL IsLegalMove
        POP  DE
        POP  BC

        OR   A
        JR   Z,PM_ILLEGAL

        ; ���]+����
        LD   A,(HumSide)
        LD   D,A
        CALL ApplyMove
        OR   A
        JR   Z,PM_ILLEGAL2      ; �O�̂���

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
; AI move / Legal move existence
; =========================================================

; ---------------------------------------------------------
; AIset
;   (AiSide) �̍��@���T�����A�ŏ��Ɍ��������1�肾���ł�
;   �������� "AI moves to A1" ��\��
;   ������Ȃ���Ή������Ȃ��iDoTurn����PASS�����j
; Destroys: AF,BC,DE,HL,IX,IY
; ---------------------------------------------------------
AIset:
        LD   A,(AiSide)
        LD   D,A                ; D=AI side

        LD   B,0                ; row=0
AI_ROW:
        LD   C,0                ; col=0
AI_COL:
        PUSH BC
        PUSH DE
        CALL IsLegalMove
        POP  DE
        POP  BC
        OR   A
        JR   Z,AI_NEXTCOL

        ; legal -> apply
        PUSH BC
        PUSH DE
        CALL ApplyMove
        POP  DE
        POP  BC

        ; �\���ʒu "A1"
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
        CP   8
        JR   C,AI_COL

        INC  B
        LD   A,B
        CP   8
        JR   C,AI_ROW

        RET                     ; no legal move


; ---------------------------------------------------------
; HasAnyLegalMove
;   �w��v���C���[�ɍ��@�肪1�ł����邩�H
; ����:
;   D = player (BLACK/WHITE)
; �߂�:
;   A = 1 ���� / 0 �Ȃ�
; Destroys:
;   AF,BC,DE,HL,IX,IY (IsLegalMove�ɏ���)
; ---------------------------------------------------------
HasAnyLegalMove:
        LD   B,0                ; row=0
HAM_ROW:
        LD   C,0                ; col=0
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

; ---------------------------------------------------------
; OffsetToRowCol
;   C = offset (0..63)
; Output:
;   B = row (0..7)
;   C = col (0..7)
; Destroys: AF
; ---------------------------------------------------------
OffsetToRowCol:
        LD   A,C

        LD   B,A
        SRL  B
        SRL  B
        SRL  B                  ; B = offset / 8

        AND  7                  ; A = offset % 8
        LD   C,A
        RET


; ---------------------------------------------------------
; RowColToOffset
;   B = row (0..7)
;   C = col (0..7)
; Output:
;   C = offset (0..63)
; Destroys: AF
; ---------------------------------------------------------
RowColToOffset:
        LD   A,B
        SLA  A
        SLA  A
        SLA  A                  ; row*8
        ADD  A,C
        LD   C,A
        RET


; ---------------------------------------------------------
; InRange
;   B=row, C=col (signed allowed)
; Output:
;   A=1 inside / A=0 outside
; Destroys: AF
; ---------------------------------------------------------
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


; ---------------------------------------------------------
; PlaceAtOffset
;   A = stone (BLACK=1 / WHITE=2)
;   C = offset (0..63)
; Output:
;   A=1 success / A=0 fail (beep)
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
PlaceAtOffset:
        LD   B,A                ; stone backup

        LD   HL,BOARD
        LD   E,C
        LD   D,0
        ADD  HL,DE              ; HL=&BOARD[offset]

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
; Output:
;   A=1 full / A=0 not full
; Destroys: AF,BC,HL
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


; =========================================================
; Rule core: TryDirCount / IsLegalMove / FlipDirN / ApplyMove
; =========================================================

; ---------------------------------------------------------
; TryDirCount
; Inputs (memory):
;   WORK_PLAYER, WORK_ROW, WORK_COL
;   TD_DR, TD_DC
; Output:
;   A=0 not flippable / A=n flippable (n>=1)
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
TryDirCount:
        ; TD_OPP = 3 - player
        LD   A,(WORK_PLAYER)
        LD   E,A
        LD   A,3
        SUB  E
        LD   (TD_OPP),A

        XOR  A
        LD   (TD_COUNT),A

        ; TD_R = row + dr
        LD   A,(WORK_ROW)
        LD   E,A
        LD   A,(TD_DR)
        ADD  A,E
        LD   (TD_R),A

        ; TD_C = col + dc
        LD   A,(WORK_COL)
        LD   E,A
        LD   A,(TD_DC)
        ADD  A,E
        LD   (TD_C),A

TDC_Loop:
        ; InRange(TD_R,TD_C)?
        LD   A,(TD_R)
        LD   B,A
        LD   A,(TD_C)
        LD   C,A
        CALL InRange
        OR   A
        JR   Z,TDC_Fail

        ; offset = r*8 + c (via RowColToOffset)
        CALL RowColToOffset     ; C=offset

        ; stone = BOARD[offset]
        LD   HL,BOARD
        LD   E,C
        LD   D,0
        ADD  HL,DE
        LD   A,(HL)
        LD   E,A                ; stone in E

        ; if stone == opp -> count++
        LD   A,(TD_OPP)
        CP   E
        JR   Z,TDC_GotOpp

        ; if stone == player -> return count (>=1 ok)
        LD   A,(WORK_PLAYER)
        CP   E
        JR   Z,TDC_ReturnCount

        ; EMPTY -> fail
        JR   TDC_Fail

TDC_GotOpp:
        LD   A,(TD_COUNT)
        INC  A
        LD   (TD_COUNT),A

        ; advance r,c
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
; Inputs:
;   D=player, B=row, C=col
; Output:
;   A=1 legal / 0 illegal
; Destroys: AF,BC,DE,HL,IX,IY
; ---------------------------------------------------------
IsLegalMove:
        ; store to work
        LD   A,D
        LD   (WORK_PLAYER),A
        LD   A,B
        LD   (WORK_ROW),A
        LD   A,C
        LD   (WORK_COL),A

        ; start cell must be EMPTY
        CALL RowColToOffset     ; C=offset
        LD   HL,BOARD
        LD   E,C
        LD   D,0
        ADD  HL,DE
        LD   A,(HL)
        OR   A
        JR   NZ,ILM_NotLegal

        ; loop dirs
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
; Input (memory):
;   WORK_PLAYER, WORK_ROW, WORK_COL, TD_DR, TD_DC
; Input (reg):
;   A = n (1..)
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
FlipDirN:
        LD   (TD_N),A
        OR   A
        RET  Z

        ; TD_R = row + dr
        LD   A,(WORK_ROW)
        LD   E,A
        LD   A,(TD_DR)
        ADD  A,E
        LD   (TD_R),A

        ; TD_C = col + dc
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

        CALL RowColToOffset     ; C=offset

        ; BOARD[offset] = player
        LD   HL,BOARD
        LD   E,C
        LD   D,0
        ADD  HL,DE
        LD   A,(WORK_PLAYER)
        LD   (HL),A

        ; n--
        LD   A,(TD_N)
        DEC  A
        LD   (TD_N),A

        ; advance r,c
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
; Inputs:
;   D=player, B=row, C=col
; Output:
;   A=1 success / 0 fail
; Destroys: AF,BC,DE,HL,IX,IY
; ---------------------------------------------------------
ApplyMove:
        ; store to work
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
        CALL TryDirCount        ; A=n (0..)
        OR   A
        JR   Z,AM_NoFlip

        CALL FlipDirN

        LD   A,1
        LD   (AM_DIDFLIP),A

AM_NoFlip:
        POP  BC
        DJNZ AM_Loop

        ; must flip at least once
        LD   A,(AM_DIDFLIP)
        OR   A
        JR   Z,AM_Fail

        ; place the stone itself
        LD   A,(WORK_ROW)
        LD   B,A
        LD   A,(WORK_COL)
        LD   C,A
        CALL RowColToOffset     ; C=offset

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

; ---------------------------------------------------------
; CountStones
; Output:
;   B = BLACK count
;   C = WHITE count
; Destroys: AF,DE,HL
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
;   A(0..64) -> "00".."64"
; Destroys: AF,BC
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
;   prints "X:nn O:nn" + CRLF
; Destroys: AF,BC,DE,HL
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
; Destroys: AF,BC,DE,HL
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


; =========================================================
; Turn control: DecideFirstTurn / DoTurn
; =========================================================

; ---------------------------------------------------------
; DecideFirstTurn
;   pseudo random by R bit0
;   sets AiSide/HumSide/TurnSide
; Destroys: AF
; ---------------------------------------------------------
DecideFirstTurn:
        LD   DE,MsgAiDecides
        CALL PrintString

        LD   A,R
        AND  1
        JR   Z,DFT_AiFirst

; human first
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

; ai first (AI=BLACK, Human=WHITE, Turn=BLACK)
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
; DoTurn
;   Benchmark��
;   - TurnSide plays 1 move by AI
;   - if no legal move -> PASS
;   - PASS �� 1��Ƃ��ăJ�E���g
;   - if PassStreak reaches 2 -> A=1 end
;   - otherwise switches TurnSide and A=0
; Destroys: AF,BC,DE
; ---------------------------------------------------------
DoTurn:
DoTurnBench:
        LD   A,(TurnSide)
        LD   D,A

        CALL HasAnyLegalMove
        OR   A
        JR   NZ,DTB_CanMove

        ; ---- PASS ----
        CALL IncGameMoves

        LD   A,(PassStreak)
        INC  A
        LD   (PassStreak),A
        CP   2
        JR   NC,DTB_EndByPass

        JR   DTB_SwitchReturn0

DTB_CanMove:
        XOR  A
        LD   (PassStreak),A

        ; ���ݎ�Ԃ�AI���Ƃ��Ĉ���
        LD   A,(TurnSide)
        LD   (AiSide),A

        CALL AIsetBench
        CALL IncGameMoves

        JR   DTB_SwitchReturn0

DTB_EndByPass:
        LD   A,1
        RET

DTB_SwitchReturn0:
        LD   A,(TurnSide)
        CP   BLACK
        JR   Z,DTB_SetWhite

DTB_SetBlack:
        LD   A,BLACK
        LD   (TurnSide),A
        XOR  A
        RET

DTB_SetWhite:
        LD   A,WHITE
        LD   (TurnSide),A
        XOR  A
        RET


; =========================================================
; Benchmark helper routines
; =========================================================

; ---------------------------------------------------------
; IncGameMoves
;   ���̃Q�[���̎萔�� 16bit �� +1
;   PASS ���ʏ풅���������Ă�
; Destroys: AF
; ---------------------------------------------------------
IncGameMoves:
        LD   A,(GM_MOVES_LO)
        INC  A
        LD   (GM_MOVES_LO),A
        RET  NZ

        LD   A,(GM_MOVES_HI)
        INC  A
        LD   (GM_MOVES_HI),A
        RET


; ---------------------------------------------------------
; AddGameMovesToTotal
;   BM_MOVES += GM_MOVES
; Destroys: AF
; ---------------------------------------------------------
AddGameMovesToTotal:
        LD   A,(BM_MOVES_LO)
        LD   B,A
        LD   A,(GM_MOVES_LO)
        ADD  A,B
        LD   (BM_MOVES_LO),A

        LD   A,(BM_MOVES_HI)
        LD   B,A
        LD   A,(GM_MOVES_HI)
        ADC  A,B
        LD   (BM_MOVES_HI),A
        RET


; ---------------------------------------------------------
; AIsetBench
;   (AiSide) �̍��@���T�����A�ŏ��Ɍ��������1�肾���ł�
;   �\���͈�؂��Ȃ�
;   ������Ȃ���Ή������Ȃ�
; Destroys: AF,BC,DE,HL,IX,IY
; ---------------------------------------------------------
AIsetBench:
        LD   A,(AiSide)
        LD   D,A

        LD   B,0
AIB_ROW:
        LD   C,0
AIB_COL:
        PUSH BC
        PUSH DE
        CALL IsLegalMove
        POP  DE
        POP  BC
        OR   A
        JR   Z,AIB_NEXTCOL

        PUSH BC
        PUSH DE
        CALL ApplyMove
        POP  DE
        POP  BC
        RET

AIB_NEXTCOL:
        INC  C
        LD   A,C
        CP   8
        JR   C,AIB_COL

        INC  B
        LD   A,B
        CP   8
        JR   C,AIB_ROW

        RET


; ---------------------------------------------------------
; DecideWinnerChar
;   WIN_CHAR �� 'X' / 'O' / '=' ��ݒ�
;   CountStones ������ŌĂ�
; Destroys: AF,BC
; ---------------------------------------------------------
DecideWinnerChar:
        CALL CountStones
        LD   A,B
        CP   C
        JR   Z,DWC_Draw
        JR   NC,DWC_X

DWC_O:
        LD   A,'O'
        LD   (WIN_CHAR),A
        RET

DWC_X:
        LD   A,'X'
        LD   (WIN_CHAR),A
        RET

DWC_Draw:
        LD   A,'='
        LD   (WIN_CHAR),A
        RET


; ---------------------------------------------------------
; Print2Digits
;   A=0..99 �� 2���ŕ\��
;   ��: 0 -> "00", 7 -> "07", 12 -> "12"
; Destroys: AF,BC
; ---------------------------------------------------------
Print2Digits:
        LD   B,0
P2D_LOOP:
        CP   10
        JR   C,P2D_OUT
        SUB  10
        INC  B
        JR   P2D_LOOP

P2D_OUT:
        LD   C,A
        LD   A,B
        ADD  A,'0'
        CALL PutChar
        LD   A,C
        ADD  A,'0'
        CALL PutChar
        RET


; ---------------------------------------------------------
; PrintU16
;   HL = value (0..65535) �� 10�i�\��
;   �擪�[���͏o���Ȃ�
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
PrintU16:
        LD   A,H
        LD   (TMP_U16_HI),A
        LD   A,L
        LD   (TMP_U16_LO),A

        LD   B,0                ; printed flag

        ; 10000 �̈�
        LD   DE,2710H
        CALL PrintU16Digit

        ; 1000 �̈�
        LD   DE,03E8H
        CALL PrintU16Digit

        ; 100 �̈�
        LD   DE,0064H
        CALL PrintU16Digit

        ; 10 �̈�
        LD   DE,000AH
        CALL PrintU16Digit

        ; 1 �̈�
        LD   A,(TMP_U16_LO)
        ADD  A,'0'
        CALL PutChar
        RET


; ---------------------------------------------------------
; PrintU16Digit
;   �����p
;   TMP_U16 ���� DE ���J��Ԃ������� 1���o��
;   B=printed flag (0/��0)
; ����:
;   DE = 10000 / 1000 / 100 / 10
; �o��:
;   B �X�V
; Destroys: AF,BC,HL
; ---------------------------------------------------------
PrintU16Digit:
        LD   C,0

P16D_SUB:
        LD   A,(TMP_U16_LO)
        SUB  E
        LD   L,A
        LD   A,(TMP_U16_HI)
        SBC  A,D
        JR   C,P16D_DONE

        LD   H,A
        LD   A,L
        LD   (TMP_U16_LO),A
        LD   A,H
        LD   (TMP_U16_HI),A
        INC  C
        JR   P16D_SUB

P16D_DONE:
        LD   A,B
        OR   A
        JR   NZ,P16D_PRINT

        LD   A,C
        OR   A
        RET  Z

P16D_PRINT:
        LD   A,C
        ADD  A,'0'
        CALL PutChar
        LD   B,1
        RET


; ---------------------------------------------------------
; PrintBenchResultLine
;   1�Q�[�����̌��ʂ�1�s�ŏo��
;   �`��:
;     G01 X:34 O:30 M:62 W:X
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
PrintBenchResultLine:
        LD   DE,MSG_G
        CALL PrintString

        LD   A,(BenchGameNo)
        CALL Print2Digits

        LD   DE,MSG_X
        CALL PrintString
        CALL CountStones
        LD   A,B
        CALL PrintDec2

        LD   DE,MSG_O
        CALL PrintString
        CALL CountStones
        LD   A,C
        CALL PrintDec2

        LD   DE,MSG_M
        CALL PrintString
        LD   A,(GM_MOVES_HI)
        LD   H,A
        LD   A,(GM_MOVES_LO)
        LD   L,A
        CALL PrintU16

        LD   DE,MSG_W
        CALL PrintString
        CALL DecideWinnerChar
        LD   A,(WIN_CHAR)
        CALL PutChar

        ; " T:xxxms"
        LD   DE,MSG_T
        CALL PrintString
        LD   HL,(GM_TIME_LO)
        CALL PrintU16
        LD   DE,MSG_MS
        CALL PrintString

        CALL NEWLINE
        RET


PrintBenchSummary:
        LD   DE,MSG_TOTAL_G
        CALL PrintString
        LD   A,BENCH_TOTAL
        CALL Print2Digits

        LD   DE,MSG_TOTAL_M
        CALL PrintString
        LD   A,(BM_MOVES_HI)
        LD   H,A
        LD   A,(BM_MOVES_LO)
        LD   L,A
        CALL PrintU16

        LD   DE,MSG_TOTAL_MS
        CALL PrintString
        LD   HL,(BM_TIME_LO)
        CALL PrintU16
        LD   DE,MSG_MS
        CALL PrintString

        ; ms/M = 総ms / 総手数
        LD   DE,MSG_MSPM
        CALL PrintString
        LD   HL,(BM_TIME_LO)    ; dividend = total ms
        LD   BC,(BM_MOVES_LO)   ; divisor  = total moves
        LD   A,B
        OR   C
        JR   Z,PBS_SKIP
        CALL Div16              ; HL = ms per move
        CALL PrintU16
PBS_SKIP:
        LD   DE,MSG_MS
        CALL PrintString

        CALL NEWLINE
        RET

; ---------------------------------------------------------
; ReadBenchTick
;   CTC CH0 �̌��ݒl��ǂ�
;   �����ł� I/O port 10H ��z��
; �߂�:
;   A = current tick byte
; Destroys: AF
; ---------------------------------------------------------
; ---------------------------------------------------------
; InitTimerCTC
;   CTC CH0 を約1msタイマー割り込みとして初期化
;   10MHz / 256 / 39 = 1001.6Hz ≈ 1ms
;   割り込みベクタ 0x00 → テーブル 0xFE00H → TICK_ISR
; Destroys: AF
; ---------------------------------------------------------
InitTimerCTC:
        ; (1) 割り込みベクタ設定 (D0=0 → vector word)
        LD   A,000H             ; vector base = 00H, CH0 → 00H
        OUT  (CTC_CH0),A

        ; (2) 制御ワード = D7H = 1101 0111b
        ;  D7=1  control word
        ;  D6=1  interrupt ENABLE
        ;  D5=0  Timer mode
        ;  D4=1  Prescaler /256
        ;  D3=0  Rising edge
        ;  D2=1  time constant follows
        ;  D1=1  software reset
        ;  D0=1  channel control word
        LD   A,0D7H
        OUT  (CTC_CH0),A

        ; (3) 時定数: 39 → 256×39/10MHz ≈ 998μs ≈ 1ms
        LD   A,39
        OUT  (CTC_CH0),A
        RET


; ---------------------------------------------------------
; TICK_ISR
;   CTC CH0 割り込みサービスルーチン（約1ms毎）
;   TICK_LO/HI を 1 インクリメント
; ---------------------------------------------------------
TICK_ISR:
        PUSH AF
        PUSH HL
        LD   HL,(TICK_LO)
        INC  HL
        LD   (TICK_LO),HL
        POP  HL
        POP  AF
        EI
        RETI


; ---------------------------------------------------------
; GetTick
;   割り込み禁止で TICK_LO/HI を安全に読む
; Returns: HL = current ms count
; Destroys: AF
; ---------------------------------------------------------
GetTick:
        DI
        LD   HL,(TICK_LO)
        EI
        RET


; ---------------------------------------------------------
; AddGameTimeToTotal
;   BM_TIME += GM_TIME (16bit)
; Destroys: AF,HL,DE
; ---------------------------------------------------------
AddGameTimeToTotal:
        LD   HL,(BM_TIME_LO)
        LD   DE,(GM_TIME_LO)
        ADD  HL,DE
        LD   (BM_TIME_LO),HL
        RET


; ----- 以下の旧ルーチンは削除 -----


; ---------------------------------------------------------
; CalcTickDiff
;   TK_DIFF = TK_START - TK_END
;   down counter �O��
;   1�Q�[���� 256 tick �𒴂��Ȃ��͈͂ŗL��
; Destroys: AF
; ---------------------------------------------------------
; CalcTickDiff: 削除済み（ソフトカウンタ方式に移行）


; ---------------------------------------------------------
; AddTickDiffToTotal
;   BM_TICKS_0..3 += TK_DIFF
; Destroys: AF
; ---------------------------------------------------------
; AddTickDiffToTotal: 削除済み（AddGameTimeToTotal に置き換え）


; ---------------------------------------------------------
; PrintU32Ticks
;   32bit�l BM_TICKS_0..3 ��16�i8���ŕ\��
;   ��: 00001234
; Destroys: AF
; ---------------------------------------------------------
; PrintU32Ticks: 削除済み（ms表示に置き換え）


; ---------------------------------------------------------
; PrintHex2
;   A ��16�i2���ŕ\��
; Destroys: AF,BC
; ---------------------------------------------------------
PrintHex2:
        PUSH AF
        RRCA
        RRCA
        RRCA
        RRCA
        AND  0FH
        CALL PrintHex1
        POP  AF
        AND  0FH
        CALL PrintHex1
        RET


; ---------------------------------------------------------
; PrintHex1
;   A=0..15 ��16�i1���ŕ\��
; Destroys: AF
; ---------------------------------------------------------
PrintHex1:
        CP   10
        JR   C,PH1_NUM
        ADD  A,'A'-10
        CALL PutChar
        RET

PH1_NUM:
        ADD  A,'0'
        CALL PutChar
        RET


; ---------------------------------------------------------
; InitBenchCTC
;   CH0 ���x���`�p�^�C�}�Ƃ��ď�����
;   - timer mode
;   - prescaler = 256
;   - auto trigger
;   - interrupt disable
;   - time constant = FFh
; Destroys: AF
; ---------------------------------------------------------
; InitBenchCTC: 旧ルーチン削除済み。InitTimerCTC を使用すること。
;        ; Control Word = C7h
;        ; 1100 0111b
;        ;  D7=1  control word
;        ;  D6=1  interrupt disable
        ;  D5=0/1 �̓f�o�C�X�����̕\�L���ɒ��ӂ�����̂ŁA
        ;       �����ł͎��@�Ŏg�������ݒ�ɍ��킹�� C7h ���̗p
        ;  D4=0  edge default
        ;  D3=0  auto trigger
        ;  D2=1  next word = time constant
        ;  D1=1  software reset
        ;  D0=1  timer mode
        ; Control Word = 97H = 1001 0111b
        ;  D7=1  control word (always 1)
        ;  D6=0  interrupt DISABLE
        ;  D5=0  Timer mode (internal clock / prescaler)
        ;  D4=1  Prescaler /256
        ;  D3=0  Rising edge
        ;  D2=1  next word = time constant
        ;  D1=1  software reset
        ;  D0=1  channel control word
        ; (InitBenchCTC: 削除済み → InitTimerCTC を使用)


; =========================================================
; Div16
;   HL = dividend (16-bit)
;   BC = divisor  (16-bit)
; Returns:
;   HL = quotient
;   DE = remainder
; Destroys: AF,BC,DE,HL
; =========================================================
Div16:
        LD   DE,0000H
        LD   A,16
D16_LP:
        ADD  HL,HL          ; shift HL left, MSB -> CY
        RL   E              ; shift DE left with carry
        RL   D
        PUSH HL
        EX   DE,HL          ; HL = partial remainder
        OR   A              ; clear carry
        SBC  HL,BC          ; HL = remainder - divisor
        JR   C,D16_NO
        EX   DE,HL          ; DE = new remainder
        POP  HL
        INC  L              ; set quotient bit 0 = 1
        DEC  A
        JR   NZ,D16_LP
        RET
D16_NO:
        ADD  HL,BC          ; undo failed subtraction → HL = old remainder
        EX   DE,HL          ; DE = old remainder (restored), HL = shifted quotient
        POP  HL             ; HL = shifted quotient
        DEC  A
        JR   NZ,D16_LP
        RET


; ---------------------------------------------------------
; PrintTicksPerMove
;   BM_TICKS_1:BM_TICKS_0 / BM_MOVES_HI:BM_MOVES_LO
;   -> "T/M:nnn" (integer ticks per move)
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
        ; (PrintTicksPerMove は PrintBenchSummary 内にインライン化済み)


; =========================================================
; Interrupt Vector Table for IM2
;   I = FEH → table base = FE00H
;   CTC CH0 vector = 00H → address FE00H
; =========================================================
        ORG  0FE00H
        DEFW TICK_ISR           ; CH0: アドレス低バイト, 高バイトの順


        END START

