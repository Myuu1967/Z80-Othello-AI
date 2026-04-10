from machine import UART, Pin
import utime

# ─── UART0 (Z80 SIOA受信) ────────────────────────────
uart = UART(0, baudrate=9600, tx=Pin(0), rx=Pin(1))

# ─── 8x8盤面 ('.', 'O', 'X') ─────────────────────────
board = [['.' for _ in range(8)] for _ in range(8)]

# ─── 行パーサー ───────────────────────────────────────
def parse_board_line(line):
    """
    "3 . . O O O X . ." → (2, ['.', '.', 'O', 'O', 'O', 'X', '.', '.'])
    先頭が 1-8 でない行 → (None, None)
    """
    if len(line) >= 2 and line[0] in '12345678':
        parts = line.split()
        if len(parts) >= 9:
            return int(parts[0]) - 1, parts[1:9]
    return None, None

# ─── メインループ ─────────────────────────────────────
buf = b''

while True:
    if uart.any():
        buf += uart.read(uart.any())

        # \n 区切りで行ごとに処理
        while b'\n' in buf:
            idx = buf.index(b'\n')
            raw = buf[:idx]
            buf  = buf[idx + 1:]
            line = raw.decode('utf-8', 'ignore').strip('\r ')

            row, cells = parse_board_line(line)
            if row is not None:
                board[row] = cells
                print(f"row{row + 1}: {cells}")

                # 8行揃ったら盤面をまとめて表示
                if row == 7:
                    print("=== board ===")
                    for r in range(8):
                        print(' '.join(board[r]))

    utime.sleep_ms(10)
