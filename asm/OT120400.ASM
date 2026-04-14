        ORG 8000H
        JP START


; ==== 定数定義 ====

SIOA_DAT    EQU 18H       ; SIOA データポート
SIOA_CTL    EQU 19H       ; SIOA コマンド/ステータス

; 4x4 盤面の定義
BOARD_W     EQU 4          ; 列数 A～D
BOARD_H     EQU 4          ; 行数 1～4
EMPTY_CHAR  EQU '.'        ; 空きマスの表示

COL_HEADER: DEFM "  A B C D",0
MSG_NEWLINE:DEFM 13,10,0   ; CR LF, 0終端

ROW_LABEL:  DEFB '1'       ; 現在の行番号（文字）用

; 0=空き, 1=黒, 2=白
BOARD:
        DEFB 0,0,0,0      ; 1行目
        DEFB 0,2,1,0      ; 2行目 (〇 ×)
        DEFB 0,1,2,0      ; 3行目 (× 〇)
        DEFB 0,0,0,0      ; 4行目

; index: 0=空き,1=黒,2=白
STONE_CHAR:
        DEFB '.'      ; 空きマス
        DEFB 'x'      ; 黒 → ×
        DEFB 'o'      ; 白 → 〇

START:
        
; ==== メインエントリ ====

        LD   SP,0FFF0H      ; 

        DI
        ; SIO 初期化はモニタ任せと仮定
        CALL    PrintBoardEmpty

Hang:
        JP      Hang

; ---------------------------------
; 盤面の初期表示（石なし）
; ---------------------------------
PrintBoardEmpty:
        PUSH AF
        PUSH BC
        PUSH DE

        ; 改行
        LD      DE,MSG_NEWLINE
        CALL    PrintString

        ; 列ヘッダ "  A B C D"
        LD      DE,COL_HEADER
        CALL    PrintString

        ; 改行
        LD      DE,MSG_NEWLINE
        CALL    PrintString

        ; 行カウンタ B = BOARD_H
        LD      B,BOARD_H
        LD      A,'1'
        LD      (ROW_LABEL),A

RowLoop:
        ; 行番号 1,2,3,4 の表示
        LD      A,(ROW_LABEL)
        CALL    PutChar

        ; 行番号の後ろにスペース
        LD      A,' '
        CALL    PutChar

        ; 列ループ C = BOARD_W
        LD      C,BOARD_W

ColLoop:
        ; 空きマス '.' を表示
        LD      A,EMPTY_CHAR
        CALL    PutChar

        ; マスの区切りスペース
        LD      A,' '
        CALL    PutChar

        DEC     C
        JR      NZ,ColLoop

        ; 行の最後で改行
        LD      DE,MSG_NEWLINE
        CALL    PrintString

        ; 次の行番号に進める
        LD      A,(ROW_LABEL)
        INC     A
        LD      (ROW_LABEL),A

        DEC     B
        JR      NZ,RowLoop

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