; =========================================================
; Super AKI-80 4x4 Othello (Prototype)
; ---------------------------------------------------------
; - 4x4盤面表示（'.' 空き / 'X' 黒(AI) / 'O' 白(プレイヤ))
; - AI: 左上(A1)から順に空きを探して黒を1手置く
; - Player: "A1"～"D4" を入力して白を置く（不正/埋まりはBEL）
; - 入力行: 最大20文字（21文字目以降はBELで捨てる）
; - 終局: 盤面の空き('.')が無くなったら GAME OVER を表示して停止
; - Move解析を関数分割：ParseMove(入力→offset) / PlaceAtOffset(offset→配置)
; Serial I/O: Z80 SIOA (DAT=18h, CTL=19h) / SIO初期化はモニタ任せ
; =========================================================

        ORG 8000H
        JP START


; ==== 定数定義 ====

SIOA_DAT    EQU 18H       ; SIOA データポート
SIOA_CTL    EQU 19H       ; SIOA コマンド/ステータス

; 4x4 盤面の定義
BOARD_W     EQU 4          ; 列数 A～D
BOARD_H     EQU 4          ; 行数 1～4

BLACK   EQU 1
WHITE   EQU 2
EMPTY   EQU 0

COL_HEADER:   DEFM "  A B C D",0
MSG_NEWLINE:  DEFM 13,10,0     ; CR LF


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

MSG_GAMEOVER:  DEFM 13,10,"GAME OVER",13,10,0

MSG_PROMPT:     DEFM "Your move (A1-D4) > ",0
MSG_INVALID:    DEFM 13,10,"Invalid move. Try again.",13,10,0
; もう少し丁寧にしたいなら：
; MSG_INVALID: DEFM 13,10,"Invalid/occupied/out of board. Try again.",13,10,0

; 盤面の8方向探索用テーブル（フェーズ2以降で使用）
DIR_DR:  DEFB -1,-1,-1, 0,0, 1,1,1
DIR_DC:  DEFB -1, 0, 1,-1,1,-1,0,1
DIR_CNT  EQU 8

START:
        
; ==== メインエントリ ====

        LD   SP,0FFF0H      ; 

        DI
        ; SIO 初期化はモニタ任せと仮定

        CALL    PrintBoard
P_START:

        CALL    AIset
        CALL    PrintBoard

        ; --- AIが置いた後に満杯なら終局 ---
        CALL    IsBoardFull
        OR      A
        JP      NZ,GameOver

        CALL    PlayerMove
        CALL    PrintBoard

        ; --- プレイヤが置いた後に満杯なら終局 ---
        CALL    IsBoardFull
        OR      A
        JP      NZ,GameOver

        JP      P_START

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
        LD      A,(HL)        ; A=0,1,2
        INC     HL            ; 次の盤面セルへ

        LD      E,A
        LD      D,0
        PUSH    HL            ; ★BOARDのHLを守る
        LD      HL,STONE_CHAR
        ADD     HL,DE
        LD      A,(HL)
        POP     HL            ; ★BOARDへ戻す

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
PM_Loop:
        ; プロンプト
        LD   DE,MSG_PROMPT
        CALL PrintString

        ; 1行受信（HL=RXBUF, 戻りA=受信長）
        LD   HL,RXBUF
        CALL GETLINE

        ; 入力を使って O(WHITE) を置く（戻りA=1成功 / 0失敗）
        CALL PlayerSetWhite
        OR   A
        RET  NZ              ; 成功なら戻る

        ; 失敗：メッセージを出して再入力
        LD   DE,MSG_INVALID
        CALL PrintString
        JR   PM_Loop


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
        LD   A,0
        LD   (HL),A          ; 先に0終端

        CALL NEWLINE
        LD   DE,RXBUF
        CALL PrintString
        CALL NEWLINE

        LD   A,B             ; length
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

NEWLINE:
        LD  A,CR
        CALL PutChar
        LD  A,LF
        CALL PutChar
        RET


; ---------------------------------
; PlayerSetWhite
; RXBUF 先頭2文字の指し手を解析して、空きマスなら WHITE を置く
; 戻り: A=1 成功 / A=0 失敗（BELは下位関数が鳴らす）
; ---------------------------------
PlayerSetWhite:
        PUSH BC
        PUSH DE
        PUSH HL

        CALL ParseMove           ; A=1成功, C=offset(0..15)
        OR   A
        JR   Z,PSW_Fail

        LD   A,WHITE             ; 置く色
        CALL PlaceAtOffset       ; A=1成功/0失敗

        JR   PSW_Done

PSW_Fail:
        XOR  A                   ; 念のため A=0

PSW_Done:
        POP  HL
        POP  DE
        POP  BC
        RET


; ---------------------------------
; ParseMove
; RXBUF の先頭2文字を "A1" のように解釈して offset(0..15) を作る
;  - 列: 'A'..'D' / 'a'..'d' → 0..3
;  - 行: '1'..'4' → 0..3
; 戻り:
;   成功: A=1, C=offset(0..15)
;   失敗: A=0（BELを鳴らす）
; 破壊: AF,BC
; ---------------------------------
ParseMove:
        ; 2文字あるか（空行対策）
        LD   A,(RXBUF)
        OR   A
        JR   Z,PM_BeepFail
        LD   A,(RXBUF+1)
        OR   A
        JR   Z,PM_BeepFail

        ; --- 列 ---
        LD   A,(RXBUF)           ; 'A'..'D' or 'a'..'d'

        ; 小文字→大文字
        CP   'a'
        JR   C,PM_ColUpper
        CP   'z'+1
        JR   NC,PM_ColUpper
        AND  11011111b
PM_ColUpper:
        SUB  'A'                 ; 0..?
        CP   4
        JR   NC,PM_BeepFail
        LD   B,A                 ; B=col(0..3)

        ; --- 行 ---
        LD   A,(RXBUF+1)         ; '1'..'4'
        SUB  '1'                 ; 0..?
        CP   4
        JR   NC,PM_BeepFail

        ; offset = row*4 + col
        SLA  A
        SLA  A                   ; row*4
        ADD  A,B                 ; +col
        LD   C,A                 ; C=offset(0..15)

        LD   A,1                 ; success
        RET

PM_BeepFail:
        LD   A,BEL
        CALL PutChar
        XOR  A                   ; fail (A=0)
        RET


; ---------------------------------
; PlaceAtOffset
; BOARD[offset] が空(0)なら stone(A) を置く
; 入力:
;   A = stone (BLACK=1 / WHITE=2)
;   C = offset (0..15)
; 戻り:
;   成功: A=1
;   失敗: A=0（埋まり/範囲外はBEL）
; 破壊: AF,BC,HL
; ---------------------------------
PlaceAtOffset:
        ; Cが0..15の想定（ParseMove経由なら保証される）
        LD   B,A                 ; B=stone
        LD   HL,BOARD
        LD   E,C
        LD   D,0
        ADD  HL,DE               ; HL=&BOARD[offset]

        LD   A,(HL)
        OR   A
        JR   NZ,PAO_BeepFail     ; 既に石あり

        LD   A,B
        LD   (HL),A              ; 置く

        LD   A,1                 ; success
        RET

PAO_BeepFail:
        LD   A,BEL
        CALL PutChar
        XOR  A                   ; fail
        RET


; ---------------------------------
; IsBoardFull
; BOARD(16byte)にEMPTY(0)が残っているか調べる
; 戻り: A=1 盤面が満杯（終局）
;       A=0 EMPTYあり（続行）
; 破壊: AF,BC,HL
; ---------------------------------
IsBoardFull:
        PUSH HL
        PUSH BC

        LD   HL,BOARD
        LD   B,16

IBF_Loop:
        LD   A,(HL)
        OR   A
        JR   Z,IBF_NotFull     ; EMPTYを発見 → 続行
        INC  HL
        DJNZ IBF_Loop

        ; EMPTYなし → 満杯
        LD   A,1
        JR   IBF_Done

IBF_NotFull:
        XOR  A                 ; A=0

IBF_Done:
        POP  BC
        POP  HL
        RET


; ---------------------------------
; GameOver
; GAME OVERを表示して停止
; ---------------------------------
GameOver:
        LD   DE,MSG_GAMEOVER
        CALL PrintString
GO_Hang:
        JP   GO_Hang

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