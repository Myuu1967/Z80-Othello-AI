"""
POS_WEIGHT GA 最適化 (RFCT150 評価関数 × half_all ウェイト版)

評価関数 (half_all ウェイト):
  EARLY (empty >= 44): pos_diff + mob×4 + stable×4  - stone×4
  MID   (empty >= 18): pos_diff + mob×4 + stable×8  - stone×2
  LATE  (empty <  18): (stone_diff + stable_diff) × 100  [RFCT150 LATE式]

深さ切替 (RFCT150 相当):
  empty <  EG_THRESHOLD(12) → 終盤完全読み (negamax_eg, POS_WEIGHT は move ordering のみ)
  empty <  D3_THRESHOLD(20) → depth-3
  empty >= D3_THRESHOLD(20) → depth-2

初期集団:
  GA_RFCT100 (現行 RFCT150 POS_WEIGHT_D3)
  GA_D2S     (現行 RFCT150 POS_WEIGHT_D2)
  GA_D3      (旧 depth-3 最適値)
  + ランダム摂動個体

使い方:
  cd python
  python optimize_weights_rfct150.py > result_rfct150.txt 2>&1

所要時間目安: 60〜90 分
"""

import random
import time
import othello_mm3_ab as oth

# =========================================================
# 設定
# =========================================================
D3_THRESHOLD  = 20
EG_THRESHOLD  = 12
MID_GAME      = 18

POP_SIZE      = 12
N_ELITE       = 4
N_GAMES       = 3      # GA 世代評価（粗いフィルタ）
N_GAMES_FINAL = 10     # 最終トーナメント
DEPTH_D2      = 2
DEPTH_D3      = 3
GENERATIONS   = 20
MUT_RATE      = 0.3
MUT_DELTA     = 15
PARAM_MIN     = -80
PARAM_MAX     = 255
RANDOM_SEED   = 42

# =========================================================
# 評価関数 (half_all ウェイト + RFCT150 LATE式)
# =========================================================
def eval_half_all(board, side):
    empty = board.count(oth.EMPTY)
    opp   = 3 - side

    # LATE: (stone + stable) × 100
    if empty < MID_GAME:
        x = board.count(oth.BLACK)
        o = board.count(oth.WHITE)
        stone_diff  = (x - o) if side == oth.BLACK else (o - x)
        my_s  = oth.count_stable_stones(board, side)
        opp_s = oth.count_stable_stones(board, opp)
        return (stone_diff + (my_s - opp_s)) * 100

    my_pos  = sum(oth.POS_WEIGHT[i] for i in range(64) if board[i] == side)
    opp_pos = sum(oth.POS_WEIGHT[i] for i in range(64) if board[i] == opp)
    pos_diff    = my_pos - opp_pos
    mob_diff    = oth.count_mobility(board, side) - oth.count_mobility(board, opp)
    my_s        = oth.count_stable_stones(board, side)
    opp_s       = oth.count_stable_stones(board, opp)
    stable_diff = my_s - opp_s
    x = board.count(oth.BLACK)
    o = board.count(oth.WHITE)
    stone_diff  = (x - o) if side == oth.BLACK else (o - x)

    if empty >= 44:  # EARLY
        return pos_diff + mob_diff * 4 + stable_diff * 4 - stone_diff * 4
    else:            # MID
        return pos_diff + mob_diff * 4 + stable_diff * 8 - stone_diff * 2

oth.eval_board = eval_half_all

# =========================================================
# 10パラメータ ↔ 64要素テーブル 変換
# =========================================================
COORD_TO_IDX = {
    (0,0): 0, (0,1): 1, (0,2): 2, (0,3): 3,
    (1,1): 4, (1,2): 5, (1,3): 6,
    (2,2): 7, (2,3): 8,
    (3,3): 9,
}
PARAM_NAMES = [
    'corner', 'c_sq', 'edge_near', 'edge_ctr',
    'x_sq',   'near_x', 'inner_edge',
    'inner',  'inner2', 'center',
]

def params_to_table(params):
    table = [0] * 64
    for pos in range(64):
        r = min(pos // 8, 7 - pos // 8)
        c = min(pos % 8,  7 - pos % 8)
        if r > c:
            r, c = c, r
        table[pos] = params[COORD_TO_IDX[(r, c)]]
    return table

def table_to_params(table):
    rep = [(0,0),(0,1),(0,2),(0,3),(1,1),(1,2),(1,3),(2,2),(2,3),(3,3)]
    return [table[r*8+c] for r,c in rep]

# 既知の良好値
GA_RFCT100_PARAMS = [157, -12,  2,  5, -49, -16,  -4, -19, -15, -24]  # 現行 POS_WEIGHT_D3
GA_D2S_PARAMS     = [114,  -5,-16, -7, -54, -16,   7,   6,   2, -12]  # 現行 POS_WEIGHT_D2
GA_D3_PARAMS      = [ 66, -32, -1, 44, -45,  22,   1,  10,  23, -29]  # 旧 depth-3

# =========================================================
# 1ゲーム実行 (RFCT150 相当)
# =========================================================
def play_one_game(black_table, white_table):
    board      = oth.make_board()
    current    = oth.BLACK
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
        tbl = black_table if current == oth.BLACK else white_table
        oth.POS_WEIGHT = tbl
        empty = board.count(oth.EMPTY)
        if empty < EG_THRESHOLD:
            pos, _ = oth.ai_choose_move_eg(board, current)
        else:
            depth = DEPTH_D3 if empty < D3_THRESHOLD else DEPTH_D2
            oth.eval_board = eval_half_all
            pos, _ = oth.ai_choose_move(board, current, depth=depth)
        if pos < 0:
            break
        board = oth.apply_move(board, pos, current)
        if board.count(oth.EMPTY) == 0:
            break
        current = 3 - current
    return board.count(oth.BLACK), board.count(oth.WHITE)

# =========================================================
# 評価・トーナメント
# =========================================================
def evaluate(params, ref_params, n_games=N_GAMES):
    table     = params_to_table(params)
    ref_table = params_to_table(ref_params)
    wins = 0
    total_margin = 0
    for i in range(n_games):
        if i % 2 == 0:
            b, o = play_one_game(table, ref_table)
            margin = b - o
            if margin > 0: wins += 1
        else:
            b, o = play_one_game(ref_table, table)
            margin = o - b
            if margin > 0: wins += 1
        total_margin += margin
    return (wins, total_margin)

def tournament(candidates, n_games=N_GAMES_FINAL):
    n = len(candidates)
    wins = [0] * n
    total_pairs = n * (n - 1) // 2
    done = 0
    t0 = time.time()
    for i in range(n):
        for j in range(i + 1, n):
            ti = params_to_table(candidates[i])
            tj = params_to_table(candidates[j])
            for k in range(n_games):
                if k % 2 == 0:
                    b, o = play_one_game(ti, tj)
                    if b > o:   wins[i] += 1
                    elif o > b: wins[j] += 1
                else:
                    b, o = play_one_game(tj, ti)
                    if o > b:   wins[i] += 1
                    elif b > o: wins[j] += 1
            done += 1
            elapsed = time.time() - t0
            remain  = elapsed / done * (total_pairs - done) if done > 0 else 0
            print(f"  [{done}/{total_pairs}] {i+1}vs{j+1}: "
                  f"累計{wins[i]}-{wins[j]}  残り約{remain/60:.1f}分", end='\r')
    print()
    return wins

# =========================================================
# GA
# =========================================================
def random_individual(base=GA_RFCT100_PARAMS):
    return [max(PARAM_MIN, min(PARAM_MAX,
            v + random.randint(-40, 40))) for v in base]

def crossover(a, b):
    return [random.choice([a[i], b[i]]) for i in range(len(a))]

def mutate(params):
    result = params[:]
    for i in range(len(result)):
        if random.random() < MUT_RATE:
            result[i] = max(PARAM_MIN, min(PARAM_MAX,
                            result[i] + random.randint(-MUT_DELTA, MUT_DELTA)))
    return result

def print_table(params):
    table = params_to_table(params)
    labels = 'ABCDEFGH'
    print(f"  ;     {'   '.join(labels)}")
    for row in range(8):
        vals = ', '.join(f"{table[row*8+col]:4d}" for col in range(8))
        print(f"  DEFB  {vals}  ; {row+1}")

# =========================================================
# メイン
# =========================================================
def run_ga():
    random.seed(RANDOM_SEED)
    print("=" * 65)
    print("GA POS_WEIGHT 最適化 (RFCT150 × half_all eval)")
    print("  EARLY: pos + mob×4 + stable×4  - stone×4")
    print("  MID  : pos + mob×4 + stable×8  - stone×2")
    print("  LATE : (stone + stable) × 100")
    print(f"  D3={D3_THRESHOLD}  EG={EG_THRESHOLD}  MID={MID_GAME}")
    print("=" * 65)
    print(f"個体数={POP_SIZE}, エリート={N_ELITE}, "
          f"GA評価={N_GAMES}g, 最終={N_GAMES_FINAL}g, 世代={GENERATIONS}")
    print(f"GA_RFCT100: {GA_RFCT100_PARAMS}  [現行 POS_WEIGHT_D3]")
    print(f"GA_D2S    : {GA_D2S_PARAMS}  [現行 POS_WEIGHT_D2]")
    print(f"GA_D3     : {GA_D3_PARAMS}  [旧 depth-3]")
    print()

    # 初期集団: 既知良好値 3種 + ランダム摂動
    population = (
        [GA_RFCT100_PARAMS[:], GA_D2S_PARAMS[:], GA_D3_PARAMS[:]]
        + [random_individual() for _ in range(POP_SIZE - 3)]
    )

    best_ever_score  = (-1, -999999)
    best_ever_params = None
    baseline_params  = GA_RFCT100_PARAMS[:]
    hall_of_fame     = [GA_RFCT100_PARAMS[:], GA_D2S_PARAMS[:], GA_D3_PARAMS[:]]
    t_start = time.time()

    for gen in range(GENERATIONS):
        t_gen = time.time()

        scored = [(evaluate(ind, baseline_params), ind) for ind in population]
        scored.sort(key=lambda x: x[0], reverse=True)

        best_score, best_params = scored[0]
        avg_wins   = sum(s[0] for s, _ in scored) / len(scored)
        avg_margin = sum(s[1] for s, _ in scored) / len(scored)

        if best_score > best_ever_score:
            best_ever_score  = best_score
            best_ever_params = best_params[:]
            baseline_params  = best_params[:]
            hall_of_fame.append(best_params[:])
            marker = " ★新記録"
        else:
            marker = ""

        gen_time = time.time() - t_gen
        remain   = gen_time * (GENERATIONS - gen - 1)
        print(f"世代 {gen+1:3d}/{GENERATIONS}  "
              f"最高={best_score[0]}/{N_GAMES}(石差{best_score[1]:+d})  "
              f"平均勝={avg_wins:.1f} 石差={avg_margin:.0f}  "
              f"世代時間={gen_time:.0f}s  残り約{remain/60:.0f}分{marker}")
        if marker:
            print(f"  パラメータ: {best_params}")

        elites   = [ind for _, ind in scored[:N_ELITE]]
        next_gen = elites[:]
        while len(next_gen) < POP_SIZE:
            p1, p2 = random.sample(elites, 2)
            next_gen.append(mutate(crossover(p1, p2)))
        population = next_gen

    total_time = time.time() - t_start
    print()
    print("=" * 65)
    print(f"GA完了  合計: {total_time/60:.1f}分  殿堂候補: {len(hall_of_fame)}種")
    print()

    print("=" * 65)
    print(f"精密トーナメント ({N_GAMES_FINAL}ゲーム/ペア)")
    print()
    t_tourn = time.time()
    win_counts = tournament(hall_of_fame, n_games=N_GAMES_FINAL)
    print(f"トーナメント完了  所要: {(time.time()-t_tourn)/60:.1f}分")
    print()

    ranked   = sorted(zip(win_counts, hall_of_fame), key=lambda x: -x[0])
    max_wins = len(hall_of_fame) * (len(hall_of_fame) - 1) * N_GAMES_FINAL // 2

    print("=" * 65)
    print("最終ランキング")
    print("=" * 65)
    for rank, (w, p) in enumerate(ranked, 1):
        label = " ← 優勝" if rank == 1 else ""
        tag = ""
        if p == GA_RFCT100_PARAMS: tag = " [GA_RFCT100/現行D3]"
        elif p == GA_D2S_PARAMS:   tag = " [GA_D2S/現行D2]"
        elif p == GA_D3_PARAMS:    tag = " [GA_D3/旧]"
        print(f"  {rank}位  {w}勝/{max_wins}  {p}{tag}{label}")

    best_params = ranked[0][1]
    print()
    print("--- 優勝テーブル Z80 DEFB ---")
    print_table(best_params)
    print()
    print(f"  {'名前':12s}  {'優勝':>5}  {'GA_RFCT100':>10}  {'GA_D2S':>7}")
    for name, val, r100, d2s in zip(
            PARAM_NAMES, best_params, GA_RFCT100_PARAMS, GA_D2S_PARAMS):
        diff = val - r100
        sign = f"+{diff}" if diff >= 0 else str(diff)
        print(f"  {name:12s}: {val:5d}  (RFCT100={r100:4d} {sign:>4s}, D2S={d2s:4d})")

    return best_params

if __name__ == '__main__':
    run_ga()
