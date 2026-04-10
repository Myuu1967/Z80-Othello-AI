from machine import UART, Pin, SPI
import st7789
import utime
import urandom
import romand as vector_font

# PA7 を受け取るピン（プルダウン設定）
signal = Pin(15, Pin.IN, Pin.PULL_DOWN)

LED = Pin(25, Pin.OUT)

# UART0の初期化
# TX: GP0, RX: GP1 (デフォルトピン)
uart = UART(0, baudrate=9600, tx=Pin(0), rx=Pin(1))

# SPIとTFTの設定
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

# ── 1回計測モード ──────────────────────────
def measure_once():
    # 1発目のHigh立ち上がりを待つ
    while signal.value() == 0:
        pass
    t_start = utime.ticks_us()
    LED.value(1)

    # Lowに戻るのを待つ（Z80が次の処理で0x00を出力した場合）
    while signal.value() == 1:
        pass
    t_end = utime.ticks_us()
    LED.value(0)

    elapsed = utime.ticks_diff(t_end, t_start)
    # print(f"処理時間: {elapsed} μs  ({elapsed/1000:.3f} ms)")
    return elapsed


# UART設定の詳細表示
def send_data(data: str):
    """文字列データを送信する"""
    uart.write(data + '\n')

def receive_data() -> str | None:
    """データを受信する（受信データがあればstr、なければNoneを返す）"""
    if uart.any():
        data = uart.readline()
        if data:
            decoded = data.decode('utf-8').strip()
#             print(f"受信: {decoded}")
            return decoded
    return None

colors = [
    st7789.WHITE, st7789.RED, st7789.GREEN, st7789.BLUE,
    st7789.YELLOW, st7789.CYAN, st7789.MAGENTA, st7789.BLACK
]

black = colors[0]
white = colors[7]
green = colors[6]

# メインループ
while True:
    # 少し待って受信確認
    received = receive_data()
    print(f"受信: {received}")
    
    if received != None:
        tft.fill_rect(40, 33, 150, 50, black)
        tft.draw(vector_font, received, 40, 40, white, 0.6)

    utime.sleep(0.1)  # 0.1秒待機
    
    elapsed = int(measure_once() // 1000)
    str_time = f"Time:{elapsed:d}ms"
    if str_time != None:
        tft.fill_rect(40, 73, 150, 50, black)
        tft.draw(vector_font, str_time, 40, 90, white, 0.6)
