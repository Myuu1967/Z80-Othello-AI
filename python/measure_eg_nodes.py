# -*- coding: utf-8 -*-
"""
終盤完全読み (AIset_EG / SearchFull) の正当なノード数を実測する。

目的:
  Z80 側に入れるノード数セーフティバルブ (SF_NODE_CAP) の値を
  勘ではなく実測に基づいて決める。あわせて ENDGAME_THRESHOLD を
  どこまで引き上げられるかの判断材料にする。

Z80 実装 (RFCT150.ASM) の構造を忠実に再現する:
  - AIset_EG のルートループは row-major (0..63) 順
  - SearchFull の手生成は POS_ORDER_D3 の固定テーブル順
  - β-cutoff は alpha[depth] 方式 (親の現在ベストのみを beta として使う浅い α-β)
  - PASS は depth を消費するが石は置かない
  - 1ノードあたりのコストは合法手数に依らずほぼ固定
    (HasAnyLegalMove の全64マス走査 + CountAllFlips 64回)

使い方:
  python measure_eg_nodes.py            # 既定 (各空きマス数200局面)
  python measure_eg_nodes.py 500        # 局面数を指定
"""
import sys, os, random, re
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from othello_mm3_ab import (BLACK, WHITE, EMPTY, make_board,
                            count_flips, apply_move, count_stones)

ASM = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   '..', 'asm', 'RFCT150.ASM')

NEG_INF = -127          # Z80 の 81H
NODE_ABORT = 3_000_000  # 測定側の暴走防止 (これを超えたら打ち切って報告)


def load_pos_order_d3(path=ASM):
    """RFCT150.ASM から POS_ORDER_D3 テーブルを抽出する (ASM を正とする)"""
    src = open(path, encoding='utf-8', errors='replace').read()
    body = src.split('POS_ORDER_D3:', 1)[1]
    vals = []
    for line in body.splitlines():
        line = line.split(';')[0].strip()
        if not line:
            continue
        m = re.match(r'^DEFB\s+(.*)$', line, re.I)
        if not m:
            if vals:
                break          # 次のラベル等に到達 → 終了
            continue
        vals += [int(x) for x in m.group(1).split(',')]
        if len(vals) >= 64:
            break
    assert len(vals) == 64 and sorted(vals) == list(range(64)), \
        f"POS_ORDER_D3 の抽出に失敗 ({len(vals)} 件)"
    return vals


POS_ORDER_D3 = load_pos_order_d3()


class Counter:
    __slots__ = ('nodes', 'flips')
    def __init__(self):
        self.nodes = 0   # SearchFull 呼び出し回数 (= Z80 のノードカウンタ)
        self.flips = 0   # CountAllFlips 相当の呼び出し回数 (実処理時間の指標)


class Abort(Exception):
    pass


def has_any_legal(board, side):
    for p in range(64):
        if count_flips(board, p, side) > 0:
            return True
    return False


def search_full(board, side, depth, alpha, ctr):
    """Z80 SearchFull の忠実な再現。alpha はリスト (depth 別)。"""
    ctr.nodes += 1
    if ctr.nodes > NODE_ABORT:
        raise Abort()

    alpha[depth] = NEG_INF
    opp = 3 - side

    ctr.flips += 64                      # HasAnyLegalMove(side) 相当
    if not has_any_legal(board, side):
        ctr.flips += 64                  # HasAnyLegalMove(opp) 相当
        if not has_any_legal(board, opp):
            b, w = count_stones(board)
            return (b - w) if side == BLACK else (w - b)
        # PASS: depth を消費して相手番へ
        return -search_full(board, opp, depth + 1, alpha, ctr)

    best = NEG_INF
    for pos in POS_ORDER_D3:
        ctr.flips += 1                   # CountAllFlips
        if count_flips(board, pos, side) == 0:
            continue
        nb = apply_move(board, pos, side)
        child = -search_full(nb, opp, depth + 1, alpha, ctr)
        if best == NEG_INF or child > best:
            best = child
            alpha[depth] = best
            if best >= -alpha[depth - 1]:   # β-cutoff
                return best
    return best


def ai_choose_eg(board, side, ctr):
    """AIset_EG の再現。戻り値 = (best_pos, best_score)"""
    alpha = [NEG_INF] * 80   # PASS も depth を消費するため余裕を持たせる
    opp = 3 - side
    best_score, best_pos = NEG_INF, -1
    for pos in range(64):                # ルートは row-major 順
        ctr.flips += 1
        if count_flips(board, pos, side) == 0:
            continue
        nb = apply_move(board, pos, side)
        alpha[0] = best_score            # LD (SF_ALPHA_TBL),A
        score = -search_full(nb, opp, 1, alpha, ctr)
        if best_pos < 0 or score > best_score:
            best_score, best_pos = score, pos
    return best_pos, best_score


def random_position(empties, rng):
    """ランダム対局で空きマス数 empties の局面を作る。手番も返す。"""
    board = make_board()
    side = BLACK
    while True:
        n_empty = sum(1 for v in board if v == EMPTY)
        if n_empty <= empties:
            return (board, side) if n_empty == empties else None
        legal = [p for p in range(64) if count_flips(board, p, side) > 0]
        if not legal:
            side = 3 - side
            if not any(count_flips(board, p, side) > 0 for p in range(64)):
                return None              # 両者パス = 早期終了局面
            continue
        board = apply_move(board, rng.choice(legal), side)
        side = 3 - side


def main():
    n_pos = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    rng = random.Random(20260903)

    print("SearchFull node count measurement (Z80 RFCT150 faithful)")
    print(f"positions per empty-count: {n_pos}\n")
    print(f"{'empties':>7} | {'samples':>7} | {'max':>9} | {'p95':>8} | "
          f"{'median':>7} | {'mean':>8} | {'max flips':>10}")
    print("-" * 76)

    results = {}
    for empties in range(2, 13):
        nodes_list, flips_list, aborted = [], [], 0
        tries = 0
        while len(nodes_list) < n_pos and tries < n_pos * 40:
            tries += 1
            r = random_position(empties, rng)
            if r is None:
                continue
            board, side = r
            if not has_any_legal(board, side):
                continue
            ctr = Counter()
            try:
                ai_choose_eg(board, side, ctr)
            except Abort:
                aborted += 1
                continue
            nodes_list.append(ctr.nodes)
            flips_list.append(ctr.flips)
        if not nodes_list:
            continue
        nodes_list.sort()
        n = len(nodes_list)
        mx = nodes_list[-1]
        p95 = nodes_list[min(n - 1, int(n * 0.95))]
        med = nodes_list[n // 2]
        mean = sum(nodes_list) / n
        results[empties] = (mx, p95, med, mean, max(flips_list))
        print(f"{empties:>7} | {n:>7} | {mx:>9,} | {p95:>8,} | "
              f"{med:>7,} | {mean:>8.1f} | {max(flips_list):>10,}")
        if aborted:
            print(f"          (aborted over {NODE_ABORT:,} nodes: {aborted})")

    print("\n--- Z80 time estimate (1 node = HasAnyLegalMove + up to 64 CountAllFlips) ---")
    print("Assumed cost per CountAllFlips-equivalent scan: 100us @10MHz (rough)")
    print(f"{'empties':>7} | {'max nodes':>10} | {'max flips':>11} | {'est. worst time':>16}")
    print("-" * 56)
    for e, (mx, p95, med, mean, mxf) in sorted(results.items()):
        print(f"{e:>7} | {mx:>10,} | {mxf:>11,} | {mxf * 100 / 1e6:>13.2f} s")


if __name__ == '__main__':
    main()
