from machine import Pin, SPI
import st7789
import utime
import urandom

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

tft.fill(st7789.BLACK)

colors = [
    st7789.WHITE, st7789.RED, st7789.GREEN, st7789.BLUE,
    st7789.YELLOW, st7789.CYAN, st7789.MAGENTA
]

while True:
    x = urandom.randint(20, 219)
    y = urandom.randint(20, 299)
    r = urandom.randint(5, 20)
    color = colors[urandom.randint(0, len(colors) - 1)]
    
    tft.fill_circle(x, y, r, color)
    utime.sleep_ms(100)