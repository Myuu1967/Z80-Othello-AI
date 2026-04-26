"""
AI 対戦比較ベンチマーク
先後手を交替しながら N ペア対戦し、勝率を計測する。

使い方:
    python benchmark_vs.py [n_pairs]   # デフォルト n_pairs=10

比較セット:
    1. V1/d2 vs V2/d2  ← 重みだけの差
    2. V1/d2 vs V1/d3  ← 深さだけの差
    3. V1/d2 vs V2/d3  ← 総合（現Z80 vs 新設計）
"""
import sys
import time
import othello_mm3_ab as mm
from othello_mm3_ab import (
    make_board, get_legal_moves, apply_move, count_stones,
    ai_choose_move, pos_to_str,
    POS_WEIGHT_V1, POS_WEIGHT_V2,
)


def play_match(cfg_x, cfg_y):
    """
    1局対戦。cfg = (POS_WEIGHT_list, depth)
    X=BLACK先手, Y=WHITE後手
    戻り値: ('X'|'Y'|'Draw', black_count, white_count)
    """
    board = make_board()
    current = mm.BLACK
    pass_count = 0

    while True:
        legal = get_legal_moves(board, current)
        if not legal:
            pass_count += 1
            if pass_count >= 2:
                break
            current = 3 - current
            continue
        pass_count = 0

        cfg = cfg_x if current == mm.BLACK else cfg_y
        mm.POS_WEIGHT[:] = cfg[0]
        depth = cfg[1]

        pos, _ = ai_choose_move(board, current, depth=depth)
        board = apply_move(board, pos, current)
        if board.count(mm.EMPTY) == 0:
            break
        current = 3 - current

    b, o = count_stones(board)
    if b > o:
        return 'X', b, o
    elif o > b:
        return 'Y', b, o
    else:
        return 'Draw', b, o


def run_match_series(cfg_a, cfg_b, label_a, label_b, n_pairs):
    """
    n_pairs ペア対戦（各ペア: A=X/B=Y 1局 + B=X/A=Y 1局）
    勝率を返す。
    """
    wins = {label_a: 0, label_b: 0, 'Draw': 0}
    total = n_pairs * 2
    t0 = time.time()

    print(f"\n{'='*56}")
    print(f"  {label_a}  vs  {label_b}  ({total}局)")
    print(f"{'='*56}")

    for i in range(n_pairs):
        # A=BLACK, B=WHITE
        result, b, o = play_match(cfg_a, cfg_b)
        winner = label_a if result == 'X' else (label_b if result == 'Y' else 'Draw')
        wins[winner] += 1
        print(f"  [{2*i+1:3d}] {label_a}=X  {label_b}=O  "
              f"X:{b:2d} O:{o:2d}  → {winner}", flush=True)

        # B=BLACK, A=WHITE
        result, b, o = play_match(cfg_b, cfg_a)
        winner = label_b if result == 'X' else (label_a if result == 'Y' else 'Draw')
        wins[winner] += 1
        print(f"  [{2*i+2:3d}] {label_b}=X  {label_a}=O  "
              f"X:{b:2d} O:{o:2d}  → {winner}", flush=True)

    elapsed = time.time() - t0
    pct_a = wins[label_a] / total * 100
    pct_b = wins[label_b] / total * 100
    print(f"\n  結果 ({elapsed:.0f}秒):")
    print(f"    {label_a}: {wins[label_a]:3d}勝  ({pct_a:.0f}%)")
    print(f"    {label_b}: {wins[label_b]:3d}勝  ({pct_b:.0f}%)")
    print(f"    Draw    : {wins['Draw']:3d}")

    # 判定
    if wins[label_b] > wins[label_a] * 1.2:
        verdict = f">>> {label_b} が有意に優勢"
    elif wins[label_a] > wins[label_b] * 1.2:
        verdict = f">>> {label_a} が有意に優勢"
    else:
        verdict = ">>> 差が小さい（互角）"
    print(f"  {verdict}")
    return wins


def main():
    n_pairs = int(sys.argv[1]) if len(sys.argv) > 1 else 10

    # 各設定を定義
    # cfg = (weight_list_copy, depth)
    cfg_v1d2 = (POS_WEIGHT_V1[:], 2)   # 現Z80相当
    cfg_v2d2 = (POS_WEIGHT_V2[:], 2)   # 重みだけ改善
    cfg_v1d3 = (POS_WEIGHT_V1[:], 3)   # 深さだけ改善
    cfg_v2d3 = (POS_WEIGHT_V2[:], 3)   # 総合新設計

    print(f"ベンチマーク開始  n_pairs={n_pairs}  (合計{n_pairs*2}局×3セット)")
    print(f"\nPOS_WEIGHT_V1 (現Z80): Corner={POS_WEIGHT_V1[0]}, "
          f"X-sq={POS_WEIGHT_V1[9]}, C-sq={POS_WEIGHT_V1[1]}")
    print(f"POS_WEIGHT_V2 (新設計): Corner={POS_WEIGHT_V2[0]}, "
          f"X-sq={POS_WEIGHT_V2[9]}, C-sq={POS_WEIGHT_V2[1]}")

    # セット1: 重みだけの差
    run_match_series(cfg_v1d2, cfg_v2d2,
                     "V1/d2", "V2/d2", n_pairs)

    # セット2: 深さだけの差
    run_match_series(cfg_v1d2, cfg_v1d3,
                     "V1/d2", "V1/d3", n_pairs)

    # セット3: 総合比較（現Z80 vs 新設計）
    run_match_series(cfg_v1d2, cfg_v2d3,
                     "V1/d2(現Z80)", "V2/d3(新設計)", n_pairs)

    # POS_WEIGHT を元に戻す
    mm.POS_WEIGHT[:] = POS_WEIGHT_V2


if __name__ == '__main__':
    main()
