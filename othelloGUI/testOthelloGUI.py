from machine import Pin, SPI
import st7789
import utime
import urandom
import romand as vector_font

head = ["A", "B", "C", "D", "E", "F", "G", "H"]
black_white = [0, 1, 1, 0]

spi = SPI(0, baudrate=31250000,
          sck=Pin(18), mosi=Pin(19))

tft = st7789.ST7789(spi, 240, 320,
    reset=Pin(20, Pin.OUT),
    cs=Pin(17, Pin.OUT),
    dc=Pin(16, Pin.OUT),
    backlight=Pin(21, Pin.OUT),
    rotation=0)

tft.init()
tft.madctl(0x88)

sw_left  = Pin( 9, Pin.IN, Pin.PULL_DOWN)
sw_right = Pin(10, Pin.IN, Pin.PULL_DOWN)
sw_up    = Pin(11, Pin.IN, Pin.PULL_DOWN)
sw_down  = Pin(12, Pin.IN, Pin.PULL_DOWN)
sw_enter = Pin(13, Pin.IN, Pin.PULL_DOWN)

tft.fill(st7789.BLACK)

colors = [
    st7789.WHITE, st7789.RED, st7789.GREEN, st7789.BLUE,
    st7789.YELLOW, st7789.CYAN, st7789.MAGENTA, st7789.BLACK
]

white = colors[0]
black = colors[7]
green = colors[6]

w = 25
h = 25
r = 8
index = 1

tft.fill_rect(30, 30, 196, 196, green)

for j in range(2):
    jj = j + 3
    y = int(jj * 24.5 + 42.25)
    for i in range(2):
        ii = i + 3
        x = int(ii * 24.5 + 42.25)
        index = black_white[j * 2 + i]
        
        if index:
            tft.fill_circle(x, y, r, white)
        else:
            tft.fill_circle(x, y, r, black)
    
for i in range(8):
    x = int(i * 24.5 + 30)
    for j in range(8):
        y = int(j * 24.5 + 30)
        tft.hline(x,     y,     w, colors[0])   # 上
        tft.vline(x,     y,     h, colors[0])   # 左
    tft.hline(30,     226,     196, colors[0])   # 上
    tft.vline(226,     30,     196, colors[0])   # 左

for i in range(8):
    x = int(i * 24.5 + 35)
    y = int(i * 24.5 + 43)
    tft.draw(vector_font, head[i], x, 20, st7789.color565(255,255,255), 0.8)
    tft.draw(vector_font, str(i+1), 8, y, st7789.color565(255,255,255), 0.8)

tft.draw(vector_font, "AI MOVE:A1 B:24 W:32", 8, 240, st7789.color565(255,255,255), 0.6)

tft.draw(vector_font, "Your turn(A1-H8)", 8, 257, st7789.color565(255,255,255), 0.6)
tft.draw(vector_font, ">", 8, 274, white, 0.6)

col_index = 0    # 'A'に対応
row_index = 0    # '0'に対応

tft.draw(vector_font, "A", 24, 274, st7789.color565(255,255,255), 0.6)
tft.draw(vector_font, "1", 40, 274, st7789.color565(255,255,255), 0.6)

while True:
    # 入力を待つ
    while (sw_left.value() == 0) and (sw_right.value() == 0) and \
          (sw_up.value() == 0) and (sw_down.value() == 0) and \
          (sw_enter.value() == 0):
        pass
    
    val_left   = sw_left.value()
    val_right  = sw_right.value()
    val_up     = sw_up.value()
    val_down   = sw_down.value()
    val_enter  = sw_enter.value()
    
    if val_left == 1:
        col_index = (col_index -1) % 8
    elif val_right == 1:
        col_index = (col_index + 1) % 8
    elif val_up == 1:
        row_index = (row_index -1) % 8
    elif val_down == 1:
        row_index = (row_index + 1) % 8
    
    
    val_left  = 0
    val_right = 0    
    val_down  = 0
    val_up = 0    
    
#     print('col:', col_index)
#     print('row:', row_index)

    a = head[col_index]
    tft.fill_rect(24, 267, 16, 26, black)
    tft.draw(vector_font, a, 24, 274, white, 0.6)
    utime.sleep(0.1)

    b = str(row_index + 1)
    tft.fill_rect(40, 267, 30, 30, black)
    tft.draw(vector_font, b, 40, 274, white, 0.6)
    utime.sleep(0.1)
    

    if val_enter:
        col = col_index
        row = row_index

        y = int(row * 24.5 + 42.25)
        x = int(col * 24.5 + 42.25)
        index = 1 - index
        if index:
            tft.fill_circle(x, y, r, white)
        else:
            tft.fill_circle(x, y, r, black)

    val_enter = 0
