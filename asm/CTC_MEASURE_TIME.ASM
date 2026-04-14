; =========================================================
; MEASURE_TIME.ASM
; Super AKI-80 (Z80)  CTC CH0 タイマー計測デモ (ポーリング版)
; ---------------------------------------------------------
; Target : Z80  Super AKI-80  @10MHz
; Serial : SIOA  DAT=18h  CTL=19h  (SIO init by monitor)
;
; 計測の仕組み:
;   CTC CH0 をタイマーモード(プリスケーラ×256, TC=0(=256))で動作させる。
;   割り込みは使わない。被計測コードから PollCTC を定期的に呼ぶことで
;   オーバーフローを検出し、カウンタを更新する。
;
;   1 tick   = 1 / 10MHz = 0.1μs
;   1 OVF    = 256 × 256 ticks = 6553.6μs ≈ 6554μs  ← 最小計測単位
;   COUNT_MS = OVFカウント (1カウント ≈ 6554μs)
;   最大計測  = COUNT_MS 16bit → 65535 × 6554μs ≈ 429秒
;
;   精度上の注意:
;     PollCTC の呼び出し間隔が 6554μs を超えると、その区間の
;     オーバーフローを取りこぼす。被計測コードでは 6554μs 以内に
;     必ず PollCTC を呼ぶこと。
;     ループ計測の場合は、内側ループが 6554μs 以下になる粒度で
;     PollCTC を呼び出すこと。
;
; 使い方 (他のプログラムへの組み込み):
;   1. StartTimer を呼んで計測開始
;   2. 被計測コードの中で 6554μs 以内に 1回 CALL PollCTC を挿入
;   3. StopTimer を呼んで計測終了
;   4. COUNT_MS (DEFW) にOVFカウントが入る (×6554μs で実時間換算)
;
; デモ内容:
;   StartTimer → ダミーループ(256×8×32) → StopTimer → OVFカウント表示
;   'r' キーで再計測 / 'q' キーで終了
;   期待値: ≒ 32 counts (≈207ms / 6554μs、PollCTC オーバーヘッド込み)
; =========================================================

        ORG  8000H
        JP   START


; =========================================================
; I/O ポート
; =========================================================
SIOA_DAT        EQU 18H
SIOA_CTL        EQU 19H

; =========================================================
; CTC CH0  (タイマー計測)
; =========================================================
CTC_CH0         EQU 12H

; コントロールワード (割り込みなし):
;   D7=0 INT無効  D6=0 タイマーモード  D5=1 プリスケーラ×256
;   D4=0          D3=1 TC続く          D2=0 D1=0 D0=1
;   = 0010_1001B = 29H
CTC_CTRL        EQU 00101001B

; 時定数 0(=256) → 1オーバーフロー = 256 × 256 / 10MHz = 6553.6μs ≈ 6554μs
CTC_TC          EQU 0       ; CTC は 0 を 256 としてカウントダウンする
CTC_PERIOD      EQU 256D    ; Ticks計算用の実周期 (EQUが0のため別定義)

; 停止用: チャネルリセット = 0000_0011B = 03H
CTC_STOP        EQU 00000011B

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
        DEFM "MEASURE_TIME: CTC polling 200us/OVF max65s",CR,LF,0

MSG_MSTART:
        DEFM "Measuring...",CR,LF,0

MSG_OVF:
        DEFM "OVF:   ",0

MSG_OVF_UNIT:
        DEFM " (raw overflows)",CR,LF,0

MSG_REMAIN:
        DEFM "REMAIN:",0

MSG_REMAIN_UNIT:
        DEFM " (CTC counter at stop)",CR,LF,0

MSG_TICKS:
        DEFM "Ticks: ",0

MSG_TICKS_UNIT:
        DEFM " (x1.6us)",CR,LF,0

MSG_MS:
        DEFM "Time:  ",0

MSG_MS_UNIT:
        DEFM " x6554us",CR,LF,0

MSG_RETRYQ:
        DEFM "r:Retry  q:Quit > ",0

MSG_BYE:
        DEFM CR,LF,"Bye.",CR,LF,0


; =========================================================
; 変数 / 作業領域
; =========================================================

; ---- CTC 計測変数 ----
CTC_PREV:       DEFB 0FFH       ; 前回 PollCTC 時の CTC カウンタ値 (初期値=FFH: 誤OVF防止)
CTC_REMAIN:     DEFB 0          ; PollCTC 最終読み取り値
OVF5_COUNT:     DEFB 1          ; 1 OVF = 1カウント (1 OVF ≈ 6554μs)
CTC_OVF:        DEFW 0          ; 総オーバーフロー回数 (診断用・16bit)
COUNT_MS:       DEFW 0          ; OVFカウント (1カウント ≈ 6554μs)

; =========================================================
; メインエントリ
; =========================================================
START:
        LD   SP,0FFF0H

        LD   DE,MSG_BANNER
        CALL PrintString

        DI                      ; ポーリング計測中は割り込み禁止

MAIN_LOOP:
        ; カウンタリセット & タイマースタート
        LD   HL,0000H
        LD   (COUNT_MS),HL
        LD   (CTC_OVF),HL
        LD   A,1
        LD   (OVF5_COUNT),A
        CALL StartTimer

        LD   DE,MSG_MSTART
        CALL PrintString

        ; ---- 計測対象: ここに測りたい処理を書く ----
        ; 注意: 6554μs 以内に CALL PollCTC が必要
        CALL DummyWork
        ; ---- 計測対象ここまで ----

        CALL StopTimer

        ; 結果表示: OVF 回数 (診断用)
        LD   DE,MSG_OVF
        CALL PrintString
        LD   HL,(CTC_OVF)
        CALL PrintDecWord
        LD   DE,MSG_OVF_UNIT
        CALL PrintString

        ; 結果表示: REMAIN (診断用)
        LD   DE,MSG_REMAIN
        CALL PrintString
        LD   A,(CTC_REMAIN)
        LD   H,0
        LD   L,A
        CALL PrintDecWord
        LD   DE,MSG_REMAIN_UNIT
        CALL PrintString

        ; 結果表示: Ticks = OVF*256 + (256-REMAIN)
        LD   DE,MSG_TICKS
        CALL PrintString
        ; HL = OVF * CTC_PERIOD (=256)
        LD   HL,0
        LD   BC,(CTC_OVF)    ; BC = OVF 回数
TK_Mul:
        LD   A,B
        OR   C
        JR   Z,TK_Done
        LD   DE,CTC_PERIOD   ; DE = 256 (CTC_TC=0は実周期でないため別定数使用)
        ADD  HL,DE           ; HL += 256
        DEC  BC
        JR   TK_Mul
TK_Done:
        ; HL += 256 - CTC_REMAIN (NEG: A = 0-REMAIN → 8bit折り返しで 256-REMAIN)
        LD   A,(CTC_REMAIN)
        NEG                  ; A = 256 - REMAIN
        LD   C,A
        LD   B,0
        ADD  HL,BC           ; HL = OVF*256 + (256-REMAIN)
        CALL PrintDecWord
        LD   DE,MSG_TICKS_UNIT
        CALL PrintString

        ; 結果表示: OVFカウント (1カウント ≈ 6554μs)
        LD   DE,MSG_MS
        CALL PrintString
        LD   HL,(COUNT_MS)
        CALL PrintDecWord
        LD   DE,MSG_MS_UNIT
        CALL PrintString

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
;   構成: 25600回ループ (PollCTC + NOP×4 + DEC DE + LD A,D + OR E + JR NZ)
;     1ループ ≈ 181T ≈ 18μs  (PollCTC ≈ 139T + ループ本体 ≈ 42T)
;     25600 × 181T ≈ 4,634,000T ≈ 463ms
;     期待値: ≒ 71 counts (≈463ms / 6554μs)
;
;   PollCTC は毎ループ呼び出し (≈18μs < 6554μs) → オーバーフロー取りこぼしなし
;
;   実際の被計測コード (AI探索など) では PollCTC を適切な場所に
;   挿入すること。ループ1回が 6554μs 以下になる粒度で呼び出す。
;
; Destroys: AF, B, C, D
; =========================================================


DummyWork:
        PUSH AF
        PUSH BC
        PUSH DE

        LD   DE, 25600D
DW_Wait:
        CALL PollCTC
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
; CTC 計測ルーティン
; =========================================================

; ---------------------------------------------------------
; PollCTC
;   CTC CH0 のカウンタ値を読み、オーバーフローを検出する。
;   被計測コードから 6554μs 以内に 1回呼び出すこと。
;
;   オーバーフロー検出:
;     CTC はカウントダウン動作 (TC=125 → 0 → リロード125 →...)
;     現在値 > 前回値 → カウンタがリロードされた = 1回オーバーフロー
;
;   5回オーバーフローで COUNT_MS をインクリメント (5×200μs = 1ms)
;
; Destroys: AF, B, HL
; ---------------------------------------------------------
PollCTC:
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL

        IN   A,(CTC_CH0)    ; 現在値を A に
        LD   B,A            ; B に保存
        LD   A,(CTC_PREV)   ; A = 前回値
        
        ; CTCはダウンカウンタなので 通常は前回(A) > 現在(B)
        ; A < B ならば、0を跨いでリロード(125へ)された証拠
        CP   B
        JR   NC,PollCTC_End ; A >= B ならまだオーバーフローしていない

        ; --- オーバーフロー発生時の処理 ---
        LD   HL,(CTC_OVF)
        INC  HL
        LD   (CTC_OVF),HL
        
        LD   A,(OVF5_COUNT)
        DEC  A
        JR   NZ,PC_NoMs
        LD   A,1
        LD   HL,(COUNT_MS)
        INC  HL
        LD   (COUNT_MS),HL
PC_NoMs:
        LD   (OVF5_COUNT),A

PollCTC_End:
        LD   A,B            ; 最新値を
        LD   (CTC_PREV),A   ; 次回の比較用に保存
        POP  HL
        POP  DE
        POP  BC
        POP  AF
        RET



; ---------------------------------------------------------
; StartTimer
;   CTC CH0 を起動し、ポーリング変数を初期化する。
;   割り込みは使用しない。
;   COUNT_MS / OVF5_COUNT は呼び出し前に初期化すること (MAIN_LOOP 参照)
; Destroys: AF
; ---------------------------------------------------------
StartTimer:
        PUSH AF
        LD   A,CTC_STOP     ; 03H: チャネルリセット
        OUT  (CTC_CH0),A
        LD   A,CTC_CTRL     ; 29H: プリスケーラ×256 / TC続く / INT無効
        OUT  (CTC_CH0),A
        LD   A,CTC_TC       ; 0 (=256): 時定数ロード → カウント開始
        OUT  (CTC_CH0),A
        IN   A,(CTC_CH0)    ; 起動直後の実測値を取得 (誤OVF防止)
        LD   (CTC_PREV),A   ; 実測値を初期PREVとして設定

        POP  AF

        RET


; ---------------------------------------------------------
; StopTimer
;   最後の PollCTC を呼んで CTC を停止する。
;   COUNT_MS に経過 ms が格納されている。
; Destroys: A
; ---------------------------------------------------------
StopTimer:
        PUSH AF

        CALL PollCTC            ; 最終ポーリング
        LD   A,CTC_STOP
        OUT  (CTC_CH0),A        ; CTC 停止

        POP  AF

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
