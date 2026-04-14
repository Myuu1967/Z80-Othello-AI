; =========================================================
; MEASURE_TIME.ASM
; Super AKI-80 (Z80)  CTC CH0 タイマー計測デモ (ポーリング版)
; ---------------------------------------------------------
; Target : Z80  Super AKI-80  @10MHz
; Serial : SIOA  DAT=18h  CTL=19h  (SIO init by monitor)
;
; =========================================================

        ORG  8000H
        JP   START


; =========================================================
; I/O ポート
; =========================================================
SIOA_DAT        EQU 18H
SIOA_CTL        EQU 19H

; =========================================================
; PIO 
; =========================================================
PIOA_DATA       EQU 1CH
PIOA_CMD        EQU 1DH

; =========================================================
; ASCII 制御文字
; =========================================================
CR              EQU 0DH
LF              EQU 0AH
BEL             EQU 07H


; =========================================================
; 文字列 (0終端)
; =========================================================
MSG_MSTART:
        DEFM "Measuring...",CR,LF,0

MSG_MSTOP:
        DEFM "DONE!",CR,LF,0

MSG_RETRYQ:
        DEFM "r:Retry  q:Quit > ",0

MSG_BYE:
        DEFM CR,LF,"Bye.",CR,LF,0


; =========================================================
; 変数 / 作業領域
; =========================================================

; =========================================================
; メインエントリ
; =========================================================
START:
        LD   SP,0FFF0H

        DI                      ; 時間計測中は割り込み禁止

MAIN_LOOP:
        CALL StartTimer

        LD   DE,MSG_MSTART
        CALL PrintString

        ; ---- 計測対象: ここに測りたい処理を書く ----
        ; 注意: 6554μs 以内に CALL PollCTC が必要
        CALL DummyWork
        ; ---- 計測対象ここまで ----

        CALL StopTimer

        LD   DE,MSG_MSTOP
        CALL PrintString

        ; r / q 待ち
        LD   DE,MSG_RETRYQ
        CALL PrintString

RQ_WAIT:
        CALL GetChar
        CALL PutChar            ; エコー
        CALL Newline

        CP   'r'
        JP   Z,MAIN_LOOP
        CP   'R'
        JP   Z,MAIN_LOOP
        CP   'q'
        JR   Z,RQ_QUIT
        CP   'Q'
        JR   Z,RQ_QUIT

        LD   A,BEL
        CALL PutChar
        JR   RQ_WAIT

RQ_QUIT:
        LD   DE,MSG_BYE
        CALL PrintString
        RST  00H
        HALT


; =========================================================
; DummyWork
;   計測対象のダミー処理。実際のプログラムではここを差し替える。
;
; Destroys: AF, DE
; =========================================================


DummyWork:
        PUSH AF
        PUSH BC
        PUSH DE

        LD   DE, 0
DW_Wait:
        NOP
        NOP
        NOP
        NOP
        DEC  DE
        LD   A, D
        OR   E
        JR   NZ, DW_Wait

        POP  DE
        POP  BC
        POP  AF

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
; シリアル I/O
; =========================================================

; ---------------------------------------------------------
; PutChar  A=1文字送信
; Destroys: AF
; ---------------------------------------------------------
PutChar:
        PUSH AF
PUT_Wait:
        IN   A,(SIOA_CTL)
        BIT  2,A                ; Tx Ready?
        JR   Z,PUT_Wait
        POP  AF
        OUT  (SIOA_DAT),A
        RET

; ---------------------------------------------------------
; GetChar  A=1文字受信 (ブロッキング)
; Destroys: AF
; ---------------------------------------------------------
GetChar:
GC_Wait:
        XOR  A
        OUT  (SIOA_CTL),A
        IN   A,(SIOA_CTL)
        BIT  0,A                ; Rx Ready?
        JR   Z,GC_Wait
        IN   A,(SIOA_DAT)
        RET

; ---------------------------------------------------------
; PrintString  DE=0終端文字列を送信
; Destroys: AF,DE
; ---------------------------------------------------------
PrintString:
        PUSH AF
        PUSH DE
PS_Loop:
        LD   A,(DE)
        OR   A
        JR   Z,PS_Done
        CALL PutChar
        INC  DE
        JR   PS_Loop
PS_Done:
        POP  DE
        POP  AF
        RET

; ---------------------------------------------------------
; Newline  CR+LF を送信
; Destroys: AF
; ---------------------------------------------------------
Newline:
        PUSH AF
        LD   A,CR
        CALL PutChar
        LD   A,LF
        CALL PutChar
        POP  AF
        RET

        END  START
