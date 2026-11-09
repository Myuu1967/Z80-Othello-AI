# kifu.py — Z80 オセロの棋譜を Pico のフラッシュ (/kifu/) に記録する
#
# gameDisplay.py から使う。MicroPython / CPython の両方で動く（PC でテスト可能）。
#
# 記録の決まり
#   - 1局 = 1ファイル。/kifu/K0001.txt から通し番号。最新 KEEP 局だけ残す
#   - Z80 から受けた行はそのまま（BS 処理済み）、Pico が足す情報は "# " で始まる行
#   - 手は「次の盤面が届いた時点」で確定する（不正手 NG は取り消し）
#       # MOVE 1 X C4 (YOU)
#       # MOVE 2 O C3 (AI)
#       # TIME 687ms            ← GPIO15 で測った AI の思考時間
#       # FREEZE? AI thinking >60s
#       # IDLE >60s (last: ...) ← AI 思考中以外で受信が途切れた
#       # END ...
#   - フラッシュへの書き込みは、受信が FLUSH_IDLE_MS 途切れたときだけ行う
#     （書き込み中は割り込みが止まり、UART を取りこぼすため）。毎回 open→追記→close

import os
try:
    from utime import ticks_diff as _ticks_diff
except ImportError:                             # PC でのテスト用
    def _ticks_diff(a, b):
        return a - b

KIFU_DIR      = '/kifu'
KIFU_KEEP     = 50        # 残す局数
FLUSH_IDLE_MS = 300       # 受信がこれだけ途切れたら書き込む
FREEZE_MS     = 60000     # AI 思考がこれを超えたら FREEZE? を記録
IDLE_MS       = 60000     # 対局中に受信がこれだけ途切れたら IDLE を記録
BUF_MAX       = 300       # 書けないときにメモリを食いつぶさない上限
PRE_MAX       = 14        # 対局開始前の行を何行覚えておくか（初期盤面用）

BOARD_HEADER = 'A B C D E F G H'


def clean(line):
    """BS を適用し、その他の制御文字を除く"""
    out = []
    for ch in line:
        if ch == '\x08':
            if out:
                out.pop()
        elif ch >= ' ':
            out.append(ch)
    return ''.join(out).strip()


class Kifu:
    def __init__(self, ver='', kdir=KIFU_DIR, keep=KIFU_KEEP):
        self.ver      = ver
        self.kdir     = kdir
        self.keep     = keep
        self.path     = None      # 記録中のファイル
        self.state    = 'boot'    # boot / game / ended
        self.buf      = []        # 未書き込みの行
        self.pre      = []        # 対局開始前の行
        self.session  = None      # この起動で最初に作った棋譜番号
        self.game_no  = 0
        self.move_no  = 0
        self.human    = '?'       # 人の石 'X' / 'O'
        self.pending  = None      # (石, 位置, 'YOU'/'AI') 盤面待ちの手
        self.last_rx  = 0
        self.idle_logged   = False
        self.freeze_logged = False
        self.last_line = ''
        self.error    = None
        try:
            os.mkdir(kdir)
        except OSError:
            pass

    # ─── ファイル管理 ───────────────────────────────────
    def _numbers(self):
        nums = []
        try:
            names = os.listdir(self.kdir)
        except OSError:
            return nums
        for n in names:
            if len(n) == 9 and n[0] == 'K' and n.endswith('.txt') and n[1:5].isdigit():
                nums.append(int(n[1:5]))
        nums.sort()
        return nums

    def _new_file(self):
        nums = self._numbers()
        while len(nums) >= self.keep:          # 古いものから消す
            try:
                os.remove('%s/K%04d.txt' % (self.kdir, nums[0]))
            except OSError:
                pass
            nums.pop(0)
        no = (nums[-1] + 1) if nums else 1
        if no > 9999:
            no = 1
        if self.session is None:
            self.session = no
        self.game_no += 1
        self.path = '%s/K%04d.txt' % (self.kdir, no)
        return no

    def flush(self):
        if not self.buf:
            return
        if self.path is None:
            self.buf = []
            return
        try:
            f = open(self.path, 'a')
            f.write('\n'.join(self.buf) + '\n')
            f.close()
            self.buf = []
            self.error = None
        except OSError as e:
            self.error = 'kifu write error %s' % e
            if len(self.buf) > BUF_MAX:
                self.buf = self.buf[-BUF_MAX:]

    def _out(self, line):
        self.buf.append(line)

    # ─── 対局の開始・終了 ───────────────────────────────
    def _start(self, now_ms, note=None):
        if self.state == 'game':
            self._end('(no end line: next game started)')
            self.flush()
        no = self._new_file()
        self.state   = 'game'
        self.move_no = 0
        self.pending = None
        self.idle_logged = False
        self.freeze_logged = False
        self._out('# KIFU K%04d session=K%04d game=%d' % (no, self.session, self.game_no))
        if self.ver:
            self._out('# Z80 ' + self.ver)
        self._out('# ticks_ms %d' % now_ms)
        if note:
            self._out('# ' + note)
        for l in self.pre:                      # 開始前の盤面（初期局面）
            self._out(l)
        self.pre = []

    def _end(self, reason):
        self._commit()
        self._out('# END ' + reason)
        self.state = 'ended'
        self.pre = []

    def _commit(self):
        if self.pending is None:
            return
        stone, pos, who = self.pending
        self.move_no += 1
        self._out('# MOVE %d %s %s (%s)' % (self.move_no, stone, pos, who))
        self.pending = None

    def _ai_stone(self):
        if self.human == 'X':
            return 'O'
        if self.human == 'O':
            return 'X'
        return '?'

    # ─── 入力 ───────────────────────────────────────────
    def feed_line(self, raw, now_ms):
        """UART から受けた1行（改行なし）を渡す"""
        line = clean(raw)
        if not line:
            return
        self.last_rx = now_ms
        self.idle_logged = False
        self.last_line = line

        # 対局開始
        if line.startswith('You go first') or line.startswith('AI goes first'):
            self.human = 'X' if 'BLACK' in line else 'O'
            self._start(now_ms)
            self._out(line)
            return

        if line.startswith('Choose:'):
            if self.state == 'game':
                self._end('(no end line: back to Choose)')
            self.state = 'ended'
            self.pre.append(line)               # 直前の初期盤面は残す
            self.pre = self.pre[-PRE_MAX:]
            return

        is_action = (line.startswith('Move:') or line.startswith('AI moves to')
                     or line in ('AI PASS', 'YOU PASS'))

        if self.state != 'game':
            if self.state == 'boot' and is_action:   # 対局の途中で Pico が起動した
                self._start(now_ms, '(recording started mid-game)')
            else:
                self.pre.append(line)
                if len(self.pre) > PRE_MAX:
                    self.pre = self.pre[-PRE_MAX:]
                return

        # ここから対局中
        if line.endswith(BOARD_HEADER):           # 盤面が届いた → 手を確定
            self._commit()
        elif line.startswith('Move:'):
            pos = line[5:].strip()[-2:]
            self.pending = (self.human, pos, 'YOU') if len(pos) == 2 else None
        elif line.startswith('NG'):
            self.pending = None
        elif line.startswith('AI moves to'):
            pos = line[11:].strip()[:2]
            self.pending = (self._ai_stone(), pos, 'AI')

        self._out(line)

        if line.endswith('wins') or line == 'Draw':
            self._end(line)
        elif line == 'Game aborted.':
            self._end('aborted')

    def ai_time(self, ms):
        """GPIO15 の High 時間（AI 思考時間）"""
        if self.state == 'game':
            self._out('# TIME %dms' % ms)
        self.freeze_logged = False

    def tick(self, now_ms, ai_thinking_ms=None):
        """メインループから毎回呼ぶ。戻り値: LCD に出す警告（なければ None）"""
        warn = None
        if self.state == 'game':
            if ai_thinking_ms is not None and ai_thinking_ms >= FREEZE_MS:
                if not self.freeze_logged:
                    self._out('# FREEZE? AI thinking >%ds' % (FREEZE_MS // 1000))
                    self.freeze_logged = True
                    self.flush()
                warn = 'FREEZE?'
            elif (ai_thinking_ms is None and not self.idle_logged
                  and self._diff(now_ms, self.last_rx) >= IDLE_MS):
                self._out('# IDLE >%ds (last: %s)' % (IDLE_MS // 1000, self.last_line))
                self.idle_logged = True
                self.flush()
        if self.buf and self._diff(now_ms, self.last_rx) >= FLUSH_IDLE_MS:
            self.flush()
        return warn

    def note_rx(self, now_ms):
        """バイトを受けたら呼ぶ（行の途中でも書き込みを遅らせるため）"""
        self.last_rx = now_ms

    @staticmethod
    def _diff(a, b):
        return _ticks_diff(a, b)
