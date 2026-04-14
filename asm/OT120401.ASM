        ORG 8000H
        JP START


; ==== 定数定義 ====

SIOA_DAT    EQU 18H       ; SIOA データポート
SIOA_CTL    EQU 19H       ; SIOA コマンド/ステータス

; 4x4 盤面の定義
BOARD_W     EQU 4          ; 列数 A～D
BOARD_H     EQU 4          ; 行数 1～4
EMPTY_CHAR  EQU '.'        ; 空きマスの表示

COL_HEADER:   DEFM "  A B C D",0
MSG_NEWLINE:  DEFM 13,10,0     ; CR LF

ROW_LABEL:  DEFB '1'       ; 現在の行番号（文字）用


; 0=空き, 1=黒(X), 2=白(O)
BOARD:
        DEFB 0,0,0,0      ; 1行目
        DEFB 0,2,1,0      ; 2行目 (O X)
        DEFB 0,1,2,0      ; 3行目 (X O)
        DEFB 0,0,0,0      ; 4行目

; index: 0=空き,1=黒,2=白
STONE_CHAR:
        DEFB '.'      ; 空きマス
        DEFB 'X'      ; 黒 → ×
        DEFB 'O'      ; 白 → 〇

START:
        
; ==== メインエントリ ====

        LD   SP,0FFF0H      ; 

        DI
        ; SIO 初期化はモニタ任せと仮定
        CALL    PrintBoard

Hang:
        JP      Hang


; ---------------------------------
; BOARD の内容を 4x4 で表示する
;  空き: .   黒: X   白: O
; ---------------------------------
PrintBoard:
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL

        ; 1行空ける
        LD      DE,MSG_NEWLINE
        CALL    PrintString

        ; 列ヘッダ "  A B C D"
        LD      DE,COL_HEADER
        CALL    PrintString

        ; 改行
        LD      DE,MSG_NEWLINE
        CALL    PrintString

        ; HL = BOARD 先頭
        LD      HL,BOARD

        ; 行数 B=4, 行番号 D='1'
        LD      B,4

RowLoop:
        ; 行番号 '1','2','3','4'
        LD      A,'5'	  ; '1' の次の文字
        SUB     B         ; B=4→'1',3→'2',2→'3',1→'4'
        CALL    PutChar

        ; スペース1つ
        LD      A,' '
        CALL    PutChar

        ; 列ループ C=4
        LD      C,4

ColLoop:
        ; BOARD から値を読む (0,1,2)
        LD      A,(HL)
        INC     HL

        ; A = 0,1,2 を文字に変換
        OR      A
        JR      Z,CellEmpty     ; 0 → 空き

        CP      1
        JR      Z,CellBlack     ; 1 → 黒

        ; ここに来たら 2 → 白
CellWhite:
        LD      A,'O'
        JR      PrintCell

CellBlack:
        LD      A,'X'
        JR      PrintCell

CellEmpty:
        LD      A,'.'

PrintCell:
        CALL    PutChar

        ; 各マスの後ろにスペース（行末もそのまま入れてOK）
        LD      A,' '
        CALL    PutChar

        DEC     C
        JR      NZ,ColLoop

        ; 行末で改行
        LD      DE,MSG_NEWLINE
        CALL    PrintString

        ; 次の行番号へ
        INC     D            ; '1'→'2'→'3'→'4'
        DJNZ    RowLoop

        POP     HL
        POP     DE
        POP     BC
        POP     AF
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

; ==== メッセージ ====
MSG_ECHO:
        DEFM 13,10,"SIO RX HEX TEST",13,10,0
        DEFM 0

MSG_RX:
        DEFM "Rx=",0

; -----------------------------
WAIT_1:
        LD      B, 155D
W1_1:   LD      C, 21D
W2_1:   DEC     C
        JP      NZ, W2_1
        DEC     B
        JP      NZ, W1_1
        RET


        END START