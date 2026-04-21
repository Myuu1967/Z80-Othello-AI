"""
AI vs AI 対戦速度計測
depth-3 α-β で N ゲーム対戦して 1ゲームあたりの時間を計測する
"""
import time
from othello_mm3_ab import make_board, get_legal_moves, apply_move, ai_choose_move

def play_one_game(depth=3):
    board = make_board()
    current = 1  # BLACK
    pass_count = 0
    moves = 0

    while True:
        legal = get_legal_moves(board, current)
        if not legal:
            pass_count += 1
            if pass_count >= 2:
                break
            current = 3 - current
            continue

        pass_count = 0
        pos, _ = ai_choose_move(board, current, depth=depth)
        board = apply_move(board, pos, current)
        moves += 1

        if board.count(0) == 0:
            break

        current = 3 - current

    b = board.count(1)
    o = board.count(2)
    return b, o, moves

def run_benchmark(n_games=10, depth=3):
    print(f"depth={depth}, {n_games}ゲーム計測中...")
    results = {'black': 0, 'white': 0, 'draw': 0}
    t_start = time.time()

    for i in range(n_games):
        b, o, moves = play_one_game(depth=depth)
        if b > o:
            results['black'] += 1
        elif o > b:
            results['white'] += 1
        else:
            results['draw'] += 1
        print(f"  game {i+1:3d}: X={b} O={o} ({moves}手)", flush=True)

    t_total = time.time() - t_start
    t_per_game = t_total / n_games

    print(f"\n--- 結果 ---")
    print(f"合計時間:        {t_total:.1f} 秒")
    print(f"1ゲームあたり:   {t_per_game:.2f} 秒")
    print(f"BLACK勝利: {results['black']} / WHITE勝利: {results['white']} / 引き分け: {results['draw']}")
    print(f"\n学習の参考:")
    print(f"  100ゲーム想定: {t_per_game * 100:.0f} 秒 ({t_per_game * 100 / 60:.1f} 分)")
    print(f"  1000ゲーム想定: {t_per_game * 1000:.0f} 秒 ({t_per_game * 1000 / 60:.1f} 分)")

if __name__ == '__main__':
    run_benchmark(n_games=10, depth=2)
