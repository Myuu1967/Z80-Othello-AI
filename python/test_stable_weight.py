"""
LATE式 stable 重み A/B テスト
  V_A: stable × 30  (現行 RFCT120 と同一)
  V_B: stable × W   (W = 60 or 100 等、引数で指定)

Black(X) = V_A 先手、White(O) = V_B 後手 で n_games 局。
その後 先後を入れ替えてさらに n_games 局（合計 2*n_games）。
"""

import sys
import othello_mm3_ab as oth
from play_vs_ai import POS_WEIGHT_D3, POS_WEIGHT_D2, D3_THRESHOLD

# --- 評価関数ファクトリ ---
MID_GAME = 18

def make_eval(stable_w):
    """stable 重み stable_w の LATE 式評価関数を返す"""
    def _eval(board, side):
        empty = board.count(oth.EMPTY)
        opp   = 3 - side
        if empty < MID_GAME:
            x = board.count(oth.BLACK)
            o = board.count(oth.WHITE)
            stone_diff = (x - o) if side == oth.BLACK else (o - x)
            my_s  = oth.count_stable_stones(board, side)
            opp_s = oth.count_stable_stones(board, opp)
            return stone_diff * 100 + (my_s - opp_s) * stable_w
        my_pos  = sum(oth.POS_WEIGHT[i] for i in range(64) if board[i] == side)
        opp_pos = sum(oth.POS_WEIGHT[i] for i in range(64) if board[i] == opp)
        pos_diff = my_pos - opp_pos
        mob_diff = oth.count_mobility(board, side) - oth.count_mobility(board, opp)
        my_s  = oth.count_stable_stones(board, side)
        opp_s = oth.count_stable_stones(board, opp)
        stable_diff = my_s - opp_s
        x = board.count(oth.BLACK)
        o = board.count(oth.WHITE)
        stone_diff = (x - o) if side == oth.BLACK else (o - x)
        if empty >= 44:
            return pos_diff + mob_diff * 8 + stable_diff * 8 - stone_diff * 8
        else:
            return pos_diff + mob_diff * 8 + stable_diff * 16 - stone_diff * 4
    return _eval


def ai_choose(board, side, eval_fn):
    empty = board.count(oth.EMPTY)
    depth = 3 if empty < D3_THRESHOLD else 2
    oth.POS_WEIGHT = POS_WEIGHT_D3 if depth == 3 else POS_WEIGHT_D2
    oth.eval_board = eval_fn
    pos, score = oth.ai_choose_move(board, side, depth=depth)
    return pos, score


def play_one(eval_black, eval_white, verbose=False):
    board = oth.make_board()
    current = oth.BLACK
    pass_count = 0
    while True:
        legal = oth.get_legal_moves(board, current)
        if not legal:
            pass_count += 1
            if pass_count >= 2:
                break
            current = 3 - current
            continue
        pass_count = 0
        eval_fn = eval_black if current == oth.BLACK else eval_white
        pos, _ = ai_choose(board, current, eval_fn)
        board = oth.apply_move(board, pos, current)
        if board.count(oth.EMPTY) == 0:
            break
        current = 3 - current
    x, o = oth.count_stones(board)
    if verbose:
        print(f"  X={x} O={o}")
    return x, o


def run_test(n_games, stable_a, stable_b):
    eval_a = make_eval(stable_a)
    eval_b = make_eval(stable_b)

    label_a = f"stable×{stable_a}"
    label_b = f"stable×{stable_b}"

    results = {label_a: 0, label_b: 0, 'Draw': 0}
    total = 0

    print(f"\n=== A(X, {label_a}) vs B(O, {label_b}) : {n_games} games ===")
    for i in range(n_games):
        x, o = play_one(eval_a, eval_b)
        total += 1
        if x > o:
            results[label_a] += 1
            res = f"A wins (X={x} O={o})"
        elif o > x:
            results[label_b] += 1
            res = f"B wins (X={x} O={o})"
        else:
            results['Draw'] += 1
            res = f"Draw  (X={x} O={o})"
        print(f"  Game {i+1:2d}: {res}")

    print(f"\n=== B(X, {label_b}) vs A(O, {label_a}) : {n_games} games ===")
    for i in range(n_games):
        x, o = play_one(eval_b, eval_a)
        total += 1
        if x > o:
            results[label_b] += 1
            res = f"B wins (X={x} O={o})"
        elif o > x:
            results[label_a] += 1
            res = f"A wins (X={x} O={o})"
        else:
            results['Draw'] += 1
            res = f"Draw  (X={x} O={o})"
        print(f"  Game {i+1:2d}: {res}")

    print(f"\n{'='*50}")
    print(f"Total {total} games:")
    print(f"  {label_a} : {results[label_a]} wins")
    print(f"  {label_b} : {results[label_b]} wins")
    print(f"  Draw       : {results['Draw']}")


if __name__ == '__main__':
    # 引数: [n_games] [stable_b]
    # 例: python test_stable_weight.py 20 60
    n      = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    stable_b = int(sys.argv[2]) if len(sys.argv) > 2 else 60

    run_test(n, stable_a=30, stable_b=stable_b)
