# Othello AI - Python prototype for Z80 porting
# Board: list[64], 0=EMPTY, 1=BLACK(X), 2=WHITE(O)
# Display format matches Z80 serial output

import sys
import copy

# =========================================================
# Constants
# =========================================================
EMPTY = 0
BLACK = 1
WHITE = 2

BOARD_W = 8
DIR_OFFSETS = [-9, -8, -7, -1, 1, 7, 8, 9]

# Direction validity: prevents wrap-around
# For each direction, the column-delta (used to detect left/right wrap)
DIR_COL_DELTA = [-1, 0, 1, -1, 1, -1, 0, 1]

# =========================================================
# POS_WEIGHT table (same as Z80 version)
# =========================================================
POS_WEIGHT = [
    120,  5, 30, 25, 25, 30,  5, 120,  # row 1
      5,  1, 15, 15, 15, 15,  1,   5,  # row 2
     30, 15, 20, 20, 20, 20, 15,  30,  # row 3
     25, 15, 20, 18, 18, 20, 15,  25,  # row 4
     25, 15, 20, 18, 18, 20, 15,  25,  # row 5
     30, 15, 20, 20, 20, 20, 15,  30,  # row 6
      5,  1, 15, 15, 15, 15,  1,   5,  # row 7
    120,  5, 30, 25, 25, 30,  5, 120,  # row 8
]

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
    col = pos % 8
    row = pos // 8
    return chr(ord('A') + col) + str(row + 1)

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
    """Count flippable stones in one direction d."""
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
    """Total flippable stones for a move. Returns 0 if illegal."""
    if board[pos] != EMPTY:
        return 0
    total = 0
    for d in range(8):
        total += count_flips_dir(board, pos, side, d)
    return total

def apply_move(board, pos, side):
    """Apply move, return new board. Assumes move is legal."""
    opp = 3 - side
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
    """Return list of legal move positions."""
    moves = []
    for pos in range(64):
        if count_flips(board, pos, side) > 0:
            moves.append(pos)
    return moves

def count_mobility(board, side):
    return len(get_legal_moves(board, side))

def count_stones(board):
    x = board.count(BLACK)
    o = board.count(WHITE)
    return x, o

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
# AI - Depth 1 (same logic as Z80 OppBestScore / CountMobility)
# =========================================================
def opp_best_score(board, opp_side):
    """Best score opponent can get + count of opponent moves."""
    best = 0
    move_count = 0
    for pos in range(64):
        flips = count_flips(board, pos, opp_side)
        if flips > 0:
            move_count += 1
            score = POS_WEIGHT[pos] + flips
            if score > best:
                best = score
    return best, move_count

def ai_eval_d1(board, pos, ai_side):
    """Evaluate AI move at pos using depth-1 minimax."""
    opp_side = 3 - ai_side
    new_board = apply_move(board, pos, ai_side)
    opp_best, opp_mob = opp_best_score(new_board, opp_side)
    ai_mob = count_mobility(new_board, ai_side)
    # mm_score = weight + (255 - opp_best) + (ai_mob - opp_mob + 64)
    return POS_WEIGHT[pos] + (255 - opp_best) + (ai_mob - opp_mob + 64)

def ai_choose_move(board, side):
    """Choose best move for side. Returns pos or -1 if no moves."""
    best_score = -1
    best_pos = -1
    for pos in range(64):
        if count_flips(board, pos, side) > 0:
            score = ai_eval_d1(board, pos, side)
            if score > best_score:
                best_score = score
                best_pos = pos
    return best_pos

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
    """Prompt human for a move. Returns pos."""
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

    # mode 1: human=BLACK(1), ai=WHITE(2)
    # mode 2: ai=BLACK(1), human=WHITE(2)
    # mode 3: ai vs ai
    if mode == 1:
        human_side = BLACK
        ai_side = WHITE
        print("You go first. You are BLACK (X).")
    elif mode == 2:
        human_side = WHITE
        ai_side = BLACK
        print("AI goes first. You are WHITE (O).")
    else:
        human_side = None
        ai_side = None  # both AI
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
                side_name = "AI(X)" if current == BLACK else "AI(O)"
                print(f"{side_name} PASS")
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
            pos = ai_choose_move(board, current)
            if mode == 3:
                side_name = "AI(X)" if current == BLACK else "AI(O)"
                print(f"{side_name} moves to {pos_to_str(pos)}")
            else:
                print(f"AI moves to {pos_to_str(pos)}")

        board = apply_move(board, pos, current)
        print_board(board)
        print_counts(board)

        if board.count(EMPTY) == 0:
            break

        current = 3 - current

    # Game over
    print("\nGAME OVER")
    x, o = count_stones(board)
    if x > o:
        print("BLACK(X) wins")
    elif o > x:
        print("WHITE(O) wins")
    else:
        print("Draw")
    print(f"X:{x:2d} O:{o:2d}")

def main():
    while True:
        mode = choose_mode()
        play_game(mode)
        print("\nr:Retry or q:Quit ? ", end='')
        ans = input().strip().lower()
        if ans == 'q':
            print("\nBye.")
            break

if __name__ == '__main__':
    main()
