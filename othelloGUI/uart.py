from machine import UART, Pin
import time

# UART0の初期化
# TX: GP0, RX: GP1 (デフォルトピン)
uart = UART(0, baudrate=9600, tx=Pin(0), rx=Pin(1))

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

# メインループ
while True:
    # 少し待って受信確認
    received = receive_data()
    print(f"受信: {received}")
    
    time.sleep(0.1)  # 1秒待機