; =========================================================
; Super AKI-80 8x8 REVERSI
; ---------------------------------------------------------
; Target : Z80 (Super AKI-80)
; Serial : SIOA  DAT=18h  CTL=19h  (SIO init by monitor)
;
; =========================================================

        ORG 8000H
        JP  START


; =========================================================
; I/O ports (SIOA, SIOB)
; =========================================================
SIOA_DAT        EQU 18H
SIOA_CTL        EQU 19H
SIOB_DAT        EQU 1AH
SIOB_CTL        EQU 1BH

; =========================================================
; ASCII / control chars
; =========================================================
CR              EQU 0DH
LF              EQU 0AH
BS              EQU 08H
DEL             EQU 7FH
BEL             EQU 07H

MSG:            DB 'Hello, World!',CR,LF,0

; =========================================================
; Main entry
; =========================================================

START:
        LD   SP,0FFF0H
        DI

LOOP:
        LD   A,'A'   
        CALL PutChar

        CALL WAIT_TIME

        CALL NEWLINE
        LD   DE,MSG
        CALL PrintString
        CALL WAIT_TIME

        JR  LOOP

        RST  00H
        HALT


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
; WaitTime
;   destroys: AF,BC
; ---------------------------------------------------------

WAIT_TIME:
        PUSH AF
        PUSH BC

        LD   A,0

WT_LOOP2:
        LD   B,0

WT_LOOP:
        DEC  B
        JR   NZ,WT_LOOP

        DEC  A
        JR   NZ,WT_LOOP2

        POP  BC
        POP  AF

        RET


        END START

