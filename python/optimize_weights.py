"""
遺伝的アルゴリズムで POS_WEIGHT テーブルを最適化する

オセロ盤は4重対称なので、64マスを10パラメータに圧縮して探索する。
depth-2 AI同士で対戦して勝率を評価し、世代を重ねて最適テーブルを求める。

使い方:
  python optimize_weights.py

出力:
  各世代の最高スコアとパラメータ
  最終的なZ80用DEFBテーブル
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
DEPTH          = 3     # 評価用探索深さ
GENERATIONS    = 30    # 世代数
MUT_RATE       = 0.3   # 各パラメータの突然変異確率
MUT_DELTA      = 15    # 突然変異の最大変化幅

# 負値を許容する範囲（Z80移植時は別途対応）
PARAM_MIN = -60
PARAM_MAX = 255

RANDOM_SEED = 42

# =========================================================
# 10パラメータ ↔ 64要素テーブル 変換
#
# オセロ盤の4重対称により、64マスは10種類に分類できる。
# (r, c) は正規化座標: r=min(row,7-row), c=min(col,7-col), r<=c
#
#   idx  (r,c)  代表マス  名前
#    0   (0,0)  A1        corner     (角)
#    1   (0,1)  B1,A2     c_sq       (C マス: 角隣の辺)
#    2   (0,2)  C1,A3     edge_near  (辺・角近く)
#    3   (0,3)  D1,A4     edge_ctr   (辺・中央寄り)
#    4   (1,1)  B2        x_sq       (X マス: 角斜め)
#    5   (1,2)  C2,B3     near_x     (X マス隣)
#    6   (1,3)  D2,B4     inner_edge (内側辺寄り)
#    7   (2,2)  C3        inner      (内側)
#    8   (2,3)  D3,C4     inner2     (内側2)
#    9   (3,3)  D4        center     (中央4マス)
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
    """10パラメータ → 64要素テーブル"""
    table = [0] * 64
    for pos in range(64):
        r = min(pos // 8, 7 - pos // 8)
        c = min(pos % 8,  7 - pos % 8)
        if r > c:
            r, c = c, r
        table[pos] = params[COORD_TO_IDX[(r, c)]]
    return table

def table_to_params(table):
    """64要素テーブル → 10パラメータ（代表マスから読む）"""
    rep = [(0,0),(0,1),(0,2),(0,3),(1,1),(1,2),(1,3),(2,2),(2,3),(3,3)]
    return [table[r*8+c] for r,c in rep]

# 現行 V1 テーブルの10パラメータ（正値のみ）
V1_PARAMS = table_to_params(oth.POS_WEIGHT_V1)

# V2 テーブル（負値あり、benchmark で V1/d2 に 80% 勝利確認済み）
V2_PARAMS = [120, -20, 20, 10, -40, -5, 1, 15, 5, 3]

# 前回 GA 最適化結果（2026-04-22, depth-2, 正値のみ）
GA_D2_PARAMS = [128, 3, 17, 30, 1, 36, 15, 18, 29, 1]

# =========================================================
# 対戦・評価
# =========================================================
def play_one_game(black_table, white_table, depth=DEPTH):
    """black_table を使う BLACK AI vs white_table を使う WHITE AI で1ゲーム"""
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
    """
    ref_params（基準AI）との対戦を行い (wins, total_margin) を返す。
    wins: 勝利数（主評価）
    total_margin: 全ゲームの石差合計（副評価、同勝利数の個体を区別する）
    先手・後手を均等に分けて対戦する。
    """
    table     = params_to_table(params)
    ref_table = params_to_table(ref_params)
    wins = 0
    total_margin = 0
    for i in range(n_games):
        if i % 2 == 0:          # 評価対象が先手(BLACK)
            b, o = play_one_game(table, ref_table, depth)
            margin = b - o
            if margin > 0:
                wins += 1
        else:                   # 評価対象が後手(WHITE)
            b, o = play_one_game(ref_table, table, depth)
            margin = o - b
            if margin > 0:
                wins += 1
        total_margin += margin
    return (wins, total_margin)

def tournament(candidates, n_games=N_GAMES_FINAL, depth=DEPTH):
    """
    candidates の総当たりトーナメント。
    各ペアで n_games 試合（先手・後手均等）。
    勝利数の合計で順位付け。
    """
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
    """各パラメータをランダムに親どちらかから選ぶ（一様交叉）"""
    return [random.choice([a[i], b[i]]) for i in range(len(a))]

def mutate(params):
    """各パラメータを確率 MUT_RATE で ±MUT_DELTA 以内でランダム変化（負値許容）"""
    result = params[:]
    for i in range(len(result)):
        if random.random() < MUT_RATE:
            result[i] = max(PARAM_MIN, min(PARAM_MAX, result[i] + random.randint(-MUT_DELTA, MUT_DELTA)))
    return result

def print_table(params):
    """パラメータをZ80 DEFB形式で表示"""
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
    print("遺伝的アルゴリズム POS_WEIGHT 最適化")
    print("=" * 60)
    print(f"個体数={POP_SIZE}, エリート={N_ELITE}, "
          f"GA評価ゲーム={N_GAMES}, 最終トーナメント={N_GAMES_FINAL}ゲーム, "
          f"depth={DEPTH}, 世代={GENERATIONS}")
    print(f"V2 パラメータ（ベースライン）: {V2_PARAMS}")
    print(f"GA_D2 パラメータ（前回結果）: {GA_D2_PARAMS}")
    print()

    # 初期集団: V2 + 前回GA結果 + ランダム個体
    population = [V2_PARAMS[:], GA_D2_PARAMS[:]] + [random_individual() for _ in range(POP_SIZE - 2)]

    best_ever_score  = (-1, -999999)
    best_ever_params = None
    # 動的ベースライン: 最初はV2、毎世代更新
    baseline_params  = V2_PARAMS[:]
    # 殿堂入り: ★新記録を出した全候補（最終トーナメント用）
    hall_of_fame     = [V2_PARAMS[:]]
    t_start = time.time()

    for gen in range(GENERATIONS):
        t_gen = time.time()

        # 全個体を評価（基準: 動的ベースライン）
        # evaluate() は (wins, total_margin) タプルを返す
        scored = [(evaluate(ind, baseline_params), ind) for ind in population]
        scored.sort(key=lambda x: x[0], reverse=True)  # タプル比較: wins優先→石差

        best_score, best_params = scored[0]
        avg_wins   = sum(s[0] for s, _ in scored) / len(scored)
        avg_margin = sum(s[1] for s, _ in scored) / len(scored)

        if best_score > best_ever_score:
            best_ever_score  = best_score
            best_ever_params = best_params[:]
            # ベースラインを更新して選択圧を維持
            baseline_params  = best_params[:]
            hall_of_fame.append(best_params[:])
            marker = " ★新記録"
        else:
            marker = ""

        gen_time   = time.time() - t_gen
        total_time = time.time() - t_start
        remain     = gen_time * (GENERATIONS - gen - 1)

        print(f"世代 {gen+1:3d}/{GENERATIONS}  "
              f"最高={best_score[0]}/{N_GAMES}(石差{best_score[1]:+d})  "
              f"平均勝={avg_wins:.1f} 石差={avg_margin:.0f}  "
              f"世代時間={gen_time:.0f}s  残り約{remain/60:.0f}分{marker}")
        if marker:
            print(f"  パラメータ: {best_params}")

        # 次世代生成
        elites   = [ind for _, ind in scored[:N_ELITE]]
        next_gen = elites[:]
        while len(next_gen) < POP_SIZE:
            p1, p2 = random.sample(elites, 2)
            next_gen.append(mutate(crossover(p1, p2)))
        population = next_gen

    # GA完了
    total_time = time.time() - t_start
    print()
    print("=" * 60)
    print(f"GA完了  合計時間: {total_time/60:.1f}分")
    print(f"殿堂入り候補数: {len(hall_of_fame)}")
    print()

    # =========================================================
    # 精密トーナメント（殿堂入り候補の総当たり）
    # =========================================================
    print("=" * 60)
    print(f"精密トーナメント開始 ({N_GAMES_FINAL}ゲーム/ペア)")
    print(f"候補数: {len(hall_of_fame)}  ペア数: {len(hall_of_fame)*(len(hall_of_fame)-1)//2}")
    # 候補数が多すぎる場合はGA最終世代エリートも追加して上位に絞る
    # （現状の設定では候補数は多くて~15程度なので全数でOK）
    print()
    t_tourn = time.time()
    win_counts = tournament(hall_of_fame, n_games=N_GAMES_FINAL)
    tourn_time = time.time() - t_tourn
    print(f"トーナメント完了  所要時間: {tourn_time/60:.1f}分")
    print()

    # 結果表示
    ranked = sorted(zip(win_counts, hall_of_fame), key=lambda x: -x[0])
    print("=" * 60)
    print("最終ランキング")
    print("=" * 60)
    max_wins = len(hall_of_fame) * (len(hall_of_fame) - 1) * N_GAMES_FINAL // 2
    for rank, (w, p) in enumerate(ranked, 1):
        label = " ← 優勝" if rank == 1 else ""
        print(f"  {rank}位  {w}勝/{max_wins}  {p}{label}")

    best_params = ranked[0][1]
    print()
    print("--- 優勝テーブル Z80 DEFB ---")
    print_table(best_params)
    print()
    print("--- 各マス分類の値 ---")
    print(f"  {'名前':12s}  {'優勝':>5}  {'V2':>5}  {'GA_D2':>5}  {'V1':>5}")
    for name, val, v2, gd2, v1 in zip(PARAM_NAMES, best_params, V2_PARAMS, GA_D2_PARAMS, V1_PARAMS):
        diff = val - v2
        sign = f"+{diff}" if diff >= 0 else str(diff)
        print(f"  {name:12s}: {val:5d}  (V2={v2:5d} {sign:>4s}, GA_D2={gd2:3d}, V1={v1:3d})")

    return best_params

if __name__ == '__main__':
    run_ga()
