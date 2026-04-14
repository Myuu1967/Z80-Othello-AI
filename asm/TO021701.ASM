; ================================================
; Z80 SIOA Echo Test Program
; 受信した1文字をそのまま送信する最小構成のテストコード
; SIO初期化はモニタ任せ（RR0 bit0=Rx Ready, bit2=Tx Ready前提）
; Created for basic RX/TX confirmation
; ================================================

        ORG 8000H
        JP  START

SIOA_DAT    EQU 18H
SIOA_CTL    EQU 19H

START:
        DI
        LD  SP,0FFF0H

ECHO_LOOP:
        LD  A, 'A'
        CALL PUTCHAR      ; 'A' を送信
        CALL WAIT_1        ; ちょっと待つ（モニタの処理が終わるのを待つ)

        CALL GETCHAR      ; A = 受信
        CALL WAIT_1        ; ちょっと待つ（モニタの処理が終わるのを待つ）

        CALL PUTCHAR      ; A を送信
        CALL WAIT_1        ; ちょっと待つ（モニタの処理が終わるのを待つ）
        
        JP   ECHO_LOOP

; --- 受信 ---
GETCHAR:
WRX:    XOR  A
        OUT  (SIOA_CTL),A    ; RR0選択（モニタ影響を受けにくく）
        IN   A,(SIOA_CTL)
        BIT  0,A
        JR   Z,WRX
        IN   A,(SIOA_DAT)
        RET

; --- 送信 ---
PUTCHAR:
        PUSH AF
WTX:    XOR  A
        OUT  (SIOA_CTL),A    ; RR0選択
        IN   A,(SIOA_CTL)
        BIT  2,A
        JR   Z,WTX
        POP  AF
        OUT  (SIOA_DAT),A
        RET


; -----------------------------
WAIT_1:
        LD      B, 155D
W1_1:   LD      C, 21D
W2_1:   DEC     C
        JP      NZ, W2_1
        DEC     B
        JP      NZ, W1_1
        RET


        END
