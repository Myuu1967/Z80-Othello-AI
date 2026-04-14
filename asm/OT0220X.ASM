; =========================================================
; Super AKI-80  4x4 Othello
; ---------------------------------------------------------
; Author : たぬきばやし(X:@Tanuki_Bayashin)
; Target : Z80 (Super AKI-80)
; Serial : SIOA (18h / 19h)
;
; Features:
;   - 4x4 board
;   - Full Othello rules (legal check + flipping)
;   - AI (scan-first strategy)
;   - Consecutive PASS end detection
;   - Stone count + winner display
;
; This program demonstrates:
;   - Board representation (1 byte per cell)
;   - Directional search (8 directions)
;   - Move validation and stone flipping
;   - Serial text I/O handling
;
; =========================================================


        ORG 8000H
        JP  start


; =========================================================
; Ports / ASCII
; =========================================================
sioADat     EQU 18H
sioACtl     EQU 19H

cr          EQU 0DH
lf          EQU 0AH
bs          EQU 08H
del         EQU 7FH
bel         EQU 07H


; =========================================================
; Board / Game constants
; =========================================================
boardW      EQU 4
boardH      EQU 4
boardBytes  EQU boardW*boardH

empty       EQU 0
black       EQU 1
white       EQU 2

dirCnt      EQU 8

bufMax      EQU 64          ; RX buffer size (no terminator)
lineMax     EQU 20          ; max input length (21st and later => beep)


; =========================================================
; Text / tables (0-terminated unless noted)
; =========================================================
colHeader:      DEFM "  A B C D",0
msgNewline:     DEFM cr,lf,0

msgPrompt:      DEFM "Your move (A1-D4) > ",0
msgBadFmt:      DEFM cr,lf,"Bad input. Use A1-D4.",cr,lf,0
msgLegal:       DEFM cr,lf,"OK (legal move).",cr,lf,0
msgIllegal:     DEFM cr,lf,"NG (illegal move).",cr,lf,0
msgIllegal2:    DEFM cr,lf,"NG2 (illegal move).",cr,lf,0

msgGameOver:    DEFM cr,lf,"GAME OVER",cr,lf,0

msgAiDecides:   DEFM "AI decides who goes first...",cr,lf,0
msgAiFirst:     DEFM "AI goes first. You are WHITE (O).",cr,lf,0
msgHumanFirst:  DEFM "You go first. You are BLACK (X).",cr,lf,0

msgAiPass:      DEFM "AI PASS",cr,lf,0
msgPlPass:      DEFM "YOU PASS",cr,lf,0

msgCountsX:     DEFM "X:",0
msgCountsO:     DEFM " O:",0

msgWinX:        DEFM "BLACK(X) wins",0
msgWinO:        DEFM "WHITE(O) wins",0
msgDraw:        DEFM "Draw",0

; AI move print helper: "AI moves to " + "A1" + 0
msgAiMove:      DEFM "AI moves to ",0
aiMovePos:      DEFB 'A','1',0

; index: 0=empty, 1=black, 2=white  -> display char
stoneChar:      DEFB '.', 'X', 'O'

; 8 directions tables (signed bytes)
dirDr:          DEFB -1,-1,-1, 0,0, 1,1,1
dirDc:          DEFB -1, 0, 1,-1,1,-1,0,1


; =========================================================
; Board initial data (standard 4x4 start)
; ---------------------------------------------------------
; NOTE:
;   We'll keep a separate initBoardData so board (RAM) can
;   be a DEFS area later if you prefer.
; =========================================================
initBoardData:
        DEFB empty,empty,empty,empty
        DEFB empty,white,black,empty
        DEFB empty,black,white,empty
        DEFB empty,empty,empty,empty


; =========================================================
; Variables (RAM)
; =========================================================
; --- Board (current state) ---
board:
        ; 今は初期値入りで動かしているので DEFB のままでもOK。
        ; 将来 InitBoard を作るならここを DEFS boardBytes にして
        ; 起動時に initBoardData をコピーするのが綺麗。
        DEFB empty,empty,empty,empty
        DEFB empty,white,black,empty
        DEFB empty,black,white,empty
        DEFB empty,empty,empty,empty

; --- Sides ---
aiSide:         DEFB 0
humSide:        DEFB 0
turnSide:       DEFB 0

; --- Pass ---
passStreak:     DEFB 0          ; consecutive passes (0..2)

; (old flags — currently not needed if passStreak is used)
aiPassed:       DEFB 0
plPassed:       DEFB 0

; --- RX buffer ---
rxBuf:          DEFS bufMax

; --- IsLegalMove / ApplyMove work area ---
workPlayer:     DEFB 0
workRow:        DEFB 0
workCol:        DEFB 0

tdR:            DEFB 0
tdC:            DEFB 0
tdOpp:          DEFB 0

tdDr:           DEFB 0
tdDc:           DEFB 0
tdCount:        DEFB 0          ; TryDirCount result count
tdN:            DEFB 0          ; FlipDirN counter

amDidFlip:      DEFB 0          ; ApplyMove: flipped at least once?


; =========================================================
; Compatibility aliases (temporary)
; ---------------------------------------------------------
; After you update code to camelCase, these can be removed.
; =========================================================
SIOA_DAT        EQU sioADat
SIOA_CTL        EQU sioACtl

BOARD_W         EQU boardW
BOARD_H         EQU boardH
BOARD_BYTES     EQU boardBytes

EMPTY           EQU empty
BLACK           EQU black
WHITE           EQU white

COL_HEADER      EQU colHeader
MSG_NEWLINE     EQU msgNewline

BOARD           EQU board
STONE_CHAR      EQU stoneChar

AImovePOS       EQU aiMovePos
AImoveMSG       EQU msgAiMove

BUF_MAX         EQU bufMax
RXBUF           EQU rxBuf
LINE_MAX        EQU lineMax

DIR_DR          EQU dirDr
DIR_DC          EQU dirDc
DIR_CNT         EQU dirCnt

WORK_PLAYER     EQU workPlayer
WORK_ROW        EQU workRow
WORK_COL        EQU workCol

TD_R            EQU tdR
TD_C            EQU tdC
TD_OPP          EQU tdOpp
TD_DR           EQU tdDr
TD_DC           EQU tdDc
TD_COUNT        EQU tdCount
TD_N            EQU tdN

AiSide          EQU aiSide
HumSide         EQU humSide
TurnSide        EQU turnSide
PassStreak      EQU passStreak

AI_PASSED       EQU aiPassed
PL_PASSED       EQU plPassed

AM_DIDFLIP      EQU amDidFlip

MSG_PROMPT      EQU msgPrompt
MSG_BADFMT      EQU msgBadFmt
MSG_LEGAL       EQU msgLegal
MSG_ILLEGAL     EQU msgIllegal
MSG_ILLEGAL2    EQU msgIllegal2
MSG_GAMEOVER    EQU msgGameOver

MsgAiDecides    EQU msgAiDecides
MsgAiFirst      EQU msgAiFirst
MsgHumanFirst   EQU msgHumanFirst

MSG_AI_PASS     EQU msgAiPass
MSG_PL_PASS     EQU msgPlPass

MSG_COUNTS      EQU msgCountsX
MSG_SPACEO      EQU msgCountsO

MSG_WIN_X       EQU msgWinX
MSG_WIN_O       EQU msgWinO
MSG_DRAW        EQU msgDraw



; =========================================================
; Main entry / game loop
; =========================================================

start:
        LD   SP,0FFF0H
        DI                      ; SIO init is assumed done by monitor

        ; 初回表示（必要ならここで passStreak=0 など初期化）
        CALL printBoard
        CALL decideFirstTurn

mainLoop:
        CALL doTurn
        OR   A
        JP   NZ,gameOver        ; A=1 => end by consecutive passes

        CALL printBoard
        CALL printCounts

        CALL isBoardFull
        OR   A
        JP   NZ,gameOver

        JP   mainLoop


; =========================================================
; Game over
; =========================================================
gameOver:
        LD   DE,msgGameOver
        CALL printString
        CALL showWinner

hang:
        JP   hang


; =========================================================
; Board display
;   - prints 4x4 board as:
;       A B C D
;     1 . . . .
;     ...
; ---------------------------------------------------------
; Uses:
;   board / boardW / boardH / stoneChar
; Destroys:
;   AF,BC,DE,HL (preserved by pushes)
; =========================================================
printBoard:
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL

        ; blank line
        LD   DE,msgNewline
        CALL printString

        ; header
        LD   DE,colHeader
        CALL printString

        LD   DE,msgNewline
        CALL printString

        LD   HL,board
        LD   B,boardH           ; row counter (4)

rowLoop:
        ; row label: '1'..'4'
        LD   A,'5'
        SUB  B                  ; B=4->'1',3->'2',2->'3',1->'4'
        CALL putChar

        LD   A,' '
        CALL putChar

        LD   C,boardW           ; col counter (4)

colLoop:
        LD   A,(HL)             ; cell 0/1/2
        INC  HL

        ; A -> display char via stoneChar[]
        LD   E,A
        LD   D,0
        PUSH HL
        LD   HL,stoneChar
        ADD  HL,DE
        LD   A,(HL)
        POP  HL

        CALL putChar

        LD   A,' '
        CALL putChar

        DEC  C
        JR   NZ,colLoop

        LD   DE,msgNewline
        CALL printString

        DJNZ rowLoop

        POP  HL
        POP  DE
        POP  BC
        POP  AF
        RET


; =========================================================
; Decide first turn
;   - pseudo random by R register bit0
;   - sets aiSide/humSide/turnSide
; Destroys: AF
; =========================================================
decideFirstTurn:
        LD   DE,msgAiDecides
        CALL printString

        LD   A,R
        AND  1
        JR   Z,aiGoesFirst

; human goes first => human=BLACK, ai=WHITE, turn=BLACK
humanGoesFirst:
        LD   A,black
        LD   (humSide),A
        LD   A,white
        LD   (aiSide),A

        LD   A,black
        LD   (turnSide),A

        LD   DE,msgHumanFirst
        CALL printString
        RET

; ai goes first => ai=BLACK, human=WHITE, turn=BLACK
aiGoesFirst:
        LD   A,black
        LD   (aiSide),A
        LD   A,white
        LD   (humSide),A

        LD   A,black
        LD   (turnSide),A

        LD   DE,msgAiFirst
        CALL printString
        RET


; =========================================================
; DoTurn
;   - current turnSide plays (AI or Human)
;   - if no legal move => pass
;   - if passStreak reaches 2 => return A=1 (game end)
;   - otherwise switches turnSide and returns A=0
; Input/Output:
;   A = 0 continue / 1 end
; Destroys: AF,BC,DE
; =========================================================
doTurn:
        ; D = side to move
        LD   A,(turnSide)
        LD   D,A

        ; any legal move?
        CALL hasAnyLegalMove     ; input D, output A=1/0
        OR   A
        JR   NZ,doTurnCanMove

        ; ---- PASS ----
        LD   A,(turnSide)
        LD   B,A
        LD   A,(humSide)
        CP   B
        JR   Z,humPassDisplay

aiPassDisplay:
        LD   DE,msgAiPass
        CALL printString
        JR   doTurnPassCommon

humPassDisplay:
        LD   DE,msgPlPass
        CALL printString

doTurnPassCommon:
        LD   A,(passStreak)
        INC  A
        LD   (passStreak),A
        CP   2
        JR   NC,doTurnEndByPass

        JR   doTurnSwitchReturn0

doTurnCanMove:
        XOR  A
        LD   (passStreak),A

        ; AI turn?
        LD   A,(turnSide)
        LD   B,A
        LD   A,(aiSide)
        CP   B
        JR   Z,doTurnAi

doTurnHum:
        CALL playerMove
        JR   doTurnSwitchReturn0

doTurnAi:
        CALL aiSet
        JR   doTurnSwitchReturn0

doTurnEndByPass:
        LD   A,1
        RET

doTurnSwitchReturn0:
        LD   A,(turnSide)
        CP   black
        JR   Z,setWhite

setBlack:
        LD   A,black
        LD   (turnSide),A
        XOR  A
        RET

setWhite:
        LD   A,white
        LD   (turnSide),A
        XOR  A
        RET


; =========================================================
; Low-level I/O
; =========================================================
putChar:
        PUSH AF
waitTx:
        IN   A,(sioACtl)
        BIT  2,A
        JR   Z,waitTx
        POP  AF
        OUT  (sioADat),A
        RET

printString:
        PUSH AF
        PUSH DE
psLoop:
        LD   A,(DE)
        OR   A
        JR   Z,psDone
        CALL putChar
        INC  DE
        JR   psLoop
psDone:
        POP  DE
        POP  AF
        RET


; =========================================================
; Compatibility aliases (optional during migration)
; - remove after you convert the rest of the file
; =========================================================
START           EQU start
MAIN_LOOP       EQU mainLoop
GameOver        EQU gameOver

PrintBoard      EQU printBoard
DecideFirstTurn EQU decideFirstTurn
DoTurn          EQU doTurn

PutChar         EQU putChar
PrintString     EQU printString

TurnSide        EQU turnSide
AiSide          EQU aiSide
HumSide         EQU humSide
PassStreak      EQU passStreak

SIOA_DAT        EQU sioADat
SIOA_CTL        EQU sioACtl

BLACK           EQU black
WHITE           EQU white


; =========================================================
; Player input / move
; =========================================================
; playerMove:
;   - prompt -> getline -> parseMove
;   - offset -> (row,col)
;   - isLegalMove -> applyMove
;   - invalid input / illegal move => loop
;
; Uses:
;   msgPrompt/msgBadFmt/msgIllegal/msgIllegal2
;   rxBuf, humSide
; Destroys:
;   AF,BC,DE,HL
; =========================================================
playerMove:
pmLoop:
        LD   DE,msgPrompt
        CALL printString
        CALL newLine

        LD   HL,rxBuf
        CALL getLine
        CALL newLine

        ; parseMove: success A=1, offset in C (0..15)
        CALL parseMove
        OR   A
        JR   Z,pmBadInput

        ; offset -> row/col (B=row, C=col)
        CALL offsetToRowCol

        ; D = player side
        LD   A,(humSide)
        LD   D,A

        PUSH BC
        PUSH DE
        CALL isLegalMove
        POP  DE
        POP  BC

        OR   A
        JR   Z,pmIllegal

        ; applyMove(D,B,C) : flips + place
        LD   A,(humSide)
        LD   D,A
        CALL applyMove

        OR   A
        JR   Z,pmIllegal2       ; just in case

        RET

pmBadInput:
        LD   DE,msgBadFmt
        CALL printString
        JR   pmLoop

pmIllegal:
        LD   DE,msgIllegal
        CALL printString
        JR   pmLoop

pmIllegal2:
        LD   DE,msgIllegal2
        CALL printString
        JR   pmLoop


; =========================================================
; AI move
; =========================================================
; aiSet:
;   - scans board from row0..3 col0..3
;   - first legal move -> applyMove and prints "AI moves to A1"
;   - if none => DoTurn will handle pass message
;
; Uses:
;   aiSide, msgAiMove, aiMovePos
; Destroys:
;   AF,BC,DE,HL,IX,IY
; =========================================================
aiSet:
        LD   A,(aiSide)
        LD   D,A                ; D = AI side (black/white)

        LD   B,0                ; row=0
aiRowLoop:
        LD   C,0                ; col=0
aiColLoop:
        PUSH BC
        PUSH DE
        CALL isLegalMove        ; A=1 legal
        POP  DE
        POP  BC
        OR   A
        JR   Z,aiNextCol

        ; legal -> applyMove
        PUSH BC
        PUSH DE
        CALL applyMove
        POP  DE
        POP  BC

        ; print location "A1"
        ; col -> 'A'+col
        LD   A,C
        AND  3
        ADD  A,'A'
        LD   (aiMovePos),A

        ; row -> '1'+row
        LD   A,B
        AND  3
        ADD  A,'1'
        LD   (aiMovePos+1),A

        ; print "AI moves to " + "A1"
        LD   DE,msgAiMove
        CALL printString
        LD   DE,aiMovePos
        CALL printString
        CALL newLine
        RET

aiNextCol:
        INC  C
        LD   A,C
        CP   4
        JR   C,aiColLoop

        INC  B
        LD   A,B
        CP   4
        JR   C,aiRowLoop

        ; no legal move
        RET


; =========================================================
; Serial input
; =========================================================
; getChar:
;   - waits RxReady then reads 1 byte
; Destroys: AF
; =========================================================
getChar:
wrx:
        XOR  A
        OUT  (sioACtl),A        ; select RR0
        IN   A,(sioACtl)
        BIT  0,A
        JR   Z,wrx
        IN   A,(sioADat)
        RET


; =========================================================
; getLine
;   HL = buffer start
;   - reads until CR/LF
;   - stores up to lineMax chars
;   - from 21st char: beep and drop (no echo increase)
;   - supports BS/DEL erase (screen: BS space BS)
; Output:
;   A = length (0..bufMax-1)
; Destroys:
;   AF,BC,DE,HL
; =========================================================
getLine:
        LD   B,0                ; length

glLoop:
        CALL getChar            ; A = char

        CP   cr
        JR   Z,glDone
        CP   lf
        JR   Z,glDone

        CP   bs
        JR   Z,glBackspace
        CP   del
        JR   Z,glBackspace

        ; normal char
        LD   E,A                ; save char

        LD   A,B
        CP   lineMax
        JR   C,glStore

        ; too long -> beep and drop
        LD   A,bel
        CALL putChar
        JR   glLoop

glStore:
        LD   A,E
        LD   (HL),A
        INC  HL
        INC  B
        CALL putChar            ; echo
        JR   glLoop

glBackspace:
        LD   A,B
        OR   A
        JR   Z,glLoop

        DEC  HL
        DEC  B

        LD   A,bs
        CALL putChar
        LD   A,' '
        CALL putChar
        LD   A,bs
        CALL putChar
        JR   glLoop

glDone:
        XOR  A
        LD   (HL),A             ; 0-term
        LD   A,B                 ; length
        RET


; =========================================================
; newLine (CRLF)
; =========================================================
newLine:
        LD   A,cr
        CALL putChar
        LD   A,lf
        CALL putChar
        RET


; =========================================================
; parseMove
;   - reads first 2 chars from rxBuf: "A1".."D4" (case-insensitive col)
; Output:
;   success: A=1, C=offset (0..15)
;   fail   : A=0 (beep)
; Destroys:
;   AF,BC
; =========================================================
parseMove:
        LD   A,(rxBuf)
        OR   A
        JR   Z,pmBeepFail
        LD   A,(rxBuf+1)
        OR   A
        JR   Z,pmBeepFail

        ; col
        LD   A,(rxBuf)

        CP   'a'
        JR   C,pmColUpper
        CP   'z'+1
        JR   NC,pmColUpper
        AND  11011111b          ; to upper
pmColUpper:
        SUB  'A'
        CP   4
        JR   NC,pmBeepFail
        LD   B,A                ; B=col

        ; row
        LD   A,(rxBuf+1)
        SUB  '1'
        CP   4
        JR   NC,pmBeepFail

        ; offset = row*4 + col
        SLA  A
        SLA  A
        ADD  A,B
        LD   C,A

        LD   A,1
        RET

pmBeepFail:
        LD   A,bel
        CALL putChar
        XOR  A
        RET


; =========================================================
; Compatibility aliases (optional during migration)
; =========================================================
PlayerMove      EQU playerMove
AIset           EQU aiSet
GetChar         EQU getChar
GETLINE         EQU getLine
NEWLINE         EQU newLine
ParseMove       EQU parseMove


; =========================================================
; Coordinate helpers / Board primitives
; =========================================================

; ---------------------------------------------------------
; offsetToRowCol
;   C = offset (0..15)
; Output:
;   B = row (0..3)
;   C = col (0..3)
; Destroys: AF
; ---------------------------------------------------------
offsetToRowCol:
        LD   A,C

        LD   B,A
        SRL  B
        SRL  B                  ; B = offset / 4

        AND  3                  ; A = offset % 4
        LD   C,A
        RET


; ---------------------------------------------------------
; rowColToOffset
;   B = row (0..3)
;   C = col (0..3)
; Output:
;   C = offset (0..15)
; Destroys: AF
; ---------------------------------------------------------
rowColToOffset:
        LD   A,B
        SLA  A
        SLA  A                  ; row*4
        ADD  A,C
        LD   C,A
        RET


; ---------------------------------------------------------
; inRange
;   B=row, C=col (signed allowed)
; Output:
;   A=1 inside / A=0 outside
; Destroys: AF
; ---------------------------------------------------------
inRange:
        BIT  7,B
        JR   NZ,irFail
        LD   A,B
        CP   4
        JR   NC,irFail

        BIT  7,C
        JR   NZ,irFail
        LD   A,C
        CP   4
        JR   NC,irFail

        LD   A,1
        RET
irFail:
        XOR  A
        RET


; ---------------------------------------------------------
; placeAtOffset
;   A = stone (black=1 / white=2)
;   C = offset (0..15)
; Action:
;   if board[offset] is empty -> set it
; Output:
;   A=1 success / A=0 fail (beep)
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
placeAtOffset:
        LD   B,A                ; save stone in B

        LD   HL,board
        LD   E,C
        LD   D,0
        ADD  HL,DE              ; HL=&board[offset]

        LD   A,(HL)
        OR   A
        JR   NZ,paoBeepFail

        LD   A,B
        LD   (HL),A

        LD   A,1
        RET

paoBeepFail:
        LD   A,bel
        CALL putChar
        XOR  A
        RET


; ---------------------------------------------------------
; isBoardFull
;   checks if any EMPTY(0) exists
; Output:
;   A=1 full / A=0 not full
; Destroys: AF,BC,HL
; ---------------------------------------------------------
isBoardFull:
        PUSH HL
        PUSH BC

        LD   HL,board
        LD   B,boardBytes

ibfLoop:
        LD   A,(HL)
        OR   A
        JR   Z,ibfNotFull
        INC  HL
        DJNZ ibfLoop

        LD   A,1
        JR   ibfDone

ibfNotFull:
        XOR  A

ibfDone:
        POP  BC
        POP  HL
        RET


; =========================================================
; Counting / printing counts
; =========================================================

; ---------------------------------------------------------
; countStones
; Output:
;   B = black count (0..16)
;   C = white count (0..16)
; Destroys: AF,DE,HL
; ---------------------------------------------------------
countStones:
        LD   HL,board
        LD   D,boardBytes
        LD   B,0
        LD   C,0

csLoop:
        LD   A,(HL)
        CP   black
        JR   NZ,csNotX
        INC  B
        JR   csNext

csNotX:
        CP   white
        JR   NZ,csNext
        INC  C

csNext:
        INC  HL
        DEC  D
        JR   NZ,csLoop
        RET


; ---------------------------------------------------------
; printDec2
;   A (0..16 here) -> prints "00".."16"
; Destroys: AF,BC
; ---------------------------------------------------------
printDec2:
        LD   B,0                ; tens
pd2Loop:
        CP   10
        JR   C,pd2Out
        SUB  10
        INC  B
        JR   pd2Loop

pd2Out:
        LD   C,A                ; ones
        LD   A,B
        ADD  A,'0'
        CALL putChar

        LD   A,C
        ADD  A,'0'
        CALL putChar
        RET


; ---------------------------------------------------------
; printCounts
;   prints: "X:nn O:nn" + CRLF
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
printCounts:
        CALL countStones

        LD   DE,msgCountsX
        PUSH BC
        CALL printString
        POP  BC

        LD   A,B
        PUSH BC
        CALL printDec2
        POP  BC

        LD   DE,msgCountsO
        PUSH BC
        CALL printString
        POP  BC

        LD   A,C
        CALL printDec2

        CALL newLine
        RET


; ---------------------------------------------------------
; showWinner
;   compares stone counts and prints winner message
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
showWinner:
        CALL countStones

        LD   A,B
        CP   C
        JR   Z,swDraw
        JR   NC,swXWin

swOWin:
        LD   DE,msgWinO
        CALL printString
        CALL newLine
        RET

swXWin:
        LD   DE,msgWinX
        CALL printString
        CALL newLine
        RET

swDraw:
        LD   DE,msgDraw
        CALL printString
        CALL newLine
        RET


; =========================================================
; Compatibility aliases (optional during migration)
; =========================================================
OffsetToRowCol  EQU offsetToRowCol
RowColToOffset  EQU rowColToOffset
InRange         EQU inRange

PlaceAtOffset   EQU placeAtOffset
IsBoardFull     EQU isBoardFull

CountStones     EQU countStones
PrintDec2       EQU printDec2
PrintCounts     EQU printCounts
ShowWinner      EQU showWinner


; =========================================================
; Rule core: legal check / flip / apply move
; ---------------------------------------------------------
; Data model:
;   board cell: 0=empty, 1=black, 2=white
;
; Direction tables:
;   dirDr[8], dirDc[8]  (signed bytes)
;
; Work variables used by these routines:
;   workPlayer/workRow/workCol, tdDr/tdDc, tdR/tdC, tdOpp
;   tdCount (TryDirCount result), tdN (FlipDirN counter)
;   amDidFlip (ApplyMove: flipped at least once)
; =========================================================


; ---------------------------------------------------------
; tryDirCount
;   From (workRow,workCol), check direction (tdDr,tdDc).
;   If there are 1+ opponent stones followed by own stone,
;   returns the number of opponent stones to flip.
;
; Inputs (memory):
;   workPlayer, workRow, workCol
;   tdDr, tdDc
; Output:
;   A = 0   not flippable in this dir
;   A = n   flippable (n>=1)
; Destroys:
;   AF,BC,DE,HL
; ---------------------------------------------------------
tryDirCount:
        ; tdOpp = 3 - player (since player is 1/2)
        LD   A,(workPlayer)
        LD   E,A
        LD   A,3
        SUB  E
        LD   (tdOpp),A

        XOR  A
        LD   (tdCount),A

        ; tdR = row + dr
        LD   A,(workRow)
        LD   E,A
        LD   A,(tdDr)
        ADD  A,E
        LD   (tdR),A

        ; tdC = col + dc
        LD   A,(workCol)
        LD   E,A
        LD   A,(tdDc)
        ADD  A,E
        LD   (tdC),A

tdcLoop:
        ; InRange(tdR,tdC)?
        LD   A,(tdR)
        LD   B,A
        LD   A,(tdC)
        LD   C,A
        CALL inRange
        OR   A
        JR   Z,tdcFail

        ; offset = r*4 + c  (C=offset)
        CALL rowColToOffset

        ; stone = board[offset]
        LD   HL,board
        LD   E,C
        LD   D,0
        ADD  HL,DE
        LD   A,(HL)
        LD   E,A                ; stone in E

        ; if stone == opp -> count++, advance
        LD   A,(tdOpp)
        CP   E
        JR   Z,tdcGotOpp

        ; else if stone == player -> return count (>=1 => legal)
        LD   A,(workPlayer)
        CP   E
        JR   Z,tdcReturnCount

        ; else empty -> fail
        JR   tdcFail

tdcGotOpp:
        LD   A,(tdCount)
        INC  A
        LD   (tdCount),A

        ; advance r,c
        LD   A,(tdR)
        LD   E,A
        LD   A,(tdDr)
        ADD  A,E
        LD   (tdR),A

        LD   A,(tdC)
        LD   E,A
        LD   A,(tdDc)
        ADD  A,E
        LD   (tdC),A

        JR   tdcLoop

tdcReturnCount:
        LD   A,(tdCount)
        RET

tdcFail:
        XOR  A
        RET


; ---------------------------------------------------------
; isLegalMove
;   Checks whether placing player at (row,col) is legal.
; Inputs:
;   D = player (1/2)
;   B = row (0..3)
;   C = col (0..3)
; Output:
;   A = 1 legal / 0 illegal
; Destroys:
;   AF,BC,DE,HL,IX,IY
; ---------------------------------------------------------
isLegalMove:
        ; store to work*
        LD   A,D
        LD   (workPlayer),A
        LD   A,B
        LD   (workRow),A
        LD   A,C
        LD   (workCol),A

        ; start cell must be empty
        CALL rowColToOffset      ; C=offset
        LD   HL,board
        LD   E,C
        LD   D,0
        ADD  HL,DE
        LD   A,(HL)
        OR   A
        JR   NZ,ilmNotLegal

        ; loop 8 directions
        LD   B,dirCnt
        LD   IX,dirDr
        LD   IY,dirDc

ilmLoop:
        LD   A,(IX+0)
        LD   (tdDr),A
        INC  IX

        LD   A,(IY+0)
        LD   (tdDc),A
        INC  IY

        PUSH BC
        CALL tryDirCount         ; A = n (0..)
        POP  BC

        OR   A
        JR   NZ,ilmLegal

        DJNZ ilmLoop

ilmNotLegal:
        XOR  A
        RET

ilmLegal:
        LD   A,1
        RET


; ---------------------------------------------------------
; flipDirN
;   Flips n stones in direction (tdDr,tdDc) starting from
;   one step away from (workRow,workCol).
;
; Inputs (memory):
;   workPlayer, workRow, workCol, tdDr, tdDc
; Input (reg):
;   A = n (1..)
; Output:
;   none
; Destroys:
;   AF,BC,DE,HL
; ---------------------------------------------------------
flipDirN:
        LD   (tdN),A
        OR   A
        RET  Z

        ; tdR = row + dr
        LD   A,(workRow)
        LD   E,A
        LD   A,(tdDr)
        ADD  A,E
        LD   (tdR),A

        ; tdC = col + dc
        LD   A,(workCol)
        LD   E,A
        LD   A,(tdDc)
        ADD  A,E
        LD   (tdC),A

fdLoop:
        LD   A,(tdN)
        OR   A
        RET  Z

        ; B=row, C=col from tdR/tdC
        LD   A,(tdR)
        LD   B,A
        LD   A,(tdC)
        LD   C,A

        CALL rowColToOffset      ; C=offset

        ; board[offset] = player
        LD   HL,board
        LD   E,C
        LD   D,0
        ADD  HL,DE
        LD   A,(workPlayer)
        LD   (HL),A

        ; n--
        LD   A,(tdN)
        DEC  A
        LD   (tdN),A

        ; advance r,c
        LD   A,(tdR)
        LD   E,A
        LD   A,(tdDr)
        ADD  A,E
        LD   (tdR),A

        LD   A,(tdC)
        LD   E,A
        LD   A,(tdDc)
        ADD  A,E
        LD   (tdC),A

        JR   fdLoop


; ---------------------------------------------------------
; applyMove
;   Applies a move for player at (row,col):
;     - scans 8 directions, flips where possible
;     - if flipped at least one direction, places own stone
;
; Inputs:
;   D = player (1/2)
;   B = row (0..3)
;   C = col (0..3)
; Output:
;   A = 1 success / 0 fail (illegal)
; Destroys:
;   AF,BC,DE,HL,IX,IY
; ---------------------------------------------------------
applyMove:
        ; store to work*
        LD   A,D
        LD   (workPlayer),A
        LD   A,B
        LD   (workRow),A
        LD   A,C
        LD   (workCol),A

        XOR  A
        LD   (amDidFlip),A

        ; direction loop
        LD   B,dirCnt
        LD   IX,dirDr
        LD   IY,dirDc

amLoop:
        LD   A,(IX+0)
        LD   (tdDr),A
        INC  IX

        LD   A,(IY+0)
        LD   (tdDc),A
        INC  IY

        PUSH BC
        CALL tryDirCount         ; A = n (0..)
        OR   A
        JR   Z,amNoFlip

        CALL flipDirN

        LD   A,1
        LD   (amDidFlip),A

amNoFlip:
        POP  BC
        DJNZ amLoop

        ; must flip at least once
        LD   A,(amDidFlip)
        OR   A
        JR   Z,amFail

        ; place own stone at start cell
        LD   A,(workRow)
        LD   B,A
        LD   A,(workCol)
        LD   C,A
        CALL rowColToOffset      ; C=offset

        LD   A,(workPlayer)
        CALL placeAtOffset

        LD   A,1
        RET

amFail:
        XOR  A
        RET


; =========================================================
; Compatibility aliases (optional during migration)
; =========================================================
TryDirCount     EQU tryDirCount
IsLegalMove     EQU isLegalMove
FlipDirN        EQU flipDirN
ApplyMove       EQU applyMove

WORK_PLAYER     EQU workPlayer
WORK_ROW        EQU workRow
WORK_COL        EQU workCol

TD_R            EQU tdR
TD_C            EQU tdC
TD_OPP          EQU tdOpp
TD_DR           EQU tdDr
TD_DC           EQU tdDc
TD_COUNT        EQU tdCount
TD_N            EQU tdN

AM_DIDFLIP      EQU amDidFlip

