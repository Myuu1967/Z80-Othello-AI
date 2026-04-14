; =========================================================
; MEASURE_TIME.ASM
; Super AKI-80 (Z80)  CTC CH0 タイマー計測デモ (ポーリング版)
; ---------------------------------------------------------
; Target : Z80  Super AKI-80  @10MHz
; Serial : SIOA  DAT=18h  CTL=19h  (SIO init by monitor)
;
; 計測の仕組み:
;   ソフトウェアで時間を計測します
; =========================================================

        ORG  8000H
        JP   START


; =========================================================
; I/O ポート
; =========================================================
SIOA_DAT        EQU 18H
SIOA_CTL        EQU 19H

; =========================================================
; ASCII 制御文字
; =========================================================
CR              EQU 0DH
LF              EQU 0AH
BEL             EQU 07H


; =========================================================
; 文字列 (0終端)
; =========================================================
MSG_BANNER:
        DEFM "SOFT_MEASURE_TIME: software counter (1count=128T=12.8us)",CR,LF,0

MSG_MSTART:
        DEFM "Measuring...",CR,LF,0

MSG_RETRYQ:
        DEFM "r:Retry  q:Quit > ",0

MSG_BYE:
        DEFM CR,LF,"Bye.",CR,LF,0


; =========================================================
; 変数 / 作業領域
; =========================================================

SWTIME:     DEFW 0

; =========================================================
; メインエントリ
; =========================================================
START:
        LD   SP,0FFF0H

        LD   DE,MSG_BANNER
        CALL PrintString

        DI                      ; ポーリング計測中は割り込み禁止

MAIN_LOOP:
        ; カウンタリセット
        LD   HL,0
        LD   (SWTIME),HL

        ; ---- 計測対象: ここに測りたい処理を書く ----
        ; AI 等への組み込み: ループ先頭に CALL COUNTER を挿入
        CALL DummyWork
        ; ---- 計測対象ここまで ----

        LD   HL,(SWTIME)
        CALL PrintDecWord
        CALL Newline

        ; r / q 待ち
        LD   DE,MSG_RETRYQ
        CALL PrintString

RQ_WAIT:
        CALL GetChar
        CALL PutChar            ; エコー
        CALL Newline

        CP   'r'
        JP   Z,MAIN_LOOP
        CP   'R'
        JP   Z,MAIN_LOOP
        CP   'q'
        JR   Z,RQ_QUIT
        CP   'Q'
        JR   Z,RQ_QUIT

        LD   A,BEL
        CALL PutChar
        JR   RQ_WAIT

RQ_QUIT:
        LD   DE,MSG_BYE
        CALL PrintString
        RST  00H
        HALT


; =========================================================
; DummyWork
;   計測対象のダミー処理。実際のプログラムではここを差し替える。
;
;   構成: 25600回ループ (COUNTER + NOP×4 + DEC DE + LD A,D + OR E + JR NZ)
;     1ループ = COUNTER(86T) + NOP×4(16T) + DEC DE(6T) + LD A,D(4T)
;               + OR E(4T) + JR NZ(12T) = 128T = 12.8μs
;     25600 × 128T = 3,276,800T ≈ 328ms
;     期待値: SWTIME = 25600 counts (= ループ回数そのもの)
;
;   実際の被計測コード (AI探索など) では CALL COUNTER をループ先頭に挿入。
;   経過時間[μs] = SWTIME × (1ループのTstate数) × 0.1
;
; Destroys: AF, B, C, D
; =========================================================


DummyWork:
        PUSH AF
        PUSH BC
        PUSH DE

        LD   DE, 25600D
DW_Wait:
        CALL COUNTER
        NOP
        NOP
        NOP
        NOP
        DEC  DE
        LD   A, D
        OR   E
        JR   NZ, DW_Wait

        POP  DE
        POP  BC
        POP  AF

        RET

; =========================================================
; COUNTER
;
; Destroys: なし (全レジスタ保護)
; 1回の呼び出しコスト: CALL(17)+PUSH HL(11)+LD HL,(nn)(16)+INC HL(6)
;                      +LD (nn),HL(16)+POP HL(10)+RET(10) = 86T = 8.6μs
; =========================================================

COUNTER:
    PUSH HL
    LD   HL,(SWTIME)
    INC  HL
    LD   (SWTIME),HL
    POP  HL
    RET

; =========================================================
; シリアル I/O
; =========================================================

; ---------------------------------------------------------
; PutChar  A=1文字送信
; Destroys: AF
; ---------------------------------------------------------
PutChar:
        PUSH AF
PUT_Wait:
        IN   A,(SIOA_CTL)
        BIT  2,A                ; Tx Ready?
        JR   Z,PUT_Wait
        POP  AF
        OUT  (SIOA_DAT),A
        RET

; ---------------------------------------------------------
; GetChar  A=1文字受信 (ブロッキング)
; Destroys: AF
; ---------------------------------------------------------
GetChar:
GC_Wait:
        XOR  A
        OUT  (SIOA_CTL),A
        IN   A,(SIOA_CTL)
        BIT  0,A                ; Rx Ready?
        JR   Z,GC_Wait
        IN   A,(SIOA_DAT)
        RET

; ---------------------------------------------------------
; PrintString  DE=0終端文字列を送信
; Destroys: AF,DE
; ---------------------------------------------------------
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

; ---------------------------------------------------------
; Newline  CR+LF を送信
; Destroys: AF
; ---------------------------------------------------------
Newline:
        PUSH AF
        LD   A,CR
        CALL PutChar
        LD   A,LF
        CALL PutChar
        POP  AF
        RET


; =========================================================
; 数値表示
; =========================================================

; ---------------------------------------------------------
; PrintDecWord
;   HL を符号なし10進5桁で出力する (先頭ゼロあり)
; Input:  HL = 値 (0..65535)
; Destroys: AF,BC,DE,HL
; ---------------------------------------------------------
PrintDecWord:
        PUSH AF
        PUSH BC
        PUSH DE

        LD   DE,10000
        CALL PDW_Digit
        LD   DE,1000
        CALL PDW_Digit
        LD   DE,100
        CALL PDW_Digit
        LD   DE,10
        CALL PDW_Digit
        LD   DE,1
        CALL PDW_Digit

        POP  DE
        POP  BC
        POP  AF

        RET

;
;PDW_Digitの処理の補助ルーティン
;

PDW_Digit:
        LD   B,'0'-1
        AND  A                  ; carry クリア
PDW_Sub:
        INC  B
        SBC  HL,DE
        JR   NC,PDW_Sub
        ADD  HL,DE
        LD   A,B
        CALL PutChar
        RET


        END  START
