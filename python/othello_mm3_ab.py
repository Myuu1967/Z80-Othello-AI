# Othello AI - Python prototype for Z80 porting
# Minimax depth-3 + Alpha-Beta pruning (negamax recursive)
# Board: list[64], 0=EMPTY, 1=BLACK(X), 2=WHITE(O)
# Display format matches Z80 serial output
#
# NOTE: depth-2 (othello_mm2_ab.py) used unrolled Z80-style loops.
#       depth-3 uses recursive negamax + α-β (cleaner, same logic).
#       Leaf eval is board-based (POS_WEIGHT diff + mobility diff).
# Phase1: move ordering (POS_WEIGHT降順), random tiebreaking at root

import random

# =========================================================
# Constants
# =========================================================
EMPTY = 0
BLACK = 1
WHITE = 2

DIR_OFFSETS   = [-9, -8, -7, -1, 1, 7, 8, 9]
DIR_COL_DELTA = [-1,  0,  1, -1, 1,-1, 0, 1]

INF = 100000

# =========================================================
# POS_WEIGHT tables
# =========================================================
# V1: Z80互換（正値のみ）
POS_WEIGHT_V1 = [
    120,  5, 30, 25, 25, 30,  5, 120,  # row 1
      5,  1, 15, 15, 15, 15,  1,   5,  # row 2
     30, 15, 20, 20, 20, 20, 15,  30,  # row 3
     25, 15, 20, 18, 18, 20, 15,  25,  # row 4
     25, 15, 20, 18, 18, 20, 15,  25,  # row 5
     30, 15, 20, 20, 20, 20, 15,  30,  # row 6
      5,  1, 15, 15, 15, 15,  1,   5,  # row 7
    120,  5, 30, 25, 25, 30,  5, 120,  # row 8
]

# V2: 負値導入版（Python専用）
# Xマス(B2/G2/B7/G7)=-40, Cマス(A2/B1等)=-20
POS_WEIGHT_V2 = [
    120, -20,  20,  10,  10,  20, -20, 120,  # row 1
    -20, -40,  -5,   1,   1,  -5, -40, -20,  # row 2
     20,  -5,  15,   5,   5,  15,  -5,  20,  # row 3
     10,   1,   5,   3,   3,   5,   1,  10,  # row 4
     10,   1,   5,   3,   3,   5,   1,  10,  # row 5
     20,  -5,  15,   5,   5,  15,  -5,  20,  # row 6
    -20, -40,  -5,   1,   1,  -5, -40, -20,  # row 7
    120, -20,  20,  10,  10,  20, -20, 120,  # row 8
]

# ← ここを切り替えてA/Bテスト
POS_WEIGHT = POS_WEIGHT_V2

STONE_CHAR = ['.', 'X', 'O']

# =========================================================
# Board utilities
# =========================================================
def make_board():
    board = [EMPTY] * 64
    board[27] = WHITE
    board[28] = BLACK
    board[35] = BLACK
    board[36] = WHITE
    return board

def pos_to_str(pos):
    return chr(ord('A') + pos % 8) + str(pos // 8 + 1)

def str_to_pos(s):
    """'A1'..'H8' -> 0..63, or -1 on error"""
    if len(s) < 2:
        return -1
    col = ord(s[0].upper()) - ord('A')
    try:
        row = int(s[1]) - 1
    except ValueError:
        return -1
    if col < 0 or col > 7 or row < 0 or row > 7:
        return -1
    return row * 8 + col

def count_flips_dir(board, pos, side, d):
    opp = 3 - side
    col = pos % 8
    count = 0
    p = pos + DIR_OFFSETS[d]
    c = col + DIR_COL_DELTA[d]
    while 0 <= p < 64 and 0 <= c <= 7:
        if board[p] == opp:
            count += 1
            p += DIR_OFFSETS[d]
            c += DIR_COL_DELTA[d]
        elif board[p] == side and count > 0:
            return count
        else:
            return 0
    return 0

def count_flips(board, pos, side):
    if board[pos] != EMPTY:
        return 0
    return sum(count_flips_dir(board, pos, side, d) for d in range(8))

def apply_move(board, pos, side):
    new_board = board[:]
    new_board[pos] = side
    for d in range(8):
        n = count_flips_dir(board, pos, side, d)
        if n > 0:
            p = pos + DIR_OFFSETS[d]
            c = (pos % 8) + DIR_COL_DELTA[d]
            for _ in range(n):
                new_board[p] = side
                p += DIR_OFFSETS[d]
                c += DIR_COL_DELTA[d]
    return new_board

def get_legal_moves(board, side):
    return [pos for pos in range(64) if count_flips(board, pos, side) > 0]

def get_legal_moves_ordered(board, side):
    moves = [pos for pos in range(64) if count_flips(board, pos, side) > 0]
    return sorted(moves, key=lambda p: POS_WEIGHT[p], reverse=True)

def count_mobility(board, side):
    return sum(1 for pos in range(64) if count_flips(board, pos, side) > 0)

def count_stones(board):
    return board.count(BLACK), board.count(WHITE)

# =========================================================
# Display
# =========================================================
def print_board(board):
    print()
    print("  A B C D E F G H")
    for row in range(8):
        line = str(row + 1) + ' '
        for col in range(8):
            line += STONE_CHAR[board[row * 8 + col]] + ' '
        print(line)

def print_counts(board):
    x, o = count_stones(board)
    print(f"X:{x:2d} O:{o:2d}")

# =========================================================
# AI - Depth 3, negamax with α-β
#
# eval_board (leaf): POS_WEIGHT差 + モビリティ差 × MOB_WEIGHT
# negamax: 再帰 α-β。PASSは depth を消費しない。
# ai_choose_move: 最善手を返す。
# =========================================================

MOB_WEIGHT = 10  # モビリティ1手差あたりの重み（調整可）

def eval_board(board, side):
    """Static evaluation from side's perspective (leaf nodes)."""
    opp = 3 - side
    my_pos  = sum(POS_WEIGHT[i] for i in range(64) if board[i] == side)
    opp_pos = sum(POS_WEIGHT[i] for i in range(64) if board[i] == opp)
    my_mob  = count_mobility(board, side)
    opp_mob = count_mobility(board, opp)
    return (my_pos - opp_pos) + (my_mob - opp_mob) * MOB_WEIGHT

def negamax(board, depth, alpha, beta, side):
    """
    Negamax α-β. Returns score from side's perspective.
    PASS: depth を消費しない（強制手なので）。
    Game over: 石差 × 200 で大きな値を返す。
    """
    opp = 3 - side
    legal = get_legal_moves(board, side)

    if not legal:
        opp_legal = get_legal_moves(board, opp)
        if not opp_legal:
            x, o = count_stones(board)
            diff = (x - o) if side == BLACK else (o - x)
            return diff * 200
        # PASS: switch side, don't decrement depth
        return -negamax(board, depth, -beta, -alpha, opp)

    if depth == 0:
        return eval_board(board, side)

    legal = get_legal_moves_ordered(board, side)  # move ordering
    best = -INF
    for pos in legal:
        new_board = apply_move(board, pos, side)
        score = -negamax(new_board, depth - 1, -beta, -alpha, opp)
        if score > best:
            best = score
        if best > alpha:
            alpha = best
        if alpha >= beta:
            break  # β-cutoff
    return best

def ai_choose_move(board, side, depth=3):
    """Choose best move using negamax depth-3 α-β. Returns (pos, score).
    Move ordering: POS_WEIGHT降順。同点はランダム選択。"""
    opp = 3 - side
    alpha = -INF
    beta  = INF
    best_score = -INF
    best_moves = []

    for pos in get_legal_moves_ordered(board, side):
        new_board = apply_move(board, pos, side)
        score = -negamax(new_board, depth - 1, -beta, -alpha, opp)
        if score > best_score:
            best_score = score
            best_moves = [pos]
            alpha = score
        elif score == best_score:
            best_moves.append(pos)

    best_pos = random.choice(best_moves) if best_moves else -1
    return best_pos, best_score

# =========================================================
# Game loop
# =========================================================
def choose_mode():
    print("Choose mode:")
    print("  1: You(X) vs AI(O)  - You go first")
    print("  2: AI(X) vs You(O)  - AI goes first")
    print("  3: AI(X) vs AI(O)")
    while True:
        c = input("> ").strip()
        if c in ('1', '2', '3'):
            return int(c)
        print("Enter 1, 2 or 3.")

def human_input(board, side):
    legal = get_legal_moves(board, side)
    while True:
        raw = input("Your move (A1-H8) > ").strip()
        pos = str_to_pos(raw)
        if pos < 0:
            print("Bad input. Use A1-H8.")
            continue
        if pos not in legal:
            print("NG (illegal move).")
            continue
        return pos

def play_game(mode):
    board = make_board()

    if mode == 1:
        human_side = BLACK
        print("You go first. You are BLACK (X).")
    elif mode == 2:
        human_side = WHITE
        print("AI goes first. You are WHITE (O).")
    else:
        human_side = None
        print("AI(X) vs AI(O)")

    print_board(board)
    print_counts(board)

    current = BLACK
    pass_count = 0

    while True:
        legal = get_legal_moves(board, current)

        if not legal:
            pass_count += 1
            if current == human_side:
                print("YOU PASS")
            elif mode == 3:
                print(f"{'AI(X)' if current == BLACK else 'AI(O)'} PASS")
            else:
                print("AI PASS")

            if pass_count >= 2:
                print("\nGame ended by consecutive passes.")
                break
            current = 3 - current
            continue

        pass_count = 0
        is_human_turn = (mode != 3 and current == human_side)

        if is_human_turn:
            pos = human_input(board, current)
        else:
            if mode == 3:
                input("[Enter] to continue...")
            pos, score = ai_choose_move(board, current)
            if mode == 3:
                print(f"{'AI(X)' if current == BLACK else 'AI(O)'} moves to {pos_to_str(pos)}  eval={score}")
            else:
                print(f"AI moves to {pos_to_str(pos)}  eval={score}")

        board = apply_move(board, pos, current)
        print_board(board)
        print_counts(board)

        if board.count(EMPTY) == 0:
            break

        current = 3 - current

    print("\nGAME OVER")
    x, o = count_stones(board)
    if x > o:
        print("BLACK(X) wins")
    elif o > x:
        print("WHITE(O) wins")
    else:
        print("Draw")
    print(f"X:{x:2d} O:{o:2d}")

def ab_test(n_games=10, depth=3):
    """V1 vs V2 自動対戦。V1=BLACK(X), V2=WHITE(O) で n_games 局。"""
    global POS_WEIGHT
    results = {'V1': 0, 'V2': 0, 'Draw': 0}

    for i in range(n_games):
        board = make_board()
        current = BLACK
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

            if current == BLACK:
                POS_WEIGHT = POS_WEIGHT_V1
            else:
                POS_WEIGHT = POS_WEIGHT_V2

            pos, _ = ai_choose_move(board, current, depth)
            board = apply_move(board, pos, current)
            if board.count(EMPTY) == 0:
                break
            current = 3 - current

        x, o = count_stones(board)
        if x > o:
            results['V1'] += 1
        elif o > x:
            results['V2'] += 1
        else:
            results['Draw'] += 1
        print(f"Game {i+1:2d}: X={x} O={o}  {'V1 wins' if x>o else 'V2 wins' if o>x else 'Draw'}")

    POS_WEIGHT = POS_WEIGHT_V2  # restore
    print(f"\n--- {n_games} games: V1(X)={results['V1']}  V2(O)={results['V2']}  Draw={results['Draw']} ---")

def main():
    print("1: Play game  2: A/B test (V1 vs V2)")
    c = input("> ").strip()
    if c == '2':
        ab_test(10)
        return
    while True:
        mode = choose_mode()
        play_game(mode)
        print("\nr:Retry or q:Quit ? ", end='')
        if input().strip().lower() == 'q':
            print("\nBye.")
            break

if __name__ == '__main__':
    main()
