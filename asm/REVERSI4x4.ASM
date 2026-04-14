; =========================================================
; Super AKI-80 4x4 Othello
; ---------------------------------------------------------
; Target : Z80 (Super AKI-80)
; Serial : SIOA  DAT=18h  CTL=19h  (SIO init by monitor)
;
; Board model:
;   0 = EMPTY, 1 = BLACK('X'), 2 = WHITE('O')
;
; Features:
;   - Board print (4x4)
;   - Player input: "A1" .. "D4"
;   - AI move: scan order (A1->D4), plays first legal move
;   - Legal check + flipping (ApplyMove)
;   - Counts display "X:nn O:nn"
;   - Game end: board full OR 2 consecutive passes
;   - 2PASS 時にメッセージを出すようにしました
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


; =========================================================
; Strings (0-terminated)
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

MSG_PASSEND:	DEFM CR,LF,"Game ended by consecutive passes.",CR,LF,0

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


; =========================================================
; Main entry / game loop
; =========================================================

START:
        LD   SP,0FFF0H
        DI                      ; SIO init is assumed done by monitor

        ; 起動直後の表示
        CALL PrintBoard
        CALL DecideFirstTurn

MAIN_LOOP:
        ; 1手進める（PASS含む）
        CALL DoTurn
        OR   A
        JP   NZ,GameOver        ; A=1 => end by consecutive passes

        ; 盤面と石数を表示
        CALL PrintBoard
        CALL PrintCounts

        ; 盤面が満杯なら終局
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
        CALL GetChar            ; A = key
        CALL PutChar            ; 1文字エコー（不要なら削除）

        ; 大文字→小文字（A..Zなら +20h）
        CP   'A'
        JR   C,GO_CHK
        CP   'Z'+1
        JR   NC,GO_CHK
        ADD  A,20H

GO_CHK:
        CP   'r'
        JR   Z,GO_RETRY
        CP   'q'
        JR   Z,GO_QUIT

        ; それ以外 → ベル
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
        RST  00H        ; 多くのモニタで入口（ダメなら下を試す）
        ; JP  0000H

        HALT                ; どちらもダメならこれで止める

; ---------------------------------------------------------
; InitBoard
;   BOARD を初期配置に戻す（16バイトコピー）
;   PassStreak も 0 に戻す
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
;   BOARD(16 bytes) を 4x4 で表示
;     空き '.' / 黒 'X' / 白 'O'
; Destroys: AF,BC,DE,HL (saved internally)
; =========================================================
PrintBoard:
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL

        ; 1行空ける
        LD   DE,MSG_NEWLINE
        CALL PrintString

        ; 列ヘッダ
        LD   DE,COL_HEADER
        CALL PrintString

        ; 改行
        LD   DE,MSG_NEWLINE
        CALL PrintString

        ; HL = BOARD 先頭
        LD   HL,BOARD

        ; B = 行カウンタ (4)
        LD   B,BOARD_H

PB_ROW_LOOP:
        ; 行番号 '1'..'4'
        LD   A,'5'
        SUB  B                  ; B=4->'1',3->'2',2->'3',1->'4'
        CALL PutChar

        ; スペース
        LD   A,' '
        CALL PutChar

        ; C = 列カウンタ (4)
        LD   C,BOARD_W

PB_COL_LOOP:
        ; A = cell (0/1/2)
        LD   A,(HL)
        INC  HL

        ; 文字変換: STONE_CHAR[cell]
        LD   E,A
        LD   D,0
        PUSH HL                 ; BOARD走査用HLを保護
        LD   HL,STONE_CHAR
        ADD  HL,DE
        LD   A,(HL)
        POP  HL

        CALL PutChar

        ; 各マスの後ろにスペース
        LD   A,' '
        CALL PutChar

        DEC  C
        JR   NZ,PB_COL_LOOP

        ; 行末改行
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
;   A = 1文字送信
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
;   DE = 0終端文字列
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
;   CRLF を出力
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
;   1文字受信して A に返す（ブロッキング）
; Destroys: AF
; ---------------------------------------------------------
GetChar:
GC_WRX:
        XOR  A
        OUT  (SIOA_CTL),A       ; RR0選択
        IN   A,(SIOA_CTL)
        BIT  0,A                ; Rx Ready ?
        JR   Z,GC_WRX
        IN   A,(SIOA_DAT)
        RET


; ---------------------------------------------------------
; GETLINE
;   HL = バッファ先頭（例: RXBUF）
;   CR/LFで確定し、最後に 0 終端を付ける
;   - 20文字まで保存＆エコー
;   - 21文字目以降は保存しないで BEL
;   - BS/DEL で1文字削除（画面も消す）
;
; 戻り:
;   A = 受信長（0..BUF_MAX-1）
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

        ; ---- 通常文字 ----
        LD   E,A                ; 受信文字を退避

        ; 20文字超なら捨ててBEL
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
        CALL PutChar            ; エコー
        JR   GL_LOOP

GL_BS:
        LD   A,B
        OR   A
        JR   Z,GL_LOOP          ; 0文字なら無視

        DEC  HL
        DEC  B

        ; 画面上も1文字消す（BS, space, BS）
        LD   A,BS
        CALL PutChar
        LD   A,' '
        CALL PutChar
        LD   A,BS
        CALL PutChar

        JR   GL_LOOP

GL_DONE:
        XOR  A
        LD   (HL),A             ; 0終端

        LD   A,B                ; length
        RET


; =========================================================
; Move parsing / Player move
; =========================================================

; ---------------------------------------------------------
; ParseMove
;   RXBUF 先頭2文字を "A1" のように解釈して offset(0..15) を作る
;   - 列: 'A'..'D' / 'a'..'d' → 0..3
;   - 行: '1'..'4'            → 0..3
; 戻り:
;   成功: A=1, C=offset(0..15)
;   失敗: A=0（BELを鳴らす）
; Destroys: AF,BC
; ---------------------------------------------------------
ParseMove:
        ; 2文字あるか（空行対策）
        LD   A,(RXBUF)
        OR   A
        JR   Z,PM_BEEPFAIL
        LD   A,(RXBUF+1)
        OR   A
        JR   Z,PM_BEEPFAIL

        ; --- 列 ---
        LD   A,(RXBUF)          ; 'A'..'D' or 'a'..'d'

        ; 小文字→大文字
        CP   'a'
        JR   C,PM_COLUPPER
        CP   'z'+1
        JR   NC,PM_COLUPPER
        AND  11011111b
PM_COLUPPER:
        SUB  'A'
        CP   4
        JR   NC,PM_BEEPFAIL
        LD   B,A                ; B=col(0..3)

        ; --- 行 ---
        LD   A,(RXBUF+1)        ; '1'..'4'
        SUB  '1'
        CP   4
        JR   NC,PM_BEEPFAIL     ; 0..3のみ

        ; offset = row*4 + col
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
;   入力→Parse→合法判定→ApplyMove(反転+着手)
;   不正ならメッセージを出して再入力
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

        CALL ParseMove          ; 成功 A=1, C=offset
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

        ; 反転+着手
        LD   A,(HumSide)
        LD   D,A
        CALL ApplyMove
        OR   A
        JR   Z,PM_ILLEGAL2      ; 念のため

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
;   (AiSide) の合法手を探索し、最初に見つけた手を1手だけ打つ
;   見つけたら "AI moves to A1" を表示
;   見つからなければ何もしない（DoTurn側がPASS扱い）
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

        ; 表示位置 "A1"
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

        RET                     ; no legal move


; ---------------------------------------------------------
; HasAnyLegalMove
;   指定プレイヤーに合法手が1つでもあるか？
; 入力:
;   D = player (BLACK/WHITE)
; 戻り:
;   A = 1 あり / 0 なし
; Destroys:
;   AF,BC,DE,HL,IX,IY (IsLegalMoveに準拠)
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


        ; =========================================================
; Coordinate helpers / Board primitives
; =========================================================

; ---------------------------------------------------------
; OffsetToRowCol
;   C = offset (0..15)
; Output:
;   B = row (0..3)
;   C = col (0..3)
; Destroys: AF
; ---------------------------------------------------------
OffsetToRowCol:
        LD   A,C

        LD   B,A
        SRL  B
        SRL  B                  ; B = offset / 4

        AND  3                  ; A = offset % 4
        LD   C,A
        RET


; ---------------------------------------------------------
; RowColToOffset
;   B = row (0..3)
;   C = col (0..3)
; Output:
;   C = offset (0..15)
; Destroys: AF
; ---------------------------------------------------------
RowColToOffset:
        LD   A,B
        SLA  A
        SLA  A                  ; row*4
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
;   A = stone (BLACK=1 / WHITE=2)
;   C = offset (0..15)
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

        ; offset = r*4 + c
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
;   A(0..16) -> "00".."16"
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
;   - TurnSide plays 1 move (AIset or PlayerMove)
;   - if no legal move -> PASS, increments PassStreak
;   - if PassStreak reaches 2 -> A=1 end
;   - otherwise switches TurnSide and A=0
; Destroys: AF,BC,DE
; ---------------------------------------------------------
DoTurn:
        LD   A,(TurnSide)
        LD   D,A

        CALL HasAnyLegalMove
        OR   A
        JR   NZ,DT_CanMove

        ; ---- PASS ----
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

        END START

