; =========================================================
; Super AKI-80 4x4 Othello
; ---------------------------------------------------------
; Main focus:
;   - 先手、後手を決めるルーチンを実装
;   - プレイヤーの入力を受け付けて合法手なら盤面更新
;   - 盤面表示を整える
;   - AI側も反転ロジックを使って着手（最初は単純に空きマスに置くだけ）
;   - 1手ごとに盤面が満杯かチェックして終局判定
;
; Target environment:
;   - Z80 (Super AKI-80)
;   - Serial I/O: SIOA (DAT=18h, CTL=19h)
;   - SIO初期化はモニタ任せ
;
; Implemented core logic:
; =========================================================

        ORG 8000H
        JP START


; ==== 定数定義 ====

SIOA_DAT    EQU 18H       ; SIOA データポート
SIOA_CTL    EQU 19H       ; SIOA コマンド/ステータス

; 4x4 盤面の定義
BOARD_W     EQU 4                   ; 列数 A～D
BOARD_H     EQU 4                   ; 行数 1～4
BOARD_BYTES  EQU BOARD_W*BOARD_H    ; バイト数

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


; ---- IsLegalMove / TryDir 用ワーク ----
WORK_PLAYER   DEFB 0
WORK_ROW      DEFB 0
WORK_COL      DEFB 0

TD_R          DEFB 0
TD_C          DEFB 0
TD_FOUND      DEFB 0
TD_OPP        DEFB 0

TD_DR         DEFB 0
TD_DC         DEFB 0
; ----------------------------------------

MSG_BADFMT:   DEFM 13,10,"Bad input. Use A1-D4.",13,10,0
MSG_LEGAL:    DEFM 13,10,"OK (legal move).",13,10,0
MSG_ILLEGAL:  DEFM 13,10,"NG (illegal move).",13,10,0
MSG_ILLEGAL2:  DEFM 13,10,"NG2 (illegal move).",13,10,0


; TryDirCount で使用
TD_COUNT:  DEFB 0    ; この方向で挟める相手石の枚数

; FripDirNで使用
TD_N:      DEFB 0     ; Flip枚数カウンタ（1..）

;=========================

; ==============================
; 変数領域
; ==============================
AiSide:     DEFB 0     ; AIの石 (BLACK/WHITE)
HumSide:    DEFB 0     ; 人の石 (BLACK/WHITE)
TurnSide:   DEFB 0     ; 次に打つ側 (BLACK/WHITE)


; --- ApplyMove用ワーク（1バイト） ---
AM_DIDFLIP:  DEFB 0

CNT_MSG: DEFM "CNT: ",0


; ==============================
; メッセージ（0終端）
; ==============================
MsgAiDecides:
        DEFM "AI decides who goes first...",13,10,0

MsgAiFirst:
        DEFM "AI goes first. You are WHITE (O).",13,10,0

MsgHumanFirst:
        DEFM "You go first. You are BLACK (X).",13,10,0

AI_PASSED:    DEFB 0
PL_PASSED:    DEFB 0
MSG_AI_PASS:  DEFM "AI PASS",13,10,0
MSG_PL_PASS:  DEFM "YOU PASS",13,10,0

PassStreak:   DEFB 0     ; 連続PASS回数（0..2）

START:
        LD   SP,0FFF0H

        DI
        ; SIO 初期化はモニタ任せと仮定

        CALL    PrintBoard
TurnDecide:
        CALL    DecideFirstTurn




MAIN_LOOP:
        CALL    DoTurn
        OR      A
        JP      NZ,GameOver     ; ★追加：双方PASSで終局

        CALL    PrintBoard

        CALL    IsBoardFull
        OR      A
        JP      NZ,GameOver

        JP      MAIN_LOOP


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
        LD      B,BOARD_H

RowLoop:
        ; 行番号 '1','2','3','4'
        LD      A,'5'	  ; '1' の次の文字
        SUB     B         ; B=4→'1',3→'2',2→'3',1→'4'
        CALL    PutChar

        ; スペース1つ
        LD      A,' '
        CALL    PutChar

        ; 列ループ C=4
        LD      C,BOARD_W



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
; AIset_old
; 左上(A1)から順にEMPTYを探して
; 最初に見つかったマスに BLACK を置く
; 反転しない
; ---------------------------------
AIset_old:
        PUSH AF
        PUSH BC
        PUSH HL

        LD   HL,BOARD      ; 盤面先頭
        LD   B,BOARD_BYTES ; 4x4 = 16マス

AI_Loop:
        LD   A,(HL)
        OR   A
        JR   Z,AI_Place    ; EMPTY(0)なら置く

        INC  HL
        DJNZ AI_Loop       ; まだ探索

        ; ここまで来たら置ける場所なし
        JR   AI_Done


AI_Place:
        LD   A,(AiSide)       ; 黒石or 白石
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



; ---------------------------------
; PlayerMove (Phase2)
; 入力→Parse→合法判定→ApplyMove(反転+着手)
; ---------------------------------
PlayerMove:
PM_Loop:
        LD   DE,MSG_PROMPT
        CALL PrintString

        LD   HL,RXBUF
        CALL GETLINE

        ; ParseMove: 成功 A=1, C=offset(0..15)
        CALL ParseMove
        OR   A
        JR   Z,PM_BadInput

        ; offset -> row/col (B=row, C=col)
        CALL OffsetToRowCol

        ; player=WHITE/BLACK
        LD   A,(HumSide)
        LD   D,A
        PUSH BC
        PUSH DE

        CALL IsLegalMove
        POP  DE
        POP  BC

        OR   A
        JR   Z,PM_Illegal

        ; 反転+着手
        LD   A,(HumSide)
        LD   D,A

        CALL ApplyMove

        OR   A
        JR   Z,PM_Illegal2      ; 念のため（普通ここには来ない）

        LD   DE,MSG_LEGAL
        CALL PrintString
        RET

PM_BadInput:
        LD   DE,MSG_BADFMT
        CALL PrintString
        JR   PM_Loop

PM_Illegal:
        LD   DE,MSG_ILLEGAL
        CALL PrintString
        JR   PM_Loop

PM_Illegal2:
        LD   DE,MSG_ILLEGAL2
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
        LD   B,BOARD_BYTES

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


; ---------------------------------
; OffsetToRowCol
; C = offset (0..15)
; 戻り:
;   B = row (0..3)
;   C = col (0..3)
; 破壊: AF
; ---------------------------------
OffsetToRowCol:
        LD   A,C        ; A = offset

        LD   B,A        ; 一旦Bにコピー
        SRL  B
        SRL  B          ; B = offset / 4 → row

        AND  3          ; A = offset % 4
        LD   C,A        ; C = col

        RET


; ---------------------------------
; RowColToOffset
; B = row (0..3)
; C = col (0..3)
; 戻り:
;   C = offset (0..15)
; 破壊: AF
; ---------------------------------
RowColToOffset:
        LD   A,B
        SLA  A
        SLA  A          ; A = row*4
        ADD  A,C        ; + col
        LD   C,A
        RET

; ---------------------------------
; InRange
; B = row
; C = col
; 戻り:
;   A = 1  → 盤内
;   A = 0  → 盤外
; 破壊: AF
; ---------------------------------
InRange:

        ; row < 0 ?
        BIT  7,B
        JR   NZ,IR_Fail

        ; row >= 4 ?
        LD   A,B
        CP   4
        JR   NC,IR_Fail

        ; col < 0 ?
        BIT  7,C
        JR   NZ,IR_Fail

        ; col >= 4 ?
        LD   A,C
        CP   4
        JR   NC,IR_Fail

        LD   A,1          ; OK
        RET

IR_Fail:
        XOR  A            ; A=0
        RET


; ---------------------------------
; TryDirCount
; 指定方向(dr,dc)に「相手石が1個以上続き、その先に自分石」があるなら
; 挟める相手石の枚数(count)を返す
;
; 参照（入力はメモリ）:
;   WORK_PLAYER, WORK_ROW, WORK_COL
;   TD_DR, TD_DC
;
; 戻り:
;   A = 0   → この方向は非合法（挟めない）
;   A = n   → 合法（n枚ひっくり返せる / n>=1）
;
; 破壊: AF,BC,DE,HL
; ---------------------------------
TryDirCount:
        ; opponent = 3 - player
        LD   A,(WORK_PLAYER)
        LD   E,A
        LD   A,3
        SUB  E
        LD   (TD_OPP),A

        ; count = 0
        XOR  A
        LD   (TD_COUNT),A

        ; r = row + dr
        LD   A,(WORK_ROW)
        LD   E,A
        LD   A,(TD_DR)
        ADD  A,E
        LD   (TD_R),A

        ; c = col + dc
        LD   A,(WORK_COL)
        LD   E,A
        LD   A,(TD_DC)
        ADD  A,E
        LD   (TD_C),A

TDC_Loop:
        ; InRange(r,c)?
        LD   A,(TD_R)
        LD   B,A

;        ADD  A, '0'
;        CALL PutChar
        ; デバッグ用：探索しているマスを表示（例: "23"）
        ; （不要ならこの3行は消すかコメントアウト）

        LD   A,(TD_C)
        LD   C,A

;        ADD  A, '0'
;        CALL PutChar
;        CALL NEWLINE

        CALL InRange
        OR   A
        JR   Z,TDC_Fail

        ; offset = r*4 + c  （C=offset）
        CALL RowColToOffset

        ; stone = BOARD[offset]
        LD   HL,BOARD
        LD   E,C
        LD   D,0
        ADD  HL,DE
        LD   A,(HL)             ; A=stone(0/1/2)
        LD   E,A                ; stone退避

        ; if stone == opponent -> count++, advance
        LD   A,(TD_OPP)
        CP   E
        JR   Z,TDC_GotOpp

        ; else if stone == player -> return count (count>=1 なら合法)
        LD   A,(WORK_PLAYER)
        CP   E
        JR   Z,TDC_ReturnCount

        ; else EMPTY -> fail
        JR   TDC_Fail

TDC_GotOpp:
        ; count++
        LD   A,(TD_COUNT)
        INC  A
        LD   (TD_COUNT),A

        ; r += dr
        LD   A,(TD_R)
        LD   E,A
        LD   A,(TD_DR)
        ADD  A,E
        LD   (TD_R),A

        ; c += dc
        LD   A,(TD_C)
        LD   E,A
        LD   A,(TD_DC)
        ADD  A,E
        LD   (TD_C),A

        JR   TDC_Loop

TDC_ReturnCount:
        ; count==0 なら相手石を挟んでない → 非合法
        ; A=count を返す（A==0を含む）

;        PUSH AF
;        PUSH DE
;        LD   DE,CNT_MSG
;        CALL PrintString
;        LD   A,(TD_COUNT)
;        ADD  A,'0'
;        CALL PutChar
;        CALL NEWLINE
;        POP  DE
;        POP  AF

        LD   A,(TD_COUNT)
        RET

TDC_Fail:
        XOR  A
        RET

; ---------------------------------
; IsLegalMove
; 8方向をチェックして合法手か判定
;
; 入力:
;   D = player (1/2)
;   B = row (0..3)
;   C = col (0..3)
;
; 戻り:
;   A = 1  → 合法
;   A = 0  → 非合法
;
; 破壊: AF,BC,DE,HL,IX,IY
; ---------------------------------

IsLegalMove:
        ; 不変値を退避
        LD   A,D
        LD   (WORK_PLAYER),A
        LD   A,B
        LD   (WORK_ROW),A
        LD   A,C
        LD   (WORK_COL),A

        ; --- 開始マスが空かチェック（空でなければ非合法） ---
        CALL RowColToOffset      ; C=offset

        LD   HL,BOARD
        LD   E,C
        LD   D,0
        ADD  HL,DE
        LD   A,(HL)
        OR   A
        JR   NZ,ILM_NotLegal

        ; --- 方向ループ ---
        LD   B,DIR_CNT           ; B=8 (カウンタ専用)
        LD   IX,DIR_DR
        LD   IY,DIR_DC

ILM_Loop:
        LD   A,(IX+0)
        LD   (TD_DR),A
        INC  IX

        LD   A,(IY+0)
        LD   (TD_DC),A
        INC  IY

        PUSH BC

        CALL TryDirCount

        POP BC
        OR   A
        JR   NZ,ILM_Legal

        DJNZ ILM_Loop

ILM_NotLegal:
        XOR  A
        RET

ILM_Legal:
        LD   A,1
        RET


; ---------------------------------
; FlipDirN
; (row,col) から (dr,dc) 方向へ n 枚ぶん、
; 相手石を player の石に “反転” して書き換える
;
; 前提:
;   TryDirCount が返した n (>=1) が入力されるので、
;   盤外チェックは基本不要（念のため InRange を入れてもOK）
;
; 入力（メモリ参照）:
;   WORK_PLAYER   = player(1/2)
;   WORK_ROW      = 開始row
;   WORK_COL      = 開始col
;   TD_DR         = dr (-1/0/1)
;   TD_DC         = dc (-1/0/1)
; 入力（レジスタ）:
;   A = n (1..)
;
; 戻り:
;   なし
;
; 破壊: AF,BC,DE,HL
; ---------------------------------
FlipDirN:
        ; n を保存
        LD   (TD_N),A
        OR   A
        RET  Z                 ; 念のため n=0 なら何もしない

        ; r = row + dr
        LD   A,(WORK_ROW)
        LD   E,A
        LD   A,(TD_DR)
        ADD  A,E
        LD   (TD_R),A

        ; c = col + dc
        LD   A,(WORK_COL)
        LD   E,A
        LD   A,(TD_DC)
        ADD  A,E
        LD   (TD_C),A

FD_Loop:
        ; if TD_N == 0 -> done
        LD   A,(TD_N)
        OR   A
        RET  Z

        ; --- (r,c) -> offset ---
        LD   A,(TD_R)
        LD   B,A
        LD   A,(TD_C)
        LD   C,A

        ; （安全のため入れるなら）
        ; CALL InRange
        ; OR   A
        ; RET  Z

        CALL RowColToOffset     ; C=offset

        ; BOARD[offset] = player
        LD   HL,BOARD
        LD   E,C
        LD   D,0
        ADD  HL,DE
        LD   A,(WORK_PLAYER)
        LD   (HL),A

        ; n--
        LD   A,(TD_N)
        DEC  A
        LD   (TD_N),A

        ; r += dr
        LD   A,(TD_R)
        LD   E,A
        LD   A,(TD_DR)
        ADD  A,E
        LD   (TD_R),A

        ; c += dc
        LD   A,(TD_C)
        LD   E,A
        LD   A,(TD_DC)
        ADD  A,E
        LD   (TD_C),A

        JR   FD_Loop

; END of FlipDirN


; ---------------------------------
; ApplyMove
; 8方向を走査し、合法方向だけ反転して盤面更新
; 最後に着手点(row,col)へ player を置く
;
; 入力:
;   D = player (1=BLACK / 2=WHITE)
;   B = row (0..3)
;   C = col (0..3)
;
; 戻り:
;   A = 1  更新成功（少なくとも1方向で反転した）
;   A = 0  更新失敗（合法手ではない）
;
; 破壊: AF,BC,DE,HL,IX,IY
; ---------------------------------
ApplyMove:
        ; WORK_* に保存（TryDirCount/FlipDirN が参照）
        LD   A,D
        LD   (WORK_PLAYER),A
        LD   A,B
        LD   (WORK_ROW),A
        LD   A,C
        LD   (WORK_COL),A

        ; まず合法手かチェック（反転方向が1つ以上あるか）
        ; （ここは IsLegalMove を呼んでもいいが、二度手間なので
        ;  Apply内で “反転したか” を集計して判定する）
        XOR  A
        LD   (AM_DIDFLIP),A     ; 0=まだ反転なし

        ; 方向ループ準備
        LD   B,DIR_CNT          ; B=8（カウンタ専用）
        LD   IX,DIR_DR
        LD   IY,DIR_DC

AM_Loop:
        ; dr/dc を TD_* にセット
        LD   A,(IX+0)
        LD   (TD_DR),A
        INC  IX

        LD   A,(IY+0)
        LD   (TD_DC),A
        INC  IY

        PUSH BC                 ; DJNZ用Bを保護

        ; この方向で何枚反転できる？
        CALL TryDirCount         ; A = n (0..)
        OR   A
        JR   Z,AM_NoFlip

        ; n枚反転
        CALL FlipDirN

        ; 反転したフラグ = 1
        LD   A,1
        LD   (AM_DIDFLIP),A

AM_NoFlip:
        POP  BC
        DJNZ AM_Loop

        ; 反転が一度も無いなら違法手 → 失敗
        LD   A,(AM_DIDFLIP)
        OR   A
        JR   Z,AM_Fail

        ; 反転があったので、最後に着手点へ player を置く
        LD   A,(WORK_ROW)
        LD   B, A
        LD   A, (WORK_COL)
        LD   C, A
        CALL RowColToOffset     ; C=offset

        ; PlaceAtOffset: 入力 A=stone, C=offset, 戻り A=1/0
        LD   A,(WORK_PLAYER)    ; stone
        CALL PlaceAtOffset

        LD   A,1
        RET

AM_Fail:
        XOR  A
        RET


; END of ApplyMove


; ==============================
; DecideFirstTurn
;  AIが先手/後手を決める（起動時に1回）
;  - Rレジスタのbit0で決定（疑似ランダム）
;  - AiSide / HumSide / TurnSide を設定
;  - メッセージ表示
;
;  使う外部:
;    PrintString : HLの0終端文字列を送信
;    PutChar     : Aの1文字を送信
;  破壊: AF, HL
; ==============================

DecideFirstTurn:
        ; "AI decides who goes first..." を表示
        LD   DE, MsgAiDecides
        CALL PrintString

        ; 疑似ランダム: Rレジスタのbit0を見る
        LD   A, R
        AND  1
        JR   Z, AiGoesFirst

; ---- Human goes first ----
HumGoesFirst:
        LD   A, BLACK
        LD   (HumSide), A
        LD   A, WHITE
        LD   (AiSide), A

        LD   A, BLACK
        LD   (TurnSide), A

        LD   DE, MsgHumanFirst
        CALL PrintString
        RET

; ---- AI goes first ----
AiGoesFirst:
        LD   A, BLACK
        LD   (AiSide), A
        LD   A, WHITE
        LD   (HumSide), A

        LD   A, BLACK
        LD   (TurnSide), A

        LD   DE, MsgAiFirst
        CALL PrintString
        RET

; END of DecideFirstTurn
;  ==============================


; ---------------------------------
; DoTurn
;   TurnSideに従ってAIかプレイヤが1手進める
;   合法手がなければPASS（手を打たない）
;   連続PASSが2回なら A=1 を返して終局通知
;   終了時に TurnSide を反転（BLACK<->WHITE）
; 戻り:
;   A = 0 継続 / 1 終局（双方PASS）
; 破壊: AF,BC,DE
; ---------------------------------
DoTurn:
        ; ---- この手番の side を D に入れる ----
        LD   A,(TurnSide)
        LD   D,A

        ; ---- 合法手があるか？ ----
        CALL HasAnyLegalMove
        OR   A
        JR   NZ,DoTurn_CanMove

        ; ===== PASS =====
        LD   A,(TurnSide)
        LD   B,A
        LD   A,(HumSide)
        CP   B
        JR   Z,Hum_PASS_Display

Ai_PASS_Display:
        ; パスメッセージ表示
        LD   DE,MSG_AI_PASS
        CALL PrintString
        JR   DoTurn_PassCommon

Hum_PASS_Display:
        LD   DE,MSG_PL_PASS
        CALL PrintString

DoTurn_PassCommon:
        LD   A,(PassStreak)
        INC  A
        LD   (PassStreak),A
        CP   2
        JR   NC,DoTurn_EndByPass   ; 2連続PASS → 終局

        ; パスでも手番は交代
        JR   DoTurn_SwitchReturn0

DoTurn_CanMove:
        ; 手を打てる → PASS連続をリセット
        XOR  A
        LD   (PassStreak),A

        ; ---- AI側か判定して打つ ----
        LD   A,(TurnSide)
        LD   B,A
        LD   A,(AiSide)
        CP   B
        JR   Z,DoTurn_AI

DoTurn_HUM:
        CALL PlayerMove
        JR   DoTurn_SwitchReturn0

DoTurn_AI:
        CALL AIset
        JR   DoTurn_SwitchReturn0

DoTurn_EndByPass:
        ; 終局通知：A=1で戻る（TurnSideは切替えず戻すのが自然）
        LD   A,1
        RET

DoTurn_SwitchReturn0:
        ; TurnSide を反転
        LD   A,(TurnSide)
        CP   BLACK
        JR   Z,SetWhite

SetBlack:
        LD   A,BLACK
        LD   (TurnSide),A
        XOR  A              ; A=0 継続
        RET

SetWhite:
        LD   A,WHITE
        LD   (TurnSide),A
        XOR  A              ; A=0 継続
        RET

; END of DoTurn
;==============================

; ---------------------------------
; AIset
; (AiSide) (黒/白)の合法手を探して1手打つ
; 見つからなければパス
; ---------------------------------

AIset:
        LD   A,(AiSide)
        LD   D,A            ; AIは黒/白

        LD   B,0            ; row = 0

AI_RowLoop:
        LD   C,0            ; col = 0

AI_ColLoop:
        PUSH BC             ; row,col保存
        PUSH DE

        CALL IsLegalMove    ; A=1なら合法

        POP  DE
        POP  BC

        OR   A
        JR   Z,AI_NextCol

        ; --- 合法手見つかった ---
        PUSH BC
        PUSH DE

        CALL ApplyMove      ; 実際に置いて反転

        POP  DE
        POP  BC

        RET                 ; 1手で終了

AI_NextCol:
        INC  C
        LD   A,C
        CP   4
        JR   C,AI_ColLoop

        INC  B
        LD   A,B
        CP   4
        JR   C,AI_RowLoop

        ; 合法手なし → パス
        RET
; END of AIset
;==============================


; ---------------------------------
; HasAnyLegalMove
; 指定プレイヤーに合法手が1つでもあるか？
;
; 入力:
;   D = player (BLACK=1 / WHITE=2)
; 戻り:
;   A = 1 (合法手あり) / 0 (なし)
; 破壊:
;   AF,BC,DE (IsLegalMove側の破壊は吸収する想定)
; ---------------------------------
HasAnyLegalMove:
        LD   B,0              ; row=0
HAM_Row:
        LD   C,0              ; col=0
HAM_Col:
        PUSH BC
        PUSH DE
        CALL IsLegalMove      ; A=1なら合法
        POP  DE
        POP  BC
        OR   A
        JR   NZ,HAM_Found

        INC  C
        LD   A,C
        CP   4
        JR   C,HAM_Col

        INC  B
        LD   A,B
        CP   4
        JR   C,HAM_Row

        XOR  A                ; A=0
        RET

HAM_Found:
        LD   A,1
        RET

; END of HasAnyLegalMove
; =============================

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