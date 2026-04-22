; =========================================================
; SIOA 単体テスト (ROM 0000H)
;   起動後 CR LF "SIOA OK" CR LF を約1秒ごとに繰り返し送信
; =========================================================

SIOA_DAT  EQU 18H
SIOA_CTL  EQU 19H
CR        EQU 0DH
LF        EQU 0AH

        ORG  0000H
        JP   START

; ---------------------------------------------------------
; InitCTC3
;   CTC3 (port 13H) をタイマーモードで起動
;   10MHz / 16 / 4 = 156250Hz → SIOA RXCA/TXCA へ供給
;   SIOA x16モードで 156250/16 ≈ 9600bps
; ---------------------------------------------------------
InitCTC3:
        LD   A,17H          ; タイマーモード / プリスケーラ/16 / TC続く / リセット
        OUT  (13H),A        ; CTC3 コントロールワード
        LD   A,04H          ; 時定数 = 4 (/4) → タイマー起動
        OUT  (13H),A        ; CTC3 時定数
        RET

; ---------------------------------------------------------
; InitSIOA
;   CTC3 起動後に呼ぶこと
; ---------------------------------------------------------
InitSIOA:
        LD   HL,SIOA_INIT_TBL
        LD   B,9
        LD   C,SIOA_CTL
        OTIR
        RET

SIOA_INIT_TBL:
        DEFB 18H            ; WR0: チャンネルリセット
        DEFB 04H            ; WR0: WR4 選択
        DEFB 44H            ; WR4: x16クロック, 1ストップ, パリティなし
        DEFB 03H            ; WR0: WR3 選択
        DEFB 0C1H           ; WR3: 受信有効, 8bit
        DEFB 05H            ; WR0: WR5 選択
        DEFB 6AH            ; WR5: 送信有効, 8bit, RTS
        DEFB 01H            ; WR0: WR1 選択
        DEFB 00H            ; WR1: 割り込みなし

MSG:    DEFM CR,LF,"SIOA OK",CR,LF,0

; ---------------------------------------------------------
; START
; ---------------------------------------------------------
START:
        LD   SP,0FFF0H
        DI
        ; PIOA/PIOB 初期化 (モニタROM 0080H と同等)
        LD   A,0CFH
        OUT  (1DH),A        ; PIOA CMD: Mode3
        LD   A,01H
        OUT  (1DH),A        ; PIOA 方向: bit0=入力, 他=出力
        LD   A,0CFH
        OUT  (1FH),A        ; PIOB CMD: Mode3
        LD   A,00H
        OUT  (1FH),A        ; PIOB 方向: 全出力
        ; PPI0/PPI1 初期化 (モニタROM 0090H と同等)
        LD   A,80H
        OUT  (33H),A        ; PPI0: Mode0, 全出力
        OUT  (37H),A        ; PPI1: Mode0, 全出力
        CALL InitSIOA       ; 先に SIOA 初期化
        CALL InitCTC3       ; その後ボーレートクロックを起動

MAIN:
        LD   HL,MSG
SEND:
        LD   A,(HL)
        OR   A
        JR   Z,DELAY
        CALL PutChar
        INC  HL
        JR   SEND

DELAY:
        LD   D,6            ; 約1秒待ち (6 × 65536 ループ @ 10MHz)
DLY1:
        LD   BC,0
DLY2:
        DEC  BC
        LD   A,B
        OR   C
        JR   NZ,DLY2
        DEC  D
        JR   NZ,DLY1
        JP   MAIN

; ---------------------------------------------------------
; PutChar  A = 送信文字
; ---------------------------------------------------------
PutChar:
        PUSH AF
WAIT_TX:
        XOR  A
        OUT  (SIOA_CTL),A   ; レジスタポインタを RR0 にリセット
        IN   A,(SIOA_CTL)   ; RR0 読み取り
        BIT  2,A            ; bit2 = TxRDY
        JR   Z,WAIT_TX
        POP  AF
        OUT  (SIOA_DAT),A
        RET

        END  START
