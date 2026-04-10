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
#   定数名          実際の値           画面上の色
COL_BOARD = st7789.MAGENTA   # → 緑  (盤面)
COL_GRID  = st7789.WHITE     # → 黒  (グリッド線)
COL_BG    = st7789.BLACK     # → 白  (画面背景)
COL_STONE_X = st7789.WHITE   # → 黒  (X石)
COL_STONE_O = st7789.BLACK   # → 白  (O石)
COL_TEXT    = st7789.WHITE   # → 黒  (ラベル・ステータス)
COL_CYAN    = st7789.YELLOW  # → シアン (強調テキスト)

# ─── 盤面レイアウト定数 ───────────────────────────────
BOARD_X   = 30      # 盤面左上 X
BOARD_Y   = 30      # 盤面左上 Y
CELL_SIZE = 24.5    # 1マスのピクセル数
STONE_R   = 8       # 石の半径
COLS_LABEL = ["A","B","C","D","E","F","G","H"]

def cell_center(col, row):
    """col/row (0-7) → 画面ピクセル座標 (cx, cy)"""
    cx = int(col * CELL_SIZE + BOARD_X + CELL_SIZE / 2)
    cy = int(row * CELL_SIZE + BOARD_Y + CELL_SIZE / 2)
    return cx, cy

# ─── 描画関数 ─────────────────────────────────────────
def draw_board():
    """盤面背景・グリッド・列行ラベルを描画する"""
    tft.fill(COL_BG)

    # 盤面の緑背景
    tft.fill_rect(BOARD_X, BOARD_Y, 196, 196, COL_BOARD)

    # グリッド線 (縦・横 各9本)
    for i in range(9):
        x = int(i * CELL_SIZE + BOARD_X)
        y = int(i * CELL_SIZE + BOARD_Y)
        tft.vline(x, BOARD_Y,      196, COL_GRID)
        tft.hline(BOARD_X, y, 196, COL_GRID)

    # 列ラベル A-H
    for i in range(8):
        lx = int(i * CELL_SIZE + BOARD_X + 7)
        tft.draw(vector_font, COLS_LABEL[i], lx, 16, COL_TEXT, 0.7)

    # 行ラベル 1-8
    for i in range(8):
        ly = int(i * CELL_SIZE + BOARD_Y + 7)
        tft.draw(vector_font, str(i + 1), 8, ly, COL_TEXT, 0.7)

def draw_stone(col, row, piece):
    """指定セルに石または空白を描画する"""
    cx, cy = cell_center(col, row)
    if piece == 'X':
        tft.fill_circle(cx, cy, STONE_R, COL_STONE_X)
    elif piece == 'O':
        tft.fill_circle(cx, cy, STONE_R, COL_STONE_O)
    else:
        # 空白: 緑で塗り直す（石を消す）
        tft.fill_circle(cx, cy, STONE_R, COL_BOARD)

def draw_all_stones():
    """board配列の全セルを描画する"""
    for row in range(8):
        for col in range(8):
            draw_stone(col, row, board[row][col])

def draw_status(score_text, move_text, time_text=""):
    """盤面下のステータスエリアを更新する"""
    tft.fill_rect(0, 232, 240, 88, COL_BG)
    if score_text:
        tft.draw(vector_font, score_text, 8, 240, COL_TEXT, 0.7)
    if move_text:
        tft.draw(vector_font, move_text,  8, 258, COL_CYAN, 0.7)
    if time_text:
        tft.draw(vector_font, time_text,  8, 276, COL_TEXT, 0.7)

# ─── 盤面データ ───────────────────────────────────────
board       = [['.' for _ in range(8)] for _ in range(8)]
score_text  = "X:-- O:--"
move_text   = ""
time_text   = ""

# ─── ノンブロッキング計測 ─────────────────────────────
_t_start   = 0
_measuring = False

def check_timer():
    """GPIO15 のエッジをポーリングして処理時間を計測する。更新があれば True を返す"""
    global _t_start, _measuring, time_text
    val = signal.value()
    if not _measuring and val == 1:          # 立ち上がり検出
        _t_start  = utime.ticks_us()
        _measuring = True
        LED.value(1)
        return False
    elif _measuring and val == 0:            # 立ち下がり検出
        elapsed    = utime.ticks_diff(utime.ticks_us(), _t_start)
        _measuring = False
        LED.value(0)
        time_text  = f"Time:{elapsed // 1000:d}ms"
        return True   # 呼び出し元で draw_status を呼ぶ
    return False

# ─── UARTパーサー ─────────────────────────────────────
def parse_board_line(line):
    """
    "3 . . O O O X . ." → (2, ['.', '.', 'O', 'O', 'O', 'X', '.', '.'])
    対象外の行 → (None, None)
    """
    if len(line) >= 2 and line[0] in '12345678':
        parts = line.split()
        if len(parts) >= 9:
            return int(parts[0]) - 1, parts[1:9]
    return None, None

# ─── 初期描画 ─────────────────────────────────────────
draw_board()
draw_status(score_text, move_text, time_text)

# ─── メインループ ─────────────────────────────────────
buf = b''

while True:
    dirty = check_timer()  # タイマー更新があれば True

    if uart.any():
        buf += uart.read(uart.any())

    while b'\n' in buf:
        idx  = buf.index(b'\n')
        raw  = buf[:idx]
        buf  = buf[idx + 1:]
        line = raw.decode('utf-8', 'ignore').strip('\r ')

        # 盤面行
        row_idx, cells = parse_board_line(line)
        if row_idx is not None:
            board[row_idx] = cells
            for col in range(8):
                draw_stone(col, row_idx, cells[col])

        # スコア行: "X:06 O:12"
        elif len(line) >= 7 and line.startswith('X:'):
            score_text = line
            dirty = True

        # AI手行: "AI moves to C8"
        elif line.startswith('AI moves to'):
            move_text = line
            dirty = True

        # AI/人間 パス
        elif line == 'AI PASS':
            move_text = 'AI PASS'
            dirty = True
        elif line == 'YOU PASS':
            move_text = 'YOU PASS'
            dirty = True

    # 1ループ内の全処理が終わってから1回だけ描画
    if dirty:
        draw_status(score_text, move_text, time_text)

    utime.sleep_ms(10)
