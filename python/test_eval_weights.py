"""
序中盤 mob/stable/stone 重み比較テスト (RFCT150.ASM 相当)

評価関数フェーズ:
  EARLY (empty >= 44): pos_diff + mob×mob_e + stable×stb_e - stone×stn_e
  MID   (empty >= 18): pos_diff + mob×mob_m + stable×stb_m - stone×stn_m
  LATE  (empty <  18): (stone_diff + stable_diff) × 100  [固定・変更なし]

深さ切替:
  empty <  EG_THRESHOLD(12) → 終盤完全読み (negamax_eg)
  empty <  D3_THRESHOLD(20) → depth-3
  empty >= D3_THRESHOLD(20) → depth-2

使い方:
  python test_eval_weights.py [n_games]
  n_games: 各対戦の片道ゲーム数（先後入替あり → 合計 n_games*2）
           省略時 = 20
"""

import sys
import othello_mm3_ab as oth
from play_vs_ai import POS_WEIGHT_D2, POS_WEIGHT_D3

# --- AI 設定 (RFCT150.ASM 実機値) ---
D3_THRESHOLD = 20   # RFCT120/150.ASM と同値
EG_THRESHOLD = 12   # Python テスト用完全読み閾値
MID_GAME     = 18   # LATE/MID 境界 (RFCT120.ASM MID_GAME EQU 18)

# =========================================================
# 比較する重みセット
#   mob_e/stb_e/stn_e : EARLY フェーズ (empty >= 44)
#   mob_m/stb_m/stn_m : MID   フェーズ (18 <= empty < 44)
# =========================================================
CONFIGS = {
    # 現行 RFCT120/150
    'current':
        dict(mob_e=8, stb_e= 8, stn_e=8,
             mob_m=8, stb_m=16, stn_m=4),

    # mob/stable を半分に
    'half_ms':
        dict(mob_e=4, stb_e= 4, stn_e=8,
             mob_m=4, stb_m= 8, stn_m=4),

    # mob/stable をさらに削減（pos_diff 主体）
    'low_ms':
        dict(mob_e=2, stb_e= 2, stn_e=8,
             mob_m=2, stb_m= 4, stn_m=4),

    # stone ペナルティも削減
    'half_all':
        dict(mob_e=4, stb_e= 4, stn_e=4,
             mob_m=4, stb_m= 8, stn_m=2),

    # pos_diff ほぼ単独（極端ケース確認用）
    'pos_only':
        dict(mob_e=1, stb_e= 1, stn_e=2,
             mob_m=1, stb_m= 2, stn_m=1),
}

# =========================================================
# 評価関数ファクトリ
# =========================================================
def make_eval(mob_e, stb_e, stn_e, mob_m, stb_m, stn_m):
    def _eval(board, side):
        empty = board.count(oth.EMPTY)
        opp   = 3 - side
        # LATE: stone+stable で固定
        if empty < MID_GAME:
            x = board.count(oth.BLACK)
            o = board.count(oth.WHITE)
            stone_diff  = (x - o) if side == oth.BLACK else (o - x)
            my_s   = oth.count_stable_stones(board, side)
            opp_s  = oth.count_stable_stones(board, opp)
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
            return pos_diff + mob_diff * mob_e + stable_diff * stb_e - stone_diff * stn_e
        else:            # MID
            return pos_diff + mob_diff * mob_m + stable_diff * stb_m - stone_diff * stn_m

    return _eval


# =========================================================
# AI 着手 (RFCT150 相当)
# =========================================================
def ai_move(board, side, eval_fn):
    empty = board.count(oth.EMPTY)
    if empty < EG_THRESHOLD:
        # 終盤完全読み: pos_weight は move ordering にのみ使用
        oth.POS_WEIGHT = POS_WEIGHT_D3
        pos, score = oth.ai_choose_move_eg(board, side)
        return pos, score
    depth = 3 if empty < D3_THRESHOLD else 2
    oth.POS_WEIGHT = POS_WEIGHT_D3 if depth == 3 else POS_WEIGHT_D2
    oth.eval_board = eval_fn
    pos, score = oth.ai_choose_move(board, side, depth=depth)
    return pos, score


# =========================================================
# 1 ゲーム実行
# =========================================================
def play_one(eval_black, eval_white):
    board = oth.make_board()
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
        eval_fn = eval_black if current == oth.BLACK else eval_white
        pos, _ = ai_move(board, current, eval_fn)
        if pos < 0:
            break
        board = oth.apply_move(board, pos, current)
        if board.count(oth.EMPTY) == 0:
            break
        current = 3 - current
    return oth.count_stones(board)  # (x, o)


# =========================================================
# 対戦ラウンド (先後入替あり)
# =========================================================
def run_match(n, name_a, name_b, eval_a, eval_b, verbose=True):
    win_a = win_b = draw = 0
    for i in range(n):
        # A=先手(X), B=後手(O)
        x, o = play_one(eval_a, eval_b)
        if x > o:   win_a += 1
        elif o > x: win_b += 1
        else:       draw  += 1
        if verbose:
            r = f"{name_a}勝" if x > o else (f"{name_b}勝" if o > x else "引分")
            print(f"  [{i*2+1:3d}] {name_a}=先手 X:{x:2d} O:{o:2d}  → {r}")

        # B=先手(X), A=後手(O)
        x, o = play_one(eval_b, eval_a)
        if x > o:   win_b += 1
        elif o > x: win_a += 1
        else:       draw  += 1
        if verbose:
            r = f"{name_b}勝" if x > o else (f"{name_a}勝" if o > x else "引分")
            print(f"  [{i*2+2:3d}] {name_b}=先手 X:{x:2d} O:{o:2d}  → {r}")

    return win_a, win_b, draw


# =========================================================
# メイン
# =========================================================
def config_label(cfg):
    return (f"mob×{cfg['mob_e']}/{cfg['mob_m']} "
            f"stb×{cfg['stb_e']}/{cfg['stb_m']} "
            f"stn×{cfg['stn_e']}/{cfg['stn_m']}")


if __name__ == '__main__':
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    total_games = n * 2

    evals = {k: make_eval(**v) for k, v in CONFIGS.items()}

    print(f"RFCT150 序中盤ウェイト比較テスト")
    print(f"D3_THRESHOLD={D3_THRESHOLD}  EG_THRESHOLD={EG_THRESHOLD}  MID_GAME={MID_GAME}")
    print(f"各対戦 {total_games} ゲーム（先後 {n} 局ずつ）")
    print("=" * 60)

    summary = []
    baseline = 'current'
    challengers = [k for k in CONFIGS if k != baseline]

    for ch in challengers:
        cfg_a = CONFIGS[baseline]
        cfg_b = CONFIGS[ch]
        print(f"\n【{baseline}】 vs 【{ch}】")
        print(f"  {baseline} : {config_label(cfg_a)}")
        print(f"  {ch:8s}: {config_label(cfg_b)}")
        print()

        wa, wb, dr = run_match(n, baseline, ch, evals[baseline], evals[ch])
        pct_a = wa / total_games * 100
        pct_b = wb / total_games * 100

        print(f"\n  結果: {baseline}={wa}勝({pct_a:.0f}%)  {ch}={wb}勝({pct_b:.0f}%)  Draw={dr}")
        summary.append((baseline, ch, wa, wb, dr, total_games))

    print("\n" + "=" * 60)
    print("サマリー")
    print(f"  {'対戦':30s}  {'current':>8}  {'挑戦者':>8}  {'Draw':>5}")
    for a, b, wa, wb, dr, tot in summary:
        winner = f"← {a}" if wa > wb else (f"← {b}" if wb > wa else "引分")
        print(f"  {a} vs {b:12s}  {wa:>5}/{tot}   {wb:>5}/{tot}   {dr:>4}  {winner}")
