"""
遺伝的アルゴリズムで POS_WEIGHT テーブルを最適化する（depth-2 signed 版）

depth-2 AI同士で対戦して勝率を評価する。
符号付き重みを許容し、GA_D3優勝値も初期集団に含める。
depth-2 に最適な signed POS_WEIGHT を求めることが目的。

使い方:
  python optimize_weights_d2signed.py > ga_d2signed_result.txt
"""

import random
import time
import othello_mm3_ab as oth

# =========================================================
# 設定
# =========================================================
POP_SIZE       = 20    # 個体数
N_ELITE        = 5     # エリート（次世代に引き継ぐ上位個体数）
N_GAMES        = 5     # GA評価ゲーム数（粗いフィルタ）
N_GAMES_FINAL  = 20    # 最終トーナメントのゲーム数（精密評価）
DEPTH          = 2     # ★ depth-2
GENERATIONS    = 30    # 世代数
MUT_RATE       = 0.3   # 各パラメータの突然変異確率
MUT_DELTA      = 15    # 突然変異の最大変化幅

PARAM_MIN = -60
PARAM_MAX = 255

RANDOM_SEED = 123      # GA_D3 と異なるシードで多様性を確保

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
    'x_sq', 'near_x', 'inner_edge',
    'inner', 'inner2', 'center',
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

V1_PARAMS  = table_to_params(oth.POS_WEIGHT_V1)
V2_PARAMS  = [120, -20, 20, 10, -40, -5, 1, 15, 5, 3]
GA_D2_PARAMS   = [128, 3, 17, 30, 1, 36, 15, 18, 29, 1]     # depth-2 正値のみ (2026-04-22)
GA_D3_PARAMS   = [66, -32, -1, 44, -45, 22, 1, 10, 23, -29] # depth-3 signed  (2026-04-26)

# =========================================================
# 対戦・評価
# =========================================================
def play_one_game(black_table, white_table, depth=DEPTH):
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
        oth.POS_WEIGHT = black_table if current == oth.BLACK else white_table
        pos, _ = oth.ai_choose_move(board, current, depth=depth)
        board = oth.apply_move(board, pos, current)
        if board.count(oth.EMPTY) == 0:
            break
        current = 3 - current
    return board.count(oth.BLACK), board.count(oth.WHITE)

def evaluate(params, ref_params, n_games=N_GAMES, depth=DEPTH):
    table     = params_to_table(params)
    ref_table = params_to_table(ref_params)
    wins = 0
    total_margin = 0
    for i in range(n_games):
        if i % 2 == 0:
            b, o = play_one_game(table, ref_table, depth)
            margin = b - o
            if margin > 0:
                wins += 1
        else:
            b, o = play_one_game(ref_table, table, depth)
            margin = o - b
            if margin > 0:
                wins += 1
        total_margin += margin
    return (wins, total_margin)

def tournament(candidates, n_games=N_GAMES_FINAL, depth=DEPTH):
    n = len(candidates)
    wins = [0] * n
    total_pairs = n * (n - 1) // 2
    done = 0
    t0 = time.time()
    for i in range(n):
        for j in range(i + 1, n):
            table_i = params_to_table(candidates[i])
            table_j = params_to_table(candidates[j])
            for k in range(n_games):
                if k % 2 == 0:
                    b, o = play_one_game(table_i, table_j, depth)
                    if b > o:
                        wins[i] += 1
                    elif o > b:
                        wins[j] += 1
                else:
                    b, o = play_one_game(table_j, table_i, depth)
                    if o > b:
                        wins[i] += 1
                    elif b > o:
                        wins[j] += 1
            done += 1
            elapsed = time.time() - t0
            remain  = elapsed / done * (total_pairs - done) if done > 0 else 0
            print(f"  [{done}/{total_pairs}] {i+1}vs{j+1}: "
                  f"累計{wins[i]}-{wins[j]}  残り約{remain/60:.1f}分", end='\r')
    print()
    return wins

# =========================================================
# 遺伝的アルゴリズム
# =========================================================
def random_individual():
    """V2パラメータを中心にランダムにばらした初期個体（負値許容）"""
    return [max(PARAM_MIN, min(PARAM_MAX, v + random.randint(-40, 40))) for v in V2_PARAMS]

def crossover(a, b):
    return [random.choice([a[i], b[i]]) for i in range(len(a))]

def mutate(params):
    result = params[:]
    for i in range(len(result)):
        if random.random() < MUT_RATE:
            result[i] = max(PARAM_MIN, min(PARAM_MAX, result[i] + random.randint(-MUT_DELTA, MUT_DELTA)))
    return result

def print_table(params):
    table = params_to_table(params)
    labels = 'ABCDEFGH'
    print(f"  ;     {'   '.join(labels)}")
    for row in range(8):
        vals = ', '.join(f"{table[row*8+col]:3d}" for col in range(8))
        print(f"  DEFB  {vals}  ; {row+1}")

# =========================================================
# メイン
# =========================================================
def run_ga():
    random.seed(RANDOM_SEED)
    print("=" * 60)
    print("遺伝的アルゴリズム POS_WEIGHT 最適化 (depth-2 signed)")
    print("=" * 60)
    print(f"個体数={POP_SIZE}, エリート={N_ELITE}, "
          f"GA評価ゲーム={N_GAMES}, 最終トーナメント={N_GAMES_FINAL}ゲーム, "
          f"depth={DEPTH}, 世代={GENERATIONS}")
    print(f"V2      パラメータ: {V2_PARAMS}")
    print(f"GA_D2   パラメータ（depth-2 正値, 前回）: {GA_D2_PARAMS}")
    print(f"GA_D3   パラメータ（depth-3 signed, 前回）: {GA_D3_PARAMS}")
    print()

    # 初期集団: V2 + GA_D2 + GA_D3 + ランダム個体
    population = (
        [V2_PARAMS[:], GA_D2_PARAMS[:], GA_D3_PARAMS[:]]
        + [random_individual() for _ in range(POP_SIZE - 3)]
    )

    best_ever_score  = (-1, -999999)
    best_ever_params = None
    baseline_params  = V2_PARAMS[:]
    hall_of_fame     = [V2_PARAMS[:], GA_D2_PARAMS[:], GA_D3_PARAMS[:]]
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
    print("=" * 60)
    print(f"GA完了  合計時間: {total_time/60:.1f}分")
    print(f"殿堂入り候補数: {len(hall_of_fame)}")
    print()

    print("=" * 60)
    print(f"精密トーナメント開始 ({N_GAMES_FINAL}ゲーム/ペア, depth={DEPTH})")
    print(f"候補数: {len(hall_of_fame)}  ペア数: {len(hall_of_fame)*(len(hall_of_fame)-1)//2}")
    print()
    t_tourn = time.time()
    win_counts = tournament(hall_of_fame, n_games=N_GAMES_FINAL)
    tourn_time = time.time() - t_tourn
    print(f"トーナメント完了  所要時間: {tourn_time/60:.1f}分")
    print()

    ranked = sorted(zip(win_counts, hall_of_fame), key=lambda x: -x[0])
    print("=" * 60)
    print("最終ランキング")
    print("=" * 60)
    max_wins = len(hall_of_fame) * (len(hall_of_fame) - 1) * N_GAMES_FINAL // 2
    for rank, (w, p) in enumerate(ranked, 1):
        label = " ← 優勝" if rank == 1 else ""
        tag = ""
        if p == V2_PARAMS:    tag = " [V2]"
        elif p == GA_D2_PARAMS: tag = " [GA_D2]"
        elif p == GA_D3_PARAMS: tag = " [GA_D3]"
        print(f"  {rank}位  {w}勝/{max_wins}  {p}{tag}{label}")

    best_params = ranked[0][1]
    print()
    print("--- 優勝テーブル Z80 DEFB ---")
    print_table(best_params)
    print()
    print("--- 各マス分類の値 ---")
    print(f"  {'名前':12s}  {'優勝':>5}  {'V2':>5}  {'GA_D2':>5}  {'GA_D3':>5}  {'V1':>5}")
    for name, val, v2, gd2, gd3, v1 in zip(
            PARAM_NAMES, best_params, V2_PARAMS, GA_D2_PARAMS, GA_D3_PARAMS, V1_PARAMS):
        diff = val - v2
        sign = f"+{diff}" if diff >= 0 else str(diff)
        print(f"  {name:12s}: {val:5d}  (V2={v2:5d} {sign:>4s}, GA_D2={gd2:3d}, GA_D3={gd3:4d}, V1={v1:3d})")

    return best_params

if __name__ == '__main__':
    run_ga()
