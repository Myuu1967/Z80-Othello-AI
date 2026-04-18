# Othello AI - Python prototype for Z80 porting
# Minimax depth-2 + Alpha-Beta pruning
# Board: list[64], 0=EMPTY, 1=BLACK(X), 2=WHITE(O)
# Display format matches Z80 serial output

# =========================================================
# Constants
# =========================================================
EMPTY = 0
BLACK = 1
WHITE = 2

DIR_OFFSETS  = [-9, -8, -7, -1, 1, 7, 8, 9]
DIR_COL_DELTA = [-1,  0,  1, -1, 1,-1, 0, 1]

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
# AI - Depth 2 + Alpha-Beta  (matches Z80 OppBestScore_d2)
#
# Structure:
#   AIset outer loop: AI tries each move pos_i
#     OppBestScore_d2 middle loop: opp tries each move pos_j
#       inner loop: AI tries each response pos_k
#         score_k = POS_WEIGHT[pos_k] + flips_k
#         α-cutoff: if obs_best >= obs2_min_ai → break k loop
#       update obs2_min_ai = min(obs2_min_ai, obs_best)
#     return 255 - obs2_min_ai  (= opp_best)
#   mm_score = POS_WEIGHT[pos_i] + (255 - opp_best) + (ai_mob - opp_mob + 64)
#            = POS_WEIGHT[pos_i] + obs2_min_ai      + (ai_mob - opp_mob + 64)
# =========================================================

def opp_best_score_d2(board, opp_side, ai_side):
    """
    Opponent picks the move that minimizes AI's depth-2 best response.
    Returns (opp_best, opp_mob).
      opp_best = 255 - min_j(max_k(POS_WEIGHT[k] + flips_k))
    α-β: inner k loop breaks when obs_best >= obs2_min_ai (current global min).
    """
    obs2_min_ai = 255  # OBS2_MIN_AI: minimum of AI's best seen so far
    opp_mob = 0

    for opp_pos in range(64):
        opp_flips = count_flips(board, opp_pos, opp_side)
        if opp_flips == 0:
            continue
        opp_mob += 1

        new_board = apply_move(board, opp_pos, opp_side)

        # Find AI's best response (OBS_BEST)
        obs_best = 0
        for ai_pos in range(64):
            ai_flips = count_flips(new_board, ai_pos, ai_side)
            if ai_flips == 0:
                continue
            score = POS_WEIGHT[ai_pos] + ai_flips
            if score > obs_best:
                obs_best = score
                # α-cutoff: obs_best >= obs2_min_ai → this opp move won't update the min
                if obs_best >= obs2_min_ai:
                    break

        if obs_best < obs2_min_ai:
            obs2_min_ai = obs_best

    if opp_mob == 0:
        return 0, 0

    return 255 - obs2_min_ai, opp_mob

def ai_eval_d2(board, pos, ai_side):
    """Evaluate AI move at pos using depth-2 minimax + α-β."""
    opp_side = 3 - ai_side
    new_board = apply_move(board, pos, ai_side)
    opp_best, opp_mob = opp_best_score_d2(new_board, opp_side, ai_side)
    ai_mob = count_mobility(new_board, ai_side)
    return POS_WEIGHT[pos] + (255 - opp_best) + (ai_mob - opp_mob + 64)

def ai_choose_move(board, side):
    """Choose best move for side using depth-2. Returns pos or -1 if no moves."""
    best_score = -1
    best_pos = -1
    for pos in range(64):
        if count_flips(board, pos, side) > 0:
            score = ai_eval_d2(board, pos, side)
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
            pos = ai_choose_move(board, current)
            if mode == 3:
                print(f"{'AI(X)' if current == BLACK else 'AI(O)'} moves to {pos_to_str(pos)}")
            else:
                print(f"AI moves to {pos_to_str(pos)}")

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

def main():
    while True:
        mode = choose_mode()
        play_game(mode)
        print("\nr:Retry or q:Quit ? ", end='')
        if input().strip().lower() == 'q':
            print("\nBye.")
            break

if __name__ == '__main__':
    main()
