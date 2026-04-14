        ORG 8000H

; ==== 定数定義 ====

SIOA_DAT    EQU 18H       ; SIOA データポート
SIOA_CTL    EQU 19H       ; SIOA コマンド/ステータス

BOARD_SIZE  EQU 4
BOARD_BYTES EQU BOARD_SIZE*BOARD_SIZE

EMPTY       EQU '.'
STONE_CPU   EQU 'X'
STONE_HUM   EQU 'O'

; ==== 変数領域 ====

BOARD:      DEFS BOARD_BYTES   ; 16バイト分の盤面
TMPROW:     DEFB 0             ; 行インデックス (0-3)
TMPCOL:     DEFB 0             ; 列インデックス (0-3)
CHARBUF:    DEFB 0             ; 列文字 (A-D)
CHARBUF2:   DEFB 0             ; 行文字 (1-4)

; ==== 文字列 ====

MSG_TITLE:  DEFM "4x4 Othello (Z80 vs YOU)",0
MSG_NEWLINE:DEFM 13,10,0       ; CR LF
MSG_TURNCPU:DEFM "Z80 turn...",0
MSG_TURNYOU:DEFM "Your move (A1-D4, Q=quit): ",0
MSG_LEGERR: DEFM " ? Try again",13,10,0
MSG_QUIT:   DEFM 13,10,"Bye!",13,10,0

COL_HEADER: DEFM "  A B C D",0

; ==== メインエントリ ====

        LD   SP,0FFF0H      ; 

START:
        DI
        ; SIO 初期化はモニタ任せと仮定
        CALL InitBoard

MainLoop:
        CALL ClearScreen
        CALL PrintTitleAndBoard

        ; ----- Z80 の手 -----
        CALL PrintNewline
        LD  DE,MSG_TURNCPU
        CALL PrintString

        CALL CpuMoveSimple      ; 左上から空マスを探して打つ
        CALL PrintNewline

        CALL ClearScreen
        CALL PrintTitleAndBoard

        ; ----- 人間の手 -----
GetHuman:
        LD  DE,MSG_TURNYOU
        CALL PrintString
        CALL HumanMove
        JR  NZ,GameQuit         ; Z フラグでなく NZ = Q 入力 → 終了

        JR  MainLoop

GameQuit:
        LD  DE,MSG_QUIT
        CALL PrintString
        JP  $

; ==== 盤面初期化 ====

InitBoard:
        LD  HL,BOARD
        LD  B,BOARD_BYTES
InitLoop:
        LD  (HL),EMPTY
        INC HL
        DJNZ InitLoop
        RET

; ==== 画面系 ====

ClearScreen:
        ; とりあえず 30 行くらい改行して消した風にする
        LD  B,30
CS_Loop:
        CALL PrintNewline
        DJNZ CS_Loop
        RET

PrintNewline:
        LD  DE,MSG_NEWLINE
        JP  PrintString

PrintTitleAndBoard:
        LD  DE,MSG_TITLE
        CALL PrintString
        CALL PrintNewline
        CALL PrintNewline

        ; 列ヘッダ "  A B C D"
        LD  DE,COL_HEADER
        CALL PrintString
        CALL PrintNewline

        ; 各行を描画
        LD  B,BOARD_SIZE        ; B = 行カウンタ (4)
        LD  A,1                 ; A = 行番号表示 (1-4)

        LD  HL,BOARD            ; HL = 盤面先頭
RowLoop:
        ; 行番号を表示 ("1 " など)
        PUSH AF
        CALL PrintRowNumber     ; A の値を '1','2','3','4' に変換して表示
        POP  AF

        ; スペース 1 つ
        LD  A,' '
        CALL PutChar

        ; 列を 4 つ描画
        LD  C,BOARD_SIZE        ; C = 残り列数
ColLoop:
        LD  A,(HL)
        CALL PutChar
        ; 石の後にスペース
        LD  A,' '
        CALL PutChar

        INC HL
        DEC C
        JP  NZ,ColLoop

        CALL PrintNewline

        INC A            ; 行番号インクリメント
        DJNZ RowLoop
        CALL PrintNewline

        ; 下に簡易の凡例
        LD  DE,MSG_NEWLINE
        CALL PrintString
        LD  DE,LegendStr
        CALL PrintString
        CALL PrintNewline
        RET

LegendStr:
        DEFM "Z80 = X, YOU = O",0

PrintRowNumber:
        ; A = 1〜4 → '1'〜'4' を表示
        ADD A,'0'
        CALL PutChar
        RET

; ==== CPU の簡単な手：左上から空きを探すだけ ====

CpuMoveSimple:
        LD  HL,BOARD
        LD  B,BOARD_BYTES
CpuSearchLoop:
        LD  A,(HL)
        CP  EMPTY
        JR  NZ,CpuNextCell

        ; 空きなら X を置いて終わり
        LD  (HL),STONE_CPU
        RET

CpuNextCell:
        INC HL
        DJNZ CpuSearchLoop
        RET             ; 置く場所がなければ何もしない（実質パス）

; ==== 人間の手入力 ====

; 戻り値:
;   Zフラグ=1 → 正常に一手置いた
;   Zフラグ=0 (NZ) → 'Q' or 'q' が入力されたので終了要求

HumanMove:
        ; 1文字目（列 A-D or Q）
        CALL GetNonCRChar       ; A=入力文字

        ; Q/q なら終了要求
        CP  'Q'
        JR  Z,HumanQuit
        CP  'q'
        JR  Z,HumanQuit

        ; 列文字を保存 (A-D / a-d)
        LD  (CHARBUF),A

        ; 2文字目（行 1-4）
        CALL GetNonCRChar       ; A=入力文字
        LD  (CHARBUF2),A

        ; --- 行文字チェック & 0〜3に変換 ---
        LD  A,(CHARBUF2)        ; A = '1'〜'4'
        CP  '1'
        JR  C,HumanInputError
        CP  '4'+1
        JR  NC,HumanInputError

        ; '1' → 0, '2' → 1, ...
        LD  A,(CHARBUF2)
        SUB '1'
        CP  BOARD_SIZE
        JR  NC,HumanInputError
        LD  (TMPROW),A          ; TMPROW = 0〜3

        ; --- 列文字チェック & 0〜3に変換 ---
        LD  A,(CHARBUF)         ; A = 'A'〜'D' or 'a'〜'd'
        CP  'a'
        JR  C,ColUpper
        SUB 'a'
        JR  ColDone
ColUpper:
        SUB 'A'
ColDone:
        CP  BOARD_SIZE
        JR  NC,HumanInputError
        LD  (TMPCOL),A          ; TMPCOL = 0〜3

        ; ---- 盤面インデックス計算 ----
        ; index = row*4 + col
        LD  A,(TMPROW)
        LD  H,0
        LD  L,A           ; HL = row
        ADD HL,HL         ; HL = row *2
        ADD HL,HL         ; HL = row *4
        LD  A,(TMPCOL)
        LD  E,A
        LD  D,0
        ADD HL,DE         ; HL = row*4 + col

        ; HL = BOARD + index
        LD  DE,BOARD
        ADD HL,DE

        ; そこが空きかどうか
        LD  A,(HL)
        CP  EMPTY
        JR  NZ,HumanInputError

        ; O を置いて終了（Z=1）
        LD  (HL),STONE_HUM
        XOR A             ; A=0 (Z=1)
        RET

HumanQuit:
        LD  A,1
        OR  A             ; A != 0 → Z=0 (NZ)
        RET

HumanInputError:
        LD  DE,MSG_LEGERR
        CALL PrintString
        ; 入力を読み直す
        JR  HumanMove
; ==== I/O 基本ルーチン ====

; A に入っている文字を SIOA に送信
PutChar:
        PUSH AF
WaitTx:
        IN   A,(SIOA_CTL)
        BIT  2,A          ; RR0 bit2 = Tx buffer empty
        JR   Z,WaitTx
        POP  AF
        OUT  (SIOA_DAT),A
        RET

; 0 終端文字列を出力 (DE が指す)
PrintString:
        PUSH AF
        PUSH DE
PS_Loop:
        LD  A,(DE)
        OR  A
        JR  Z,PS_Done
        CALL PutChar
        INC DE
        JR  PS_Loop
PS_Done:
        POP  DE
        POP  AF
        RET

; CRやLFをスキップしながら1文字読む
; 戻り: A=文字
GetNonCRChar:
        CALL GetChar
        CP  13            ; CR
        JR  Z,GetNonCRChar
        CP  10            ; LF
        JR  Z,GetNonCRChar
        RET

; 1文字読み取り：A=文字
GetChar:
WaitRx:
        IN   A,(SIOA_CTL)
        BIT  0,A          ; RR0 bit0 = Rx char available
        JR   Z,WaitRx
        IN   A,(SIOA_DAT)
        RET

        END  START
