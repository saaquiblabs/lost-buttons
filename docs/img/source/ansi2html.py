# Turns a captured terminal session (script(1) output) into HTML: the last frame the menu drew,
# with its 24-bit colours, and the icon where the menu placed it with the kitty graphics protocol.
# Used by capture-menu.sh.
import base64, html, re, sys

raw = open(sys.argv[1], 'rb').read().decode('utf8', 'replace')

# The icon: the PNG the menu sent (kitty "a=t" plus its chunks) and where it was last placed.
apc = re.findall(r'\x1b_G([^;\x1b]*)(?:;([^\x1b]*))?\x1b\\', raw)
png = ''.join(p for h, p in apc if h.startswith('a=t') or h.startswith('m='))
place = re.findall(r'\x1b\[(\d+);(\d+)H\x1b_Ga=p,[^\x1b]*?c=(\d+),r=(\d+)', raw)

i = raw.rfind('\x1b[H')
raw = raw[i + 3:] if i >= 0 else raw
j = raw.find('\x1b[?25h')
raw = raw[:j] if j >= 0 else raw
raw = re.sub(r'\x1b_G[^\x1b]*\x1b\\', '', raw)
raw = re.sub(r'\x1b\]1337;[^\x07]*\x07', '', raw)
raw = re.sub(r'\x1b[78]', '', raw)
raw = re.sub(r'\x1b\[\d+;\d+H', '', raw)

out = []
fg = bg = None
bold = False
for m in re.finditer(r'\x1b\[([0-9;?]*)([a-zA-Z])|([^\x1b]+)', raw):
    if m.group(3) is not None:
        t = html.escape(m.group(3).replace('\r', ''))
        st = [f'color:{fg}'] if fg else []
        if bg: st.append(f'background:{bg}')
        if bold: st.append('font-weight:700')
        out.append(f'<span style="{";".join(st)}">{t}</span>' if st else t)
        continue
    if m.group(2) != 'm':
        continue
    ps = [int(x) for x in m.group(1).split(';') if x.isdigit()] or [0]
    k = 0
    while k < len(ps):
        p = ps[k]
        if p == 0: fg = bg = None; bold = False
        elif p == 1: bold = True
        elif p == 49: bg = None
        elif p == 38 and ps[k + 1] == 2: fg = 'rgb(%d,%d,%d)' % tuple(ps[k + 2:k + 5]); k += 4
        elif p == 48 and ps[k + 1] == 2: bg = 'rgb(%d,%d,%d)' % tuple(ps[k + 2:k + 5]); k += 4
        k += 1

LINE, PAD = 19, 10
img = ''
if png and place:
    r, c, cols, rows = map(int, place[-1])
    img = (f'<img src="data:image/png;base64,{png}" style="position:absolute;'
           f'left:calc({PAD}px + {c - 1}ch);top:{PAD + (r - 1) * LINE}px;width:{cols}ch;height:{rows * LINE}px">')
print('<html><body style="margin:0;background:#151A22;color:#E9E6DF">'
      f'<style>pre span{{display:inline-block;height:{LINE}px;vertical-align:top}}</style>'
      f'<div style="position:relative;font:15px/{LINE}px Menlo,monospace">'
      f'<pre style="font:inherit;padding:{PAD}px;margin:0">\n' + ''.join(out) + '</pre>' + img + '</div></body></html>')
