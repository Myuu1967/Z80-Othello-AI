from machine import Pin
import time

# PA7 を受け取るピン（プルダウン設定）
signal = Pin(15, Pin.IN, Pin.PULL_DOWN)

LED = Pin(25, Pin.OUT)

print("計測待機中... Z80から0x80が来るのを待っています")

# ── 1回計測モード ──────────────────────────
def measure_once():
    # 1発目のHigh立ち上がりを待つ
    while signal.value() == 0:
        pass
    t_start = time.ticks_us()
    LED.value(1)

    # Lowに戻るのを待つ（Z80が次の処理で0x00を出力した場合）
    while signal.value() == 1:
        pass
    t_end = time.ticks_us()
    LED.value(0)

    elapsed = time.ticks_diff(t_end, t_start)
    print(f"処理時間: {elapsed} μs  ({elapsed/1000:.3f} ms)")
    return elapsed

# ── 複数回計測して平均を出すモード ──────────
def measure_average(count=10):
    results = []
    print(f"{count}回計測します")

    for i in range(count):
        # High待ち
        while signal.value() == 0:
            pass
        t_start = time.ticks_us()

        # Low待ち
        while signal.value() == 1:
            pass
        t_end = time.ticks_us()

        elapsed = time.ticks_diff(t_end, t_start)
        results.append(elapsed)
        print(f"  [{i+1:2d}] {elapsed} μs")

        # 次の計測まで少し待つ（Z80側の準備時間）
        time.sleep_us(10)

    avg = sum(results) / len(results)
    mn  = min(results)
    mx  = max(results)
    print(f"\n--- 結果 ---")
    print(f"  平均: {avg:.1f} μs  ({avg/1000:.3f} ms)")
    print(f"  最小: {mn} μs")
    print(f"  最大: {mx} μs")
    print(f"  ばらつき: {mx - mn} μs")
    return results

# ── メイン ──────────────────────────────────
# 使い方に応じてどちらかを呼ぶ

# 1回だけ計測する場合:
# measure_once()

# 複数回計測して統計を出す場合:
measure_average(10)