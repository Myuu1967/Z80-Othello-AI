#!/usr/bin/env python3
"""
kifu_viewer.py — Pico が記録した棋譜 (/kifu/K0001.txt 等) を PC で1手ずつ再現する

使い方:
    python kifu_viewer.py local/kifu/K0012.txt     # GUI で表示
    python kifu_viewer.py                          # ファイル選択ダイアログ
    python kifu_viewer.py --check K0012.txt        # GUI なしで手順と警告を表示

操作: ← → 1手戻る/進む、Home/End 最初/最後、一覧クリックでその局面へ
表示: 人の手 = 赤枠、AI の手 = シアン枠。
      Z80 の盤面が Python のルールで計算した盤面と違うマスは橙の × で示す。
"""
import sys

DIRS = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
COLS = 'ABCDEFGH'


# ─── ルール ─────────────────────────────────────────────
def initial_board():
    b = [['.'] * 8 for _ in range(8)]
    b[3][3], b[3][4], b[4][3], b[4][4] = 'O', 'X', 'X', 'O'
    return b


def copy_board(b):
    return [row[:] for row in b]


def pos_to_rc(pos):
    """'C4' → (row=3, col=2)"""
    if len(pos) != 2 or pos[0].upper() not in COLS or pos[1] not in '12345678':
        return None
    return int(pos[1]) - 1, COLS.index(pos[0].upper())


def rc_to_pos(r, c):
    return COLS[c] + str(r + 1)


def flips(b, r, c, s):
    if b[r][c] != '.':
        return []
    o = 'O' if s == 'X' else 'X'
    out = []
    for dr, dc in DIRS:
        line = []
        rr, cc = r + dr, c + dc
        while 0 <= rr < 8 and 0 <= cc < 8 and b[rr][cc] == o:
            line.append((rr, cc))
            rr += dr
            cc += dc
        if line and 0 <= rr < 8 and 0 <= cc < 8 and b[rr][cc] == s:
            out += line
    return out


def apply_move(b, pos, s):
    """ルールどおりに打った盤面を返す。不正手なら (盤面, False)"""
    nb = copy_board(b)
    rc = pos_to_rc(pos)
    if rc is None or s not in 'XO':
        return nb, False
    r, c = rc
    f = flips(b, r, c, s)
    nb[r][c] = s
    for rr, cc in f:
        nb[rr][cc] = s
    return nb, bool(f)


def has_move(b, s):
    return any(flips(b, r, c, s) for r in range(8) for c in range(8))


def count(b):
    x = sum(row.count('X') for row in b)
    o = sum(row.count('O') for row in b)
    return x, o


# ─── 棋譜の読み込み ─────────────────────────────────────
class Step:
    def __init__(self, kind, board, stone='', pos='', who='', no=0):
        self.kind  = kind      # start / move / pass / note
        self.board = board     # 表示する盤面（Z80 が出したもの優先）
        self.stone = stone
        self.pos   = pos
        self.who   = who       # YOU / AI / ?
        self.no    = no
        self.ms    = None
        self.eval  = ''
        self.score = ''
        self.notes = []        # 情報
        self.warns = []        # 警告
        self.bad   = []        # ルール計算と食い違ったマス

    def label(self):
        if self.kind == 'start':
            return '  開始局面'
        if self.kind == 'move':
            t = '%3d  %s %s  %-3s' % (self.no, self.stone, self.pos, self.who)
            if self.ms is not None:
                t += ' %6dms' % self.ms
        elif self.kind == 'pass':
            t = '     %s PASS %-3s' % (self.stone, self.who)
        else:
            t = '     ' + (self.notes[0] if self.notes else '')
        if self.warns:
            t = '!! ' + t.lstrip()
        return t


def parse(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        lines = [l.rstrip('\r\n') for l in f]

    info = []
    human = '?'
    steps = []
    board = None          # 直前の確定盤面
    pend = []             # 盤面待ちの手
    rows = None           # 読み取り中の盤面
    last_ai = None

    def cur():
        return board if board is not None else initial_board()

    def note(text, warn=False):
        st = Step('note', copy_board(cur()))
        st.notes.append(text)
        if warn:
            st.warns.append(text)
        steps.append(st)

    def on_board(snap):
        nonlocal board, last_ai
        if not steps:                                   # 最初の盤面
            if not pend:
                board = snap
                steps.append(Step('start', copy_board(snap)))
                return
            steps.append(Step('start', initial_board()))
        prev = cur()
        if not pend:
            if snap != prev:                            # 記録にない変化
                new = [(r, c) for r in range(8) for c in range(8)
                       if prev[r][c] == '.' and snap[r][c] != '.']
                if len(new) == 1:
                    r, c = new[0]
                    s = snap[r][c]
                    who = 'YOU' if s == human else ('AI' if human != '?' else '?')
                    pend.append(Step('move', None, s, rc_to_pos(r, c), who))
                    pend[-1].notes.append('盤面の差分から推定した手')
                else:
                    st = Step('note', copy_board(snap))
                    st.notes.append('盤面が変化（手を特定できない）')
                    st.warns.append('盤面が変化（手を特定できない）')
                    steps.append(st)
                    board = snap
                    return
            else:
                return
        for i, mv in enumerate(pend):
            s = mv.stone
            rc = pos_to_rc(mv.pos)
            if s not in 'XO' and rc:                    # 石の色が不明 → Z80 盤面から
                s = mv.stone = snap[rc[0]][rc[1]]
            exp, legal = apply_move(prev, mv.pos, s)
            if not legal:
                mv.warns.append('%s %s はルール上打てない手' % (s, mv.pos))
            if i == len(pend) - 1:
                mv.board = copy_board(snap)
                mv.bad = [(r, c) for r in range(8) for c in range(8) if exp[r][c] != snap[r][c]]
                if mv.bad:
                    mv.warns.append('Z80 の盤面がルール計算と %d マス違う: %s' % (
                        len(mv.bad), ' '.join(rc_to_pos(r, c) for r, c in mv.bad)))
            else:
                mv.board = exp
            prev = exp
            mv.no = sum(1 for x in steps if x.kind == 'move') + 1
            steps.append(mv)
            if mv.who == 'AI':
                last_ai = mv
        pend.clear()
        board = snap

    for line in lines:
        t = line.strip()
        if rows is not None:                            # 盤面の行
            parts = t.split()
            if len(parts) == 9 and parts[0] == str(len(rows) + 1):
                rows.append(parts[1:])
                if len(rows) == 8:
                    on_board(rows)
                    rows = None
                continue
            rows = None
        if t.endswith('A B C D E F G H'):
            rows = []
            continue
        if t.startswith('# '):
            body = t[2:]
            if body.startswith('MOVE '):
                p = body.split()
                who = p[4].strip('()') if len(p) > 4 else '?'
                pend.append(Step('move', None, p[2], p[3], who))
            elif body.startswith('TIME '):
                ms = int(''.join(ch for ch in body[5:] if ch.isdigit()) or 0)
                tgt = next((m for m in reversed(pend) if m.who == 'AI'), None) or last_ai
                if tgt is not None and tgt.ms is None:
                    tgt.ms = ms
            elif body.startswith('FREEZE') or body.startswith('IDLE'):
                note(body, warn=True)
            elif body.startswith('END'):
                note(body)
            elif body.startswith('KIFU') or body.startswith('Z80') or body.startswith('('):
                info.append(body)
            continue
        if t.startswith('You go first') or t.startswith('AI goes first'):
            human = 'X' if 'BLACK' in t else 'O'
            info.append(t)
        elif t in ('AI PASS', 'YOU PASS'):
            who = 'AI' if t.startswith('AI') else 'YOU'
            s = human if who == 'YOU' else ({'X': 'O', 'O': 'X'}.get(human, '?'))
            st = Step('pass', copy_board(cur()), s, '', who)
            if s in 'XO' and has_move(cur(), s):
                st.warns.append('%s は打てる手があるのに PASS' % s)
            steps.append(st)
        elif t.startswith('Eval:'):
            tgt = next((m for m in reversed(pend) if m.who == 'AI'), None)
            if tgt is not None:
                tgt.eval = t
        elif t.startswith('X:') and 'O:' in t:
            if steps:
                steps[-1].score = t
                x, o = count(steps[-1].board)
                if t.replace(' ', '') != 'X:%02dO:%02d' % (x, o):
                    steps[-1].warns.append('石数の表示 "%s" が盤面 (X:%d O:%d) と違う' % (t, x, o))
        elif t.startswith('Game ended by') or t.endswith('wins') or t == 'Draw' \
                or t == 'GAME OVER' or t == 'Game aborted.':
            note(t)
    if pend:                                            # 盤面が来ないまま終わった手
        for mv in pend:
            mv.board = copy_board(cur())
            mv.notes.append('この手の後の盤面が届いていない（ここで停止）')
            mv.warns.append('この手の後の盤面が届いていない（ここで停止）')
            steps.append(mv)
    if not steps:
        steps.append(Step('start', initial_board()))
    return info, human, steps


# ─── テキスト出力 (--check) ─────────────────────────────
def check(path):
    info, human, steps = parse(path)
    print('\n'.join(info))
    print('人の石:', human)
    nwarn = 0
    for st in steps:
        print(st.label(), ('  ' + st.score) if st.score else '')
        for n in st.notes:
            if n not in st.warns and st.kind != 'note':
                print('      -', n)
        for w in st.warns:
            print('      !!', w)
            nwarn += 1
    print('手数 %d、警告 %d' % (sum(1 for s in steps if s.kind == 'move'), nwarn))
    return 1 if nwarn else 0


# ─── GUI ────────────────────────────────────────────────
def gui(path):
    import tkinter as tk
    from tkinter import filedialog

    if not path:
        root0 = tk.Tk()
        root0.withdraw()
        path = filedialog.askopenfilename(title='棋譜を開く',
                                          filetypes=[('kifu', '*.txt'), ('all', '*.*')])
        root0.destroy()
        if not path:
            return
    info, human, steps = parse(path)

    CELL, M = 56, 28
    root = tk.Tk()
    root.title('kifu_viewer — ' + path)
    cv = tk.Canvas(root, width=M + CELL * 8 + 8, height=M + CELL * 8 + 8, bg='white',
                   highlightthickness=0)
    cv.grid(row=0, column=0, padx=8, pady=8, sticky='n')
    side = tk.Frame(root)
    side.grid(row=0, column=1, rowspan=2, padx=8, pady=8, sticky='ns')
    tk.Label(side, text='\n'.join(info) + '\n人の石: ' + human, justify='left',
             font=('Consolas', 9)).pack(anchor='w')
    lb = tk.Listbox(side, width=34, height=26, font=('Consolas', 10), exportselection=False)
    lb.pack(fill='y', expand=True)
    for st in steps:
        lb.insert('end', st.label())
        if st.warns:
            lb.itemconfig('end', fg='red')
    detail = tk.Label(root, text='', justify='left', anchor='w', font=('Meiryo', 10),
                      wraplength=M + CELL * 8)
    detail.grid(row=1, column=0, padx=8, pady=(0, 8), sticky='w')

    idx = [0]

    def draw():
        st = steps[idx[0]]
        cv.delete('all')
        cv.create_rectangle(M, M, M + CELL * 8, M + CELL * 8, fill='#2e8b57', outline='black')
        for i in range(9):
            cv.create_line(M + i * CELL, M, M + i * CELL, M + CELL * 8)
            cv.create_line(M, M + i * CELL, M + CELL * 8, M + i * CELL)
        for i in range(8):
            cv.create_text(M + i * CELL + CELL / 2, M / 2, text=COLS[i], font=('Consolas', 12))
            cv.create_text(M / 2, M + i * CELL + CELL / 2, text=str(i + 1), font=('Consolas', 12))
        for r in range(8):
            for c in range(8):
                v = st.board[r][c]
                x0, y0 = M + c * CELL + 6, M + r * CELL + 6
                if v in 'XO':
                    cv.create_oval(x0, y0, x0 + CELL - 12, y0 + CELL - 12,
                                   fill='black' if v == 'X' else 'white', outline='black')
        if st.kind == 'move' and pos_to_rc(st.pos):
            r, c = pos_to_rc(st.pos)
            col = 'red' if st.who == 'YOU' else ('#00c8c8' if st.who == 'AI' else 'orange')
            cv.create_rectangle(M + c * CELL + 2, M + r * CELL + 2,
                                M + (c + 1) * CELL - 2, M + (r + 1) * CELL - 2, outline=col, width=4)
        for r, c in st.bad:
            x0, y0 = M + c * CELL + 14, M + r * CELL + 14
            cv.create_line(x0, y0, x0 + CELL - 28, y0 + CELL - 28, fill='orange', width=4)
            cv.create_line(x0 + CELL - 28, y0, x0, y0 + CELL - 28, fill='orange', width=4)
        x, o = count(st.board)
        txt = ['%d / %d   X(黒):%d  O(白):%d' % (idx[0], len(steps) - 1, x, o)]
        if st.kind == 'move':
            txt.append('%s が %s に打った（%s）' % ('人' if st.who == 'YOU' else st.who, st.pos, st.stone)
                       + ('  思考 %dms' % st.ms if st.ms is not None else ''))
        if st.eval:
            txt.append(st.eval)
        txt += [n for n in st.notes if n not in st.warns]
        txt += ['!! ' + w for w in st.warns]
        detail.config(text='\n'.join(txt), fg='red' if st.warns else 'black')
        lb.selection_clear(0, 'end')
        lb.selection_set(idx[0])
        lb.see(idx[0])

    def go(i):
        idx[0] = max(0, min(len(steps) - 1, i))
        draw()

    root.bind('<Left>', lambda e: go(idx[0] - 1))
    root.bind('<Right>', lambda e: go(idx[0] + 1))
    root.bind('<Home>', lambda e: go(0))
    root.bind('<End>', lambda e: go(len(steps) - 1))
    lb.bind('<<ListboxSelect>>', lambda e: lb.curselection() and go(lb.curselection()[0]))
    go(0)
    root.mainloop()


if __name__ == '__main__':
    args = sys.argv[1:]
    if args and args[0] == '--check':
        sys.exit(check(args[1]))
    gui(args[0] if args else None)
