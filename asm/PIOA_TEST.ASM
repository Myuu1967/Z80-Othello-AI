; =========================================================
; PIOA D7 トグルテスト (ROM 0000H)
;   SIOAを使わずPIOA D7をトグルし続ける
;   Pico GPIO15 で受信できればEEPROMのコードは実行されている
;   約0.7秒周期でHIGH/LOWを繰り返す
; =========================================================

PIOA_DATA EQU 1CH
PIOA_CMD  EQU 1DH

        ORG  0000H
        JP   START

START:
        LD   SP,0FFF0H
        DI
        ; PPI0/PPI1 初期化
        LD   A,80H
        OUT  (33H),A
        OUT  (37H),A
        ; PIOA: Mode3, 全出力
        LD   A,0CFH
        OUT  (PIOA_CMD),A
        LD   A,00H
        OUT  (PIOA_CMD),A

LOOP:
        LD   A,80H
        OUT  (PIOA_DATA),A      ; D7 HIGH
        CALL DELAY
        LD   A,00H
        OUT  (PIOA_DATA),A      ; D7 LOW
        CALL DELAY
        JP   LOOP

; 約0.35秒待ち (65536 × 3 ループ @ 10MHz ≈ 0.33秒)
DELAY:
        PUSH BC
        LD   BC,0
DLY:    DEC  BC
        LD   A,B
        OR   C
        JR   NZ,DLY
        POP  BC
        RET

        END  START
