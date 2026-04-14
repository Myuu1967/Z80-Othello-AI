; =========================================
; Super AKI-80 4x4 Othello
; Board display + AI move + Player input
; Serial I/O: SIOA (18h/19h)
; =========================================

        ORG 8000H
        JP START


; ==== 定数定義 ====

SIOA_DAT    EQU 18H       ; SIOA データポート
SIOA_CTL    EQU 19H       ; SIOA コマンド/ステータス

; 4x4 盤面の定義
BOARD_W     EQU 4          ; 列数 A～D
BOARD_H     EQU 4          ; 行数 1～4
EMPTY_CHAR  EQU '.'        ; 空きマスの表示

BLACK   EQU 1
WHITE   EQU 2
EMPTY   EQU 0

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

AImovePOS DEFB 'A','1', 0
AImoveMSG DEFM "AI moves to ",0

CR          EQU 0DH
LF          EQU 0AH
BS          EQU 08H
DEL         EQU 7FH

BUF_MAX     EQU 64          ; 受信最大長（終端0含まず）
RXBUF:      DEFS BUF_MAX    ; 受信バッファ

BEL         EQU 07H
LINE_MAX    EQU 20          ; 入力は最大20文字（21文字目からビープ）

START:
        
; ==== メインエントリ ====

        LD   SP,0FFF0H      ; 

        DI
        ; SIO 初期化はモニタ任せと仮定
P_START:
        CALL    PrintBoard
        CALL    AIset
        CALL    PrintBoard

        CALL    PlayerMove

        JP      P_START
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
        ; INC     D            ; '1'→'2'→'3'→'4'
        DJNZ    RowLoop

        POP     HL
        POP     DE
        POP     BC
        POP     AF
        RET


        ; AI の手を BOARD にセットする
; ---------------------------------
; AIset
; 左上(A1)から順にEMPTYを探して
; 最初に見つかったマスに BLACK を置く
; ---------------------------------
AIset:
        PUSH AF
        PUSH BC
        PUSH HL

        LD   HL,BOARD      ; 盤面先頭
        LD   B,16          ; 4x4 = 16マス

AI_Loop:
        LD   A,(HL)
        OR   A
        JR   Z,AI_Place    ; EMPTY(0)なら置く

        INC  HL
        DJNZ AI_Loop       ; まだ探索

        ; ここまで来たら置ける場所なし
        JR   AI_Done


AI_Place:
        LD   A,BLACK       ; 黒石
        LD   (HL),A

        ; ---- 置いた場所を表示 ----
        ; offset = HL - BOARD
        PUSH HL
        LD   DE,BOARD
        OR   A             ; carry clear
        SBC  HL,DE         ; HL = offset
        LD   A,L           ; 0..15
        POP  HL

        ; A = offset
        LD   C,A

        ; 列 = offset % 4
        LD   A,C
        AND  3
        ADD  A,'A'
        LD   (AImovePOS),A

        ; 行 = offset / 4
        LD   A,C
        SRL  A
        SRL  A
        ADD  A,'1'
        LD   (AImovePOS+1),A

        ; メッセージ表示
        LD   DE,AImoveMSG
        CALL PrintString
        LD   DE,AImovePOS
        CALL PrintString
        CALL NEWLINE

AI_Done:
        POP  HL
        POP  BC
        POP  AF
        RET


PlayerMove:
        ; プロンプト（任意）
        LD  A,'>'
        CALL PutChar
        LD  A,' '
        CALL PutChar

        ; 1行受信（HL=RXBUF, 戻りA=受信長）
        LD  HL,RXBUF
        CALL GETLINE

        LD A, (RXBUF)

        ; 入力を使って O(WHITE) を置く
        CALL PlayerSetWhite

        
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

; -----------------------------
; GETLINE
; HL: バッファ先頭
; 受信文字を保存し、CR/LFで確定。最後に 0 終端を付ける
; 戻り: A = 受信長（0..BUF_MAX-1）
; -----------------------------
GETLINE:
        LD  B,0             ; B=length

GL_LOOP:
        CALL GetChar        ; A=1文字

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
        CALL PutChar
        JR  GL_LOOP


;        LD  A,B              ; 長さチェック
;        CP  BUF_MAX-1
;        JR  NC,GL_LOOP

GL_STORE:
        LD  A,E
        LD  (HL),A
        INC HL
        INC B
        CALL PutChar        ; 入力中エコー
        JR  GL_LOOP

GL_BS:
        LD  A,B
        OR  A
        JR  Z,GL_LOOP       ; 0文字なら何もしない
        DEC HL
        DEC B

        ; 画面上も1文字消す（BS, space, BS）
        LD  A,BS
        CALL PutChar
        LD  A,' '
        CALL PutChar
        LD  A,BS
        CALL PutChar

        JR  GL_LOOP

GL_DONE:
        ; 改行してから「受信した行」を返す
        CALL NEWLINE
        LD  HL,RXBUF
        CALL PUTS0
        CALL NEWLINE

        XOR A
        LD  (HL),A          ; 0終端
        LD  A,B             ; length
        RET

; --- 受信（あなたのをほぼそのまま） ---
GetChar:
WRX:    XOR  A
        OUT  (SIOA_CTL),A    ; RR0選択
        IN   A,(SIOA_CTL)
        BIT  0,A
        JR   Z,WRX
        IN   A,(SIOA_DAT)
        RET


; 0終端文字列の送信（HL=文字列）
PUTS0:
PS0:    LD  A,(HL)
        OR  A
        RET Z
        CALL PutChar
        INC HL
        JR  PS0

NEWLINE:
        LD  A,CR
        CALL PutChar
        LD  A,LF
        CALL PutChar
        RET

; ---------------------------------
; PlayerSetWhite
; RXBUF の先頭2文字を "A1" のように解釈して
; BOARD に WHITE(=2) を書く
;  - 不正入力 / 盤外 / 埋まってる → BEL
; ---------------------------------
PlayerSetWhite:
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL

        ; まず2文字ある前提で読む（空行対策）
        LD   A,(RXBUF)
        OR   A
        JR   Z,PSW_Beep

        LD   A,(RXBUF+1)
        OR   A
        JR   Z,PSW_Beep

        ; ---- 列文字 col = RXBUF[0] を 0..3 に ----
        LD   A,(RXBUF)          ; 'A'..'D' or 'a'..'d'

        ; 小文字なら大文字へ（'a'..'z' → 'A'..'Z'）
        CP   'a'
        JR   C,PSW_ColIsUpper
        CP   'z'+1
        JR   NC,PSW_ColIsUpper
        AND  11011111b          ; bit5 を落として大文字化
PSW_ColIsUpper:

        SUB  'A'                ; 'A'->0
        CP   4
        JR   NC,PSW_Beep        ; 0..3 以外は盤外
        LD   B,A                ; B = col (0..3)

        ; ---- 行文字 row = RXBUF[1] を 0..3 に ----
        LD   A,(RXBUF+1)        ; '1'..'4'
        SUB  '1'
        CP   4
        JR   NC,PSW_Beep        ; 0..3 以外は盤外

        ; A = row(0..3)
        SLA  A
        SLA  A                  ; A = row*4
        ADD  A,B                ; A = row*4 + col
        LD   C,A
        LD   B,0                ; BC = offset

        ; HL = &BOARD[offset]
        LD   HL,BOARD
        ADD  HL,BC

        ; そのマスが空(0)かチェック
        LD   A,(HL)
        OR   A
        JR   NZ,PSW_Beep        ; 既に石がある

        ; WHITE(=2) を置く → 'O'
        LD   A,WHITE
        LD   (HL),A

        JR   PSW_Done

PSW_Beep:
        LD   A,BEL
        CALL PutChar

PSW_Done:
        POP  HL
        POP  DE
        POP  BC
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


        END