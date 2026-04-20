from machine import UART, Pin, SPI
import st7789
import utime
import romand as vector_font

# ─── SPI / TFT ───────────────────────────────────────
spi = SPI(0, baudrate=31250000, sck=Pin(18), mosi=Pin(19))
tft = st7789.ST7789(spi, 240, 320,
    reset=Pin(20, Pin.OUT),
    cs=Pin(17, Pin.OUT),
    dc=Pin(16, Pin.OUT),
    backlight=Pin(21, Pin.OUT),
    rotation=0)
tft.init()
tft.madctl(0x88)

# ─── UART0 (Z80 SIOA) ────────────────────────────────
uart = UART(0, baudrate=9600, tx=Pin(0), rx=Pin(1))

# ─── 計測ピン (Z80 PIOA D7 → GPIO15) ─────────────────
signal = Pin(15, Pin.IN, Pin.PULL_DOWN)
LED    = Pin(25, Pin.OUT)

# ─── 色定数 (madctl(0x88) 補色補正済み) ───────────────
#   定数名            実際の値           画面上の色
COL_BOARD   = st7789.MAGENTA   # → 緑   (盤面背景)
COL_GRID    = st7789.WHITE     # → 黒   (グリッド線)
COL_BG      = st7789.BLACK     # → 白   (画面背景)
COL_STONE_X = st7789.WHITE     # → 黒   (X石)
COL_STONE_O = st7789.BLACK     # → 白   (O石)
COL_TEXT    = st7789.WHITE     # → 黒   (スコア・時間)
COL_AI      = st7789.YELLOW    # → シアン (AI手強調)
COL_HUMAN   = st7789.CYAN      # → 赤   (人の手)

# ─── 盤面レイアウト定数 ───────────────────────────────
BOARD_X    = 30
BOARD_Y    = 30
CELL_SIZE  = 24.5
STONE_R    = 8
COLS_LABEL = ["A","B","C","D","E","F","G","H"]

# ─── ステータスエリア Y座標 (盤面下 232px～) ──────────
ST_Y_SCORE  = 236   # スコア     "X:04 O:04"
ST_Y_MOVE   = 254   # AI手       "AI moves to C8"
ST_Y_TIME   = 272   # 処理時間   "Time:687ms"
ST_Y_HUMAN  = 290   # 人の手     "You: D4"
ST_Y_RETRY  = 308   # リトライ   "●:Retry  ●:Quit"

# ─── 描画関数 ─────────────────────────────────────────
def draw_board():
    """盤面背景・グリッド・列行ラベルを描画する"""
    tft.fill(COL_BG)
    tft.fill_rect(BOARD_X, BOARD_Y, 196, 196, COL_BOARD)
    for i in range(9):
        x = int(i * CELL_SIZE + BOARD_X)
        y = int(i * CELL_SIZE + BOARD_Y)
        tft.vline(x, BOARD_Y,      196, COL_GRID)
        tft.hline(BOARD_X, y, 196, COL_GRID)
    for i in range(8):
        lx = int(i * CELL_SIZE + BOARD_X + 7)
        tft.draw(vector_font, COLS_LABEL[i], lx, 16, COL_TEXT, 0.7)
    for i in range(8):
        ly = int(i * CELL_SIZE + BOARD_Y + 7)
        tft.draw(vector_font, str(i + 1), 8, ly, COL_TEXT, 0.7)

def draw_stone(col, row, piece):
    """指定セルに石または空白を描画する"""
    cx = int(col * CELL_SIZE + BOARD_X + CELL_SIZE / 2)
    cy = int(row * CELL_SIZE + BOARD_Y + CELL_SIZE / 2)
    if piece == 'X':
        tft.fill_circle(cx, cy, STONE_R, COL_STONE_X)
    elif piece == 'O':
        tft.fill_circle(cx, cy, STONE_R, COL_STONE_O)
    else:
        tft.fill_circle(cx, cy, STONE_R, COL_BOARD)

def draw_status():
    """盤面下のステータスエリア5行を更新する"""
    tft.fill_rect(0, 228, 240, 92, COL_BG)
    if choose_mode:
        tft.draw(vector_font, ":1st(X)", 26,  ST_Y_SCORE, COL_AI,    0.7)
        tft.fill_circle(14,  ST_Y_SCORE, STONE_R, COL_AI)
        tft.draw(vector_font, ":2nd(O)", 142, ST_Y_SCORE, COL_HUMAN, 0.7)
        tft.fill_circle(130, ST_Y_SCORE, STONE_R, COL_HUMAN)
    elif score_text:
        tft.draw(vector_font, score_text,  8, ST_Y_SCORE, COL_TEXT,  0.7)
        tft.fill_circle(14, ST_Y_SCORE, STONE_R, COL_STONE_X)
        tft.fill_circle(72, ST_Y_SCORE, STONE_R, COL_STONE_O)
        tft.circle(72, ST_Y_SCORE, STONE_R, COL_STONE_X)

    if move_text:
        tft.draw(vector_font, move_text,   8, ST_Y_MOVE,  COL_AI,    0.7)
    if time_text:
        tft.draw(vector_font, time_text,   8, ST_Y_TIME,  COL_TEXT,  0.7)
    if human_text:
        tft.draw(vector_font, human_text, 26, ST_Y_HUMAN, COL_HUMAN, 0.7)
        stone = winner_stone if retry_mode else player_stone
        if stone == 'X':
            tft.fill_circle(14, ST_Y_HUMAN, STONE_R, COL_STONE_X)
        elif stone == 'O':
            tft.fill_circle(14, ST_Y_HUMAN, STONE_R, COL_STONE_O)
            tft.circle(14, ST_Y_HUMAN, STONE_R, COL_STONE_X)

    if retry_mode:
        tft.draw(vector_font, ":Retry",  26,  ST_Y_RETRY, COL_AI,    0.7)
        tft.fill_circle(14,  ST_Y_RETRY, STONE_R, COL_AI)
        tft.draw(vector_font, ":Quit",  142,  ST_Y_RETRY, COL_HUMAN, 0.7)
        tft.fill_circle(130, ST_Y_RETRY, STONE_R, COL_HUMAN)

# ─── 盤面データ・ステータス変数 ──────────────────────
board        = [['.' for _ in range(8)] for _ in range(8)]
score_text   = "X:-- O:--"
move_text    = ""
time_text    = ""
human_text   = ""
player_stone = None   # 'X' (黒) or 'O' (白)、ゲーム開始時に確定
winner_stone = None   # 'X' or 'O'、勝者確定時にセット（Drawはそのまま None）
retry_mode   = False  # True = "r:Retry or q:Quit ?" プロンプト表示中
choose_mode  = False  # True = 先後手選択中

# ─── ノンブロッキング計測 ─────────────────────────────
_t_start   = 0
_measuring = False

def check_timer():
    """GPIO15 のエッジをポーリングして処理時間を計測する"""
    global _t_start, _measuring, time_text
    val = signal.value()
    if not _measuring and val == 1:
        _t_start   = utime.ticks_us()
        _measuring = True
        LED.value(1)
    elif _measuring and val == 0:
        elapsed    = utime.ticks_diff(utime.ticks_us(), _t_start)
        _measuring = False
        LED.value(0)
        time_text  = f"Time:{elapsed // 1000:d}ms"
        draw_status()

# ─── UARTパーサー (行単位) ────────────────────────────
def parse_board_line(line):
    """
    "3 . . O O O X . ." → (2, ['.', '.', 'O', 'O', 'O', 'X', '.', '.'])
    対象外 → (None, None)
    """
    if len(line) >= 2 and line[0] in '12345678':
        parts = line.split()
        if len(parts) >= 9:
            return int(parts[0]) - 1, parts[1:9]
    return None, None

# ─── Move: リアルタイム追跡 (バイト単位) ─────────────
# Z80は "Move: A1" を改行なしで送り、BS BS XX で位置を上書きする。
# 行単位パーサーでは捕捉できないため、1バイトずつ追跡する。
_sbuf      = b''    # "Move: " 検索バッファ (末尾6バイト保持)
_in_cursor = False  # "Move: " 受信後の位置追跡中フラグ
_pbuf      = b''    # 位置文字バッファ (最大2文字: 列+行)

def feed_byte(b):
    """1バイトごとに Move: カーソル位置を追跡し human_text を更新する"""
    global _sbuf, _in_cursor, _pbuf, human_text

    if not _in_cursor:
        # "BS BS" パターン: Pico起動時など Move: を受け損ねた場合でもカーソル更新を捕捉
        if b == 0x08 and len(_sbuf) > 0 and _sbuf[-1] == 0x08:
            _in_cursor = True
            _pbuf = b''
            _sbuf = b''
            return
        # "Move: " の末尾マッチを探す (末尾6バイトを保持)
        _sbuf = (_sbuf + bytes([b]))[-6:]
        if _sbuf.endswith(b'Move: '):
            _in_cursor = True
            _pbuf = b''
    else:
        if b == 0x08:                # BS: 次の2文字で位置が上書きされる
            _pbuf = b''
        elif b in (0x0D, 0x0A):      # 改行: Enter確定 → 人の手表示をクリア
            _in_cursor = False
            _sbuf      = b''
            _pbuf      = b''
            human_text = ""
            draw_status()
        else:
            _pbuf += bytes([b])
            if len(_pbuf) == 2:      # 列+行の2文字がそろったら表示更新
                pos = _pbuf.decode('utf-8', 'ignore')
                human_text = "You: " + pos
                draw_status()

# ─── 行単位パーサー (UART・ログ再生で共用) ──────────
def process_line(line):
    """1行分の文字列を解析して盤面・ステータスを更新する"""
    global score_text, move_text, time_text, human_text, player_stone, winner_stone, retry_mode, choose_mode

    row_idx, cells = parse_board_line(line)
    if row_idx is not None:
        board[row_idx] = cells
        for col in range(8):
            draw_stone(col, row_idx, cells[col])
        if row_idx == 0:
            retry_mode   = False
            winner_stone = None
            human_text   = ""

    elif line.startswith('X:') and 'O:' in line:
        score_text = line
        draw_status()

    elif line.startswith('AI moves to'):
        move_text  = line
        human_text = ""
        draw_status()

    elif line == 'AI PASS':
        move_text  = "AI PASS"
        human_text = ""
        draw_status()

    elif line == 'YOU PASS':
        human_text = "YOU PASS"
        draw_status()

    elif line.startswith('Game ended by consecutive'):
        time_text = "Consec. PASS"
        draw_status()

    elif line == 'GAME OVER':
        move_text  = "GAME OVER"
        human_text = ""
        draw_status()

    elif 'wins' in line or line in ('DRAW', 'Draw'):
        if 'BLACK' in line:
            human_text   = "BLACK wins"
            winner_stone = 'X'
        elif 'WHITE' in line:
            human_text   = "WHITE wins"
            winner_stone = 'O'
        else:
            human_text   = "DRAW"
            winner_stone = None
        retry_mode = True
        draw_status()

    elif 'Choose:' in line:
        choose_mode  = True
        move_text    = ""
        human_text   = ""
        draw_status()

    elif 'You are BLACK' in line:
        choose_mode  = False
        player_stone = 'X'
        draw_status()
    elif 'You are WHITE' in line:
        choose_mode  = False
        player_stone = 'O'
        draw_status()

    elif line in ('R', 'r'):
        retry_mode   = False
        choose_mode  = False
        player_stone = None
        winner_stone = None
        score_text   = "X:-- O:--"
        move_text    = ""
        human_text   = ""
        draw_status()

# ─── ログ再生 ─────────────────────────────────────────
def replay_log(filename, line_delay_ms=400):
    """
    Pico ファイルシステム上のログファイルを行単位で再生する。
    Z80 実機なしで表示確認ができる。
    ファイルが存在しない場合は何もしない。
    """
    try:
        with open(filename) as f:
            lines = f.readlines()
    except OSError:
        return
    for raw in lines:
        line = raw.strip('\r\n ')
        if line:
            process_line(line)
        utime.sleep_ms(line_delay_ms)

# ─── 初期描画 ─────────────────────────────────────────
draw_board()
draw_status()

# ログファイルがあれば Z80 なしで表示テスト (/replay.txt)
replay_log('/replay.txt')

# ─── メインループ ─────────────────────────────────────
line_buf = b''

while True:
    check_timer()

    if uart.any():
        data = uart.read(uart.any())

        for byte in data:
            feed_byte(byte)

        line_buf += data
        while b'\n' in line_buf:
            idx      = line_buf.index(b'\n')
            raw      = line_buf[:idx]
            line_buf = line_buf[idx + 1:]
            line     = raw.decode('utf-8', 'ignore').strip('\r ')
            process_line(line)

    utime.sleep_ms(10)
