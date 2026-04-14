; ================================================
; Z80 SIOA Line Receive Test
; Enter( CR/LF )まで受信してバッファに保存し、1行を返す
;  - CR(0Dh) / LF(0Ah) どちらでも確定
;  - Backspace(08h/7Fh)で1文字削除（簡易）
;  - 受信中はキーをエコー表示
; ================================================

        ORG 8000H
        JP  START

SIOA_DAT    EQU 18H
SIOA_CTL    EQU 19H

CR          EQU 0DH
LF          EQU 0AH
BS          EQU 08H
DEL         EQU 7FH

BUF_MAX     EQU 64          ; 受信最大長（終端0含まず）
RXBUF:      DEFS BUF_MAX    ; 受信バッファ

BEL         EQU 07H
LINE_MAX    EQU 20          ; 入力は最大20文字（21文字目からビープ）


START:
        DI
        LD  SP,0FFF0H

MAIN:
        ; プロンプト（任意）
        LD  A,'>'
        CALL PUTCHAR
        LD  A,' '
        CALL PUTCHAR

        ; 1行受信（HL=RXBUF, 戻りA=受信長）
        LD  HL,RXBUF
        CALL GETLINE

        ; 改行してから「受信した行」を返す
        CALL NEWLINE
        LD  HL,RXBUF
        CALL PUTS0
        CALL NEWLINE

        JP  MAIN

; -----------------------------
; GETLINE
; HL: バッファ先頭
; 受信文字を保存し、CR/LFで確定。最後に 0 終端を付ける
; 戻り: A = 受信長（0..BUF_MAX-1）
; -----------------------------
GETLINE:
        LD  B,0             ; B=length

GL_LOOP:
        CALL GETCHAR        ; A=1文字

        CP  CR
        JR  Z,GL_DONE
        CP  LF
        JR  Z,GL_DONE

        ; バックスペース対応（任意）
        CP  BS
        JR  Z,GL_BS
        CP  DEL
        JR  Z,GL_BS

; ---- 通常文字（CR/LF, BS/DEL以外） ----

        LD  E,A             ; 受信文字を退避

        ; すでに20文字なら保存しないでビープ
        LD  A,B
        CP  LINE_MAX
        JR  C,GL_STORE      ; B < 20 なら保存OK

        ; 21文字目以降：捨ててビープ（表示は増やさない）
        LD  A,BEL
        CALL PUTCHAR
        JR  GL_LOOP


;        LD  A,B              ; 長さチェック
;        CP  BUF_MAX-1
;        JR  NC,GL_LOOP

GL_STORE:
        LD  A,E
        LD  (HL),A
        INC HL
        INC B
        CALL PUTCHAR        ; 入力中エコー
        JR  GL_LOOP

GL_BS:
        LD  A,B
        OR  A
        JR  Z,GL_LOOP       ; 0文字なら何もしない
        DEC HL
        DEC B

        ; 画面上も1文字消す（BS, space, BS）
        LD  A,BS
        CALL PUTCHAR
        LD  A,' '
        CALL PUTCHAR
        LD  A,BS
        CALL PUTCHAR

        JR  GL_LOOP

GL_DONE:
        XOR A
        LD  (HL),A          ; 0終端
        LD  A,B             ; length
        RET

; --- 受信（あなたのをほぼそのまま） ---
GETCHAR:
WRX:    XOR  A
        OUT  (SIOA_CTL),A    ; RR0選択
        IN   A,(SIOA_CTL)
        BIT  0,A
        JR   Z,WRX
        IN   A,(SIOA_DAT)
        RET

; --- 送信（あなたのをほぼそのまま） ---
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

; 0終端文字列の送信（HL=文字列）
PUTS0:
PS0:    LD  A,(HL)
        OR  A
        RET Z
        CALL PUTCHAR
        INC HL
        JR  PS0

NEWLINE:
        LD  A,CR
        CALL PUTCHAR
        LD  A,LF
        CALL PUTCHAR
        RET

        END
