"""
序中盤ウェイト 第2回精密テスト (RFCT150.ASM 相当)
新ベースライン: half_all (mob×4/4, stb×4/8, stn×4/2)

前回の発見: stone ペナルティ削減が最大の改善要因
今回の探索:
  1. stone ペナルティ変動 (stn_e/stn_m を 0～8/4 で掃引)
  2. mob 変動 (mob_e/mob_m を 2～8 で掃引)
  3. stable 変動 (stb_e/stb_m を 2/4～8/16 で掃引)

使い方:
  python test_eval_weights2.py [n_games]
  n_games: 片道ゲーム数（先後入替あり → 合計 n_games*2）
           省略時 = 20
"""

import sys
import othello_mm3_ab as oth
from play_vs_ai import POS_WEIGHT_D2, POS_WEIGHT_D3

D3_THRESHOLD = 20
EG_THRESHOLD = 12
MID_GAME     = 18

# =========================================================
# 比較する重みセット
# half_all を新ベースラインとして周辺を探索
# =========================================================
BASELINE = 'half_all'

CONFIGS = {
    # ベースライン (前回優勝)
    'half_all':   dict(mob_e=4, stb_e= 4, stn_e=4, mob_m=4, stb_m= 8, stn_m=2),

    # --- stone ペナルティ変動 (mob/stableはhalf_all固定) ---
    'stn_0':      dict(mob_e=4, stb_e= 4, stn_e=0, mob_m=4, stb_m= 8, stn_m=0),  # ペナルティなし
    'stn_2_1':    dict(mob_e=4, stb_e= 4, stn_e=2, mob_m=4, stb_m= 8, stn_m=1),  # さらに半減
    'stn_6_3':    dict(mob_e=4, stb_e= 4, stn_e=6, mob_m=4, stb_m= 8, stn_m=3),  # やや増
    'stn_8_4':    dict(mob_e=4, stb_e= 4, stn_e=8, mob_m=4, stb_m= 8, stn_m=4),  # current同等

    # --- mob 変動 (stb/stnはhalf_all固定) ---
    'mob_2':      dict(mob_e=2, stb_e= 4, stn_e=4, mob_m=2, stb_m= 8, stn_m=2),
    'mob_6':      dict(mob_e=6, stb_e= 4, stn_e=4, mob_m=6, stb_m= 8, stn_m=2),
    'mob_8':      dict(mob_e=8, stb_e= 4, stn_e=4, mob_m=8, stb_m= 8, stn_m=2),

    # --- stable 変動 (mob/stnはhalf_all固定) ---
    'stb_2_4':    dict(mob_e=4, stb_e= 2, stn_e=4, mob_m=4, stb_m= 4, stn_m=2),
    'stb_6_12':   dict(mob_e=4, stb_e= 6, stn_e=4, mob_m=4, stb_m=12, stn_m=2),
    'stb_8_16':   dict(mob_e=4, stb_e= 8, stn_e=4, mob_m=4, stb_m=16, stn_m=2),
}

# =========================================================
# 評価関数ファクトリ
# =========================================================
def make_eval(mob_e, stb_e, stn_e, mob_m, stb_m, stn_m):
    def _eval(board, side):
        empty = board.count(oth.EMPTY)
        opp   = 3 - side
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
        if empty >= 44:
            return pos_diff + mob_diff * mob_e + stable_diff * stb_e - stone_diff * stn_e
        else:
            return pos_diff + mob_diff * mob_m + stable_diff * stb_m - stone_diff * stn_m
    return _eval


# =========================================================
# AI 着手 (RFCT150 相当)
# =========================================================
def ai_move(board, side, eval_fn):
    empty = board.count(oth.EMPTY)
    if empty < EG_THRESHOLD:
        oth.POS_WEIGHT = POS_WEIGHT_D3
        pos, score = oth.ai_choose_move_eg(board, side)
        return pos, score
    depth = 3 if empty < D3_THRESHOLD else 2
    oth.POS_WEIGHT = POS_WEIGHT_D3 if depth == 3 else POS_WEIGHT_D2
    oth.eval_board = eval_fn
    pos, score = oth.ai_choose_move(board, side, depth=depth)
    return pos, score


def play_one(eval_black, eval_white):
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
        eval_fn = eval_black if current == oth.BLACK else eval_white
        pos, _ = ai_move(board, current, eval_fn)
        if pos < 0:
            break
        board = oth.apply_move(board, pos, current)
        if board.count(oth.EMPTY) == 0:
            break
        current = 3 - current
    return oth.count_stones(board)


def run_match(n, name_a, name_b, eval_a, eval_b):
    win_a = win_b = draw = 0
    for i in range(n):
        x, o = play_one(eval_a, eval_b)
        if x > o:   win_a += 1
        elif o > x: win_b += 1
        else:       draw  += 1
        x, o = play_one(eval_b, eval_a)
        if x > o:   win_b += 1
        elif o > x: win_a += 1
        else:       draw  += 1
    return win_a, win_b, draw


def config_label(cfg):
    return (f"mob×{cfg['mob_e']}/{cfg['mob_m']} "
            f"stb×{cfg['stb_e']}/{cfg['stb_m']} "
            f"stn×{cfg['stn_e']}/{cfg['stn_m']}")


# =========================================================
# メイン
# =========================================================
if __name__ == '__main__':
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    total = n * 2

    evals = {k: make_eval(**v) for k, v in CONFIGS.items()}
    base_eval = evals[BASELINE]
    base_cfg  = CONFIGS[BASELINE]

    print(f"RFCT150 ウェイト精密テスト (ベースライン: {BASELINE})")
    print(f"  {BASELINE}: {config_label(base_cfg)}")
    print(f"D3={D3_THRESHOLD}  EG={EG_THRESHOLD}  MID={MID_GAME}")
    print(f"各対戦 {total} ゲーム（先後 {n} 局ずつ）")

    challengers = [k for k in CONFIGS if k != BASELINE]
    groups = [
        ('stone ペナルティ', ['stn_0', 'stn_2_1', 'stn_6_3', 'stn_8_4']),
        ('mob',              ['mob_2', 'mob_6', 'mob_8']),
        ('stable',           ['stb_2_4', 'stb_6_12', 'stb_8_16']),
    ]

    summary = []

    for group_name, members in groups:
        print(f"\n{'='*60}")
        print(f"【{group_name} 変動】  (その他は {BASELINE} 固定)")
        print(f"  baseline: {BASELINE} : {config_label(base_cfg)}")

        for ch in members:
            cfg = CONFIGS[ch]
            print(f"\n  {BASELINE} vs {ch}")
            print(f"    {ch:10s}: {config_label(cfg)}")
            wa, wb, dr = run_match(n, BASELINE, ch, base_eval, evals[ch])
            pct_a = wa / total * 100
            pct_b = wb / total * 100
            winner = f"<< {BASELINE}" if wa > wb else (f"<< {ch}" if wb > wa else "引分")
            print(f"    結果: {BASELINE}={wa}勝({pct_a:.0f}%)  {ch}={wb}勝({pct_b:.0f}%)  Draw={dr}  {winner}")
            summary.append((group_name, ch, wa, wb, dr, total))

    print(f"\n{'='*60}")
    print(f"サマリー (ベースライン: {BASELINE})")
    print(f"  {'グループ':<8}  {'挑戦者':<12}  {'baseline':>10}  {'挑戦者':>8}  {'Draw':>4}  判定")
    for grp, ch, wa, wb, dr, tot in summary:
        winner = f"<< {BASELINE}" if wa > wb else (f"<< {ch}" if wb > wa else "引分")
        print(f"  {grp:<8}  {ch:<12}  {wa:>5}/{tot}     {wb:>5}/{tot}  {dr:>4}  {winner}")

    # 推奨設定の提示
    print(f"\n{'='*60}")
    print("推奨考察:")
    best_ch = None
    best_wb = 0
    for grp, ch, wa, wb, dr, tot in summary:
        if wb > best_wb and wb > wa:
            best_wb = wb
            best_ch = (ch, wb, wa, tot)
    if best_ch:
        ch, wb, wa, tot = best_ch
        print(f"  最も強い挑戦者: {ch}  ({wb}/{tot}勝, {wb/tot*100:.0f}%)")
        print(f"  設定: {config_label(CONFIGS[ch])}")
    else:
        print(f"  {BASELINE} がすべての対戦で優勢または互角")
