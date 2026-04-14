        ORG 8000H
        JP START

SIOA_DAT    EQU 18H
SIOA_CTL    EQU 19H

START:
        LD   SP,0FFF0H
        DI

        LD   DE,MSG_ECHO
        CALL PrintString

EchoLoop:
        CALL GetChar        ; A = 受信文字
        PUSH AF             ; 文字を保存

        ; "Rx=" を表示
        LD   DE,MSG_RX
        CALL PrintString

        ; 受信文字を16進表示
        POP  AF             ; A = 受信文字
        CALL PrintHex8      ; "xx" を表示

        ; 改行
        LD   A,13
        CALL PutChar
        LD   A,10
        CALL PutChar

        JR   EchoLoop

; ==== 1バイトを16進2桁で表示 ====
; A に値、破壊される
PrintHex8:
        PUSH AF
        PUSH BC

        ; 上位4ビット
        SRL  A
        SRL  A
        SRL  A
        SRL  A              ; A = A >> 4
        CALL NibbleToHex

        ; 下位4ビット
        POP  BC             ; B に元の値を退避しておく方がきれいだが
        PUSH BC             ; 今回は簡略化してもう一度読むなら工夫

        ; もう一回元の値を得たいので工夫版：
        POP  BC             ; BC破壊OKとする
        LD   A,C            ; C に元の値を入れておくとよい
        PUSH BC

        AND  0FH
        CALL NibbleToHex

        POP  BC
        POP  AF
        RET

; ニブル(0?15)を '0'?'9','A'?'F' にして出力
NibbleToHex:
        AND  0FH
        ADD  A,'0'
        CP   '9'+1
        JR   C,HexOut
        ADD  A,7            ; 'A' - ':' = 7
HexOut:
        CALL PutChar
        RET

; ==== A の文字を送信 ====
PutChar:
        PUSH AF
WaitTx:
        IN   A,(SIOA_CTL)
        BIT  2,A
        JR   Z,WaitTx
        POP  AF
        OUT  (SIOA_DAT),A
        RET

; ==== 0終端文字列を表示 ====
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

; ==== 1文字受信 ====
GetChar:
WaitRx:
        IN   A,(SIOA_CTL)
        BIT  0,A            ; Rx char available?
        JR   Z,WaitRx
        IN   A,(SIOA_DAT)   ; A = 受信文字
        RET

; ==== メッセージ ====
MSG_ECHO:
        DEFM 13,10,"SIO RX HEX TEST",13,10,0
        DEFM 0

MSG_RX:
        DEFM "Rx=",0

; -----------------------------
WAIT_1:
        LD      B, 80D
W1_1:   LD      C, 51D
W2_1:   DEC     C
        JP      NZ, W2_1
        DEC     B
        JP      NZ, W1_1
        RET


        END START
