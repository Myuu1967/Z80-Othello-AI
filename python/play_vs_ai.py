"""
オセロ 人 vs AI (tkinter GUI)
評価関数: RFCT100 v2 (mob×8, stable×8/16, -stone_diff×8/4)
POS_WEIGHT: GA_D2S優勝値 (corner=114, x_sq=-54) [optimize_weights_rfct100_v2.py 1位]
深さ: depth-2 (空き < D3_THRESHOLD=20 で depth-3 に自動切替)

起動:
    cd python
    python play_vs_ai.py
"""

import tkinter as tk
from tkinter import messagebox
import threading
import time
import othello_mm3_ab as oth

# =========================================================
# AI 設定
# =========================================================
GA_D2S_TABLE = [
    114,  -5, -16,  -7,  -7, -16,  -5, 114,
     -5, -54, -16,   7,   7, -16, -54,  -5,
    -16, -16,   6,   2,   2,   6, -16, -16,
     -7,   7,   2, -12, -12,   2,   7,  -7,
     -7,   7,   2, -12, -12,   2,   7,  -7,
    -16, -16,   6,   2,   2,   6, -16, -16,
     -5, -54, -16,   7,   7, -16, -54,  -5,
    114,  -5, -16,  -7,  -7, -16,  -5, 114,
]
oth.POS_WEIGHT = GA_D2S_TABLE

D3_THRESHOLD = 20  # 空き < 20 → depth-3 に切替


def eval_rfct100_v2(board, side):
    """RFCT100 v2: EARLY/MID に stone_diff ペナルティ追加"""
    empty = board.count(oth.EMPTY)
    opp   = 3 - side
    if empty < 12:
        x = board.count(oth.BLACK)
        o = board.count(oth.WHITE)
        stone_diff = (x - o) if side == oth.BLACK else (o - x)
        my_s  = oth.count_stable_stones(board, side)
        opp_s = oth.count_stable_stones(board, opp)
        return stone_diff * 100 + (my_s - opp_s) * 30
    my_pos  = sum(oth.POS_WEIGHT[i] for i in range(64) if board[i] == side)
    opp_pos = sum(oth.POS_WEIGHT[i] for i in range(64) if board[i] == opp)
    pos_diff = my_pos - opp_pos
    mob_diff = oth.count_mobility(board, side) - oth.count_mobility(board, opp)
    my_s  = oth.count_stable_stones(board, side)
    opp_s = oth.count_stable_stones(board, opp)
    stable_diff = my_s - opp_s
    x = board.count(oth.BLACK)
    o = board.count(oth.WHITE)
    stone_diff = (x - o) if side == oth.BLACK else (o - x)
    if empty >= 44:
        return pos_diff + mob_diff * 8 + stable_diff * 8 - stone_diff * 8
    else:
        return pos_diff + mob_diff * 8 + stable_diff * 16 - stone_diff * 4

oth.eval_board = eval_rfct100_v2


def ai_move(board, side):
    empty  = board.count(oth.EMPTY)
    depth  = 3 if empty < D3_THRESHOLD else 2
    pos, score = oth.ai_choose_move(board, side, depth=depth)
    return pos, score, depth

# =========================================================
# GUI 定数
# =========================================================
CELL   = 68
MARGIN = 28
BOARD_PX = CELL * 8 + MARGIN * 2
STATUS_H = 90

C_BOARD   = '#2d6a2d'
C_LINE    = '#1b4d1b'
C_BLACK   = '#111111'
C_WHITE   = '#f2f2f2'
C_HINT    = '#5ab85a'   # 合法手ドット
C_HINT_BG = '#3d7a3d'   # 合法手セル背景
C_LAST    = '#e0c040'   # 最終手リング
C_STATUS  = '#1a1a2e'
C_TEXT    = '#e8e8e8'


class OthelloApp:
    def __init__(self, root):
        self.root = root
        self.root.title('Othello vs AI')
        self.root.resizable(False, False)

        self.canvas = tk.Canvas(root, width=BOARD_PX, height=BOARD_PX,
                                bg=C_BOARD, highlightthickness=0)
        self.canvas.pack()

        self.status_frame = tk.Frame(root, bg=C_STATUS, height=STATUS_H)
        self.status_frame.pack(fill=tk.X)
        self.status_frame.pack_propagate(False)

        self.lbl_turn = tk.Label(self.status_frame, text='', font=('Consolas', 13, 'bold'),
                                 bg=C_STATUS, fg=C_TEXT)
        self.lbl_turn.pack(pady=(8, 0))

        self.lbl_score = tk.Label(self.status_frame, text='', font=('Consolas', 12),
                                  bg=C_STATUS, fg=C_TEXT)
        self.lbl_score.pack()

        self.lbl_eval = tk.Label(self.status_frame, text='', font=('Consolas', 11),
                                 bg=C_STATUS, fg='#aaccaa')
        self.lbl_eval.pack()

        self.canvas.bind('<Button-1>', self.on_click)

        self.board       = None
        self.human_side  = oth.BLACK
        self.ai_side     = oth.WHITE
        self.turn        = oth.BLACK
        self.last_pos    = None
        self.legal_moves = []
        self.ai_busy     = False
        self.game_over   = False

        self._choose_side()

    # ----------------------------------------------------------
    # 先後手選択
    # ----------------------------------------------------------
    def _choose_side(self):
        dlg = tk.Toplevel(self.root)
        dlg.title('先後手選択')
        dlg.resizable(False, False)
        dlg.grab_set()
        dlg.focus_set()

        tk.Label(dlg, text='あなたはどちらで対戦しますか？',
                 font=('', 12), pady=12).pack()

        frm = tk.Frame(dlg)
        frm.pack(pady=8)

        chosen = tk.IntVar(value=0)

        def pick(side):
            chosen.set(side)
            dlg.destroy()

        tk.Button(frm, text='● 黒（先手）', font=('', 12), width=14,
                  bg='#222', fg='white', activebackground='#444',
                  command=lambda: pick(oth.BLACK)).pack(side=tk.LEFT, padx=10)
        tk.Button(frm, text='○ 白（後手）', font=('', 12), width=14,
                  bg='#eee', fg='black', activebackground='#ccc',
                  command=lambda: pick(oth.WHITE)).pack(side=tk.LEFT, padx=10)

        self.root.wait_window(dlg)

        side = chosen.get()
        if side == 0:
            side = oth.BLACK  # デフォルト

        self.human_side = side
        self.ai_side    = 3 - side
        self._start_game()

    # ----------------------------------------------------------
    # ゲーム開始 / リセット
    # ----------------------------------------------------------
    def _start_game(self):
        self.board       = oth.make_board()
        self.turn        = oth.BLACK
        self.last_pos    = None
        self.game_over   = False
        self.legal_moves = oth.get_legal_moves(self.board, self.turn)

        self._redraw()
        self._update_status()

        if self.turn == self.ai_side:
            self.root.after(300, self._ai_turn)

    # ----------------------------------------------------------
    # 描画
    # ----------------------------------------------------------
    def _cell_xy(self, pos):
        """pos(0-63) → セル左上ピクセル座標"""
        r = pos // 8
        c = pos % 8
        x = MARGIN + c * CELL
        y = MARGIN + r * CELL
        return x, y

    def _redraw(self):
        self.canvas.delete('all')

        # グリッド線
        for i in range(9):
            x = MARGIN + i * CELL
            y = MARGIN + i * CELL
            self.canvas.create_line(MARGIN, y, BOARD_PX - MARGIN, y, fill=C_LINE, width=1)
            self.canvas.create_line(x, MARGIN, x, BOARD_PX - MARGIN, fill=C_LINE, width=1)

        # 星（4点）
        for sr, sc in [(2,2),(2,5),(5,2),(5,5)]:
            sx = MARGIN + sc * CELL
            sy = MARGIN + sr * CELL
            r = 4
            self.canvas.create_oval(sx-r, sy-r, sx+r, sy+r, fill=C_LINE, outline='')

        # 合法手ハイライト（セル背景）
        legal_set = set(self.legal_moves)
        for pos in range(64):
            x, y = self._cell_xy(pos)
            if pos in legal_set and not self.game_over:
                self.canvas.create_rectangle(x+1, y+1, x+CELL-1, y+CELL-1,
                                             fill=C_HINT_BG, outline='')

        # 最終手リング
        if self.last_pos is not None:
            x, y = self._cell_xy(self.last_pos)
            pad = 5
            self.canvas.create_rectangle(x+pad, y+pad, x+CELL-pad, y+CELL-pad,
                                         outline=C_LAST, width=3)

        # 石
        pad = 5
        for pos in range(64):
            stone = self.board[pos]
            if stone == oth.EMPTY:
                continue
            x, y = self._cell_xy(pos)
            color = C_BLACK if stone == oth.BLACK else C_WHITE
            outline = '#555' if stone == oth.BLACK else '#999'
            self.canvas.create_oval(x+pad, y+pad, x+CELL-pad, y+CELL-pad,
                                    fill=color, outline=outline, width=1)

        # 合法手ドット（石がない合法手）
        if not self.game_over:
            r = 7
            for pos in legal_set:
                if self.board[pos] == oth.EMPTY:
                    x, y = self._cell_xy(pos)
                    cx, cy = x + CELL//2, y + CELL//2
                    self.canvas.create_oval(cx-r, cy-r, cx+r, cy+r,
                                            fill=C_HINT, outline='')

        # 列ラベル (A-H)
        for i, lbl in enumerate('ABCDEFGH'):
            x = MARGIN + i * CELL + CELL // 2
            self.canvas.create_text(x, MARGIN // 2, text=lbl,
                                    fill='#aaddaa', font=('Consolas', 10))
        # 行ラベル (1-8)
        for i in range(8):
            y = MARGIN + i * CELL + CELL // 2
            self.canvas.create_text(MARGIN // 2, y, text=str(i+1),
                                    fill='#aaddaa', font=('Consolas', 10))

    def _update_status(self, eval_str=''):
        x, o = oth.count_stones(self.board)
        side_char = {oth.BLACK: '●', oth.WHITE: '○'}
        h_mark = '(あなた)' if self.turn == self.human_side else ''
        a_mark = '(AI)' if self.turn == self.ai_side else ''

        if self.game_over:
            if x > o:
                result = f'●黒の勝ち！  X:{x}  O:{o}'
            elif o > x:
                result = f'○白の勝ち！  X:{x}  O:{o}'
            else:
                result = f'引き分け！  X:{x}  O:{o}'
            self.lbl_turn.config(text='ゲーム終了')
            self.lbl_score.config(text=result)
            self.lbl_eval.config(text='')
        else:
            turn_str = f'{side_char[self.turn]} {"黒" if self.turn == oth.BLACK else "白"}の番  {h_mark}{a_mark}'
            self.lbl_turn.config(text=turn_str)
            self.lbl_score.config(text=f'●黒: {x}  ○白: {o}  空き: {self.board.count(oth.EMPTY)}')
            self.lbl_eval.config(text=eval_str)

    # ----------------------------------------------------------
    # 人間の入力
    # ----------------------------------------------------------
    def on_click(self, event):
        if self.ai_busy or self.game_over:
            return
        if self.turn != self.human_side:
            return

        c = (event.x - MARGIN) // CELL
        r = (event.y - MARGIN) // CELL
        if not (0 <= r < 8 and 0 <= c < 8):
            return
        pos = r * 8 + c

        if pos not in self.legal_moves:
            return

        self.board    = oth.apply_move(self.board, pos, self.human_side)
        self.last_pos = pos
        self._advance_turn()

    # ----------------------------------------------------------
    # AI の手番
    # ----------------------------------------------------------
    def _ai_turn(self):
        if self.game_over or self.turn != self.ai_side:
            return
        self.ai_busy = True
        self.lbl_turn.config(text='AI 思考中...')
        self.canvas.config(cursor='watch')

        def think():
            pos, score, depth = ai_move(self.board, self.ai_side)
            self.root.after(0, lambda: self._ai_done(pos, score, depth))

        threading.Thread(target=think, daemon=True).start()

    def _ai_done(self, pos, score, depth):
        self.ai_busy = False
        self.canvas.config(cursor='')
        if self.game_over:
            return

        self.board    = oth.apply_move(self.board, pos, self.ai_side)
        self.last_pos = pos
        pos_str       = oth.pos_to_str(pos)
        eval_str      = f'AI → {pos_str}  評価値: {score:+d}  (depth-{depth})'
        self._advance_turn(eval_str)

    # ----------------------------------------------------------
    # ターン進行・PASS・ゲーム終了
    # ----------------------------------------------------------
    def _advance_turn(self, eval_str=''):
        self.turn = 3 - self.turn

        next_legal = oth.get_legal_moves(self.board, self.turn)
        if not next_legal:
            # PASS チェック
            opp_legal = oth.get_legal_moves(self.board, 3 - self.turn)
            if not opp_legal:
                self.game_over   = True
                self.legal_moves = []
                self._redraw()
                self._update_status()
                self._show_result()
                return
            # PASS
            passer = '●黒' if self.turn == oth.BLACK else '○白'
            messagebox.showinfo('PASS', f'{passer} は打てる場所がないのでパスします')
            self.turn      = 3 - self.turn
            next_legal     = oth.get_legal_moves(self.board, self.turn)

        self.legal_moves = next_legal
        self._redraw()
        self._update_status(eval_str)

        if self.turn == self.ai_side:
            self.root.after(400, self._ai_turn)

    def _show_result(self):
        x, o = oth.count_stones(self.board)
        if x > o:
            msg = f'●黒の勝ち！\n黒: {x}  白: {o}'
        elif o > x:
            msg = f'○白の勝ち！\n黒: {x}  白: {o}'
        else:
            msg = f'引き分け！\n黒: {x}  白: {o}'

        again = messagebox.askyesno('ゲーム終了', f'{msg}\n\nもう一度プレイしますか？')
        if again:
            self._choose_side()


# =========================================================
# エントリポイント
# =========================================================
if __name__ == '__main__':
    root = tk.Tk()
    app  = OthelloApp(root)
    root.mainloop()
