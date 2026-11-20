import re,sys,html
raw=open(sys.argv[1],'rb').read().decode('utf8','replace')
# keep only the last full frame (after the last clear-screen)
i=raw.rfind('\x1b[H\x1b[2J'); raw=raw[i+len('\x1b[H\x1b[2J'):] if i>=0 else raw
j=raw.find('\x1b[?25h'); raw=raw[:j] if j>=0 else raw
out=[]; fg=None; bg=None; b=False
pos=0
for m in re.finditer(r'\x1b\[([0-9;?]*)([a-zA-Z])|([^\x1b]+)',raw):
    if m.group(3) is not None:
        t=html.escape(m.group(3).replace('\r',''))
        st=[]
        if fg: st.append(f'color:{fg}')
        if bg: st.append(f'background:{bg}')
        if b: st.append('font-weight:700')
        out.append(f'<span style="{";".join(st)}">{t}</span>' if st else t); continue
    if m.group(2)!='m': continue
    ps=[int(x) for x in m.group(1).split(';') if x.isdigit()] or [0]
    k=0
    while k<len(ps):
        p=ps[k]
        if p==0: fg=bg=None;b=False
        elif p==1: b=True
        elif p==49: bg=None
        elif p==38 and ps[k+1]==2: fg='rgb(%d,%d,%d)'%tuple(ps[k+2:k+5]); k+=4
        elif p==48 and ps[k+1]==2: bg='rgb(%d,%d,%d)'%tuple(ps[k+2:k+5]); k+=4
        k+=1
print('<html><body style="margin:0;background:#151A22;color:#E9E6DF"><pre style="font:15px/1.2 Menlo,monospace;padding:10px;margin:0">'+''.join(out)+'</pre></body></html>')
