#!/usr/bin/env python3
"""Probe latest-client handoff using a native PTY and an isolated tmux server.

Run locally, or pipe this file to python3 over SSH. This checks native tmux
focus/key behavior; RemoteTmuxLegacySizingTests checks the production app path.
CMUX_TMUX_BINARY may select a specific server binary. Every command retains the
unique -L socket; cleanup never targets the user's default server.
"""
import os, subprocess, fcntl, termios, struct, time, select, uuid, threading, shutil
prefix=[os.environ.get('CMUX_TMUX_BINARY') or shutil.which('tmux') or '/usr/bin/tmux','-L','cmux-native-sizing-'+uuid.uuid4().hex,'-f','/dev/null']
def tmux(*args):
    p=subprocess.run(prefix+list(args), text=True, capture_output=True, timeout=10)
    if p.returncode: raise RuntimeError((args,p.stderr))
    return p.stdout.strip()
control=None; native=None; master=None
try:
    print(tmux('-V'), flush=True)
    tmux('new-session','-d','-s','sizing','-x','188','-y','50','sleep 90')
    tmux('set-option','-g','window-size','latest')
    tmux('set-option','-g','focus-events','on')
    tmux('set-option','-g','status-left','CMUX_NATIVE_READY')
    tmux('set-option','-g','status-left-length','30')
    tmux('bind-key','-n','F12','wait-for','-S','cmux-native-key')
    w=tmux('display-message','-p','-t','sizing','#{window_id}')
    control=subprocess.Popen(prefix+['-C','attach-session','-t','sizing'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
    buf=bytearray()
    def read_block():
        deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            while b'\n' in buf:
                line,_,rest=buf.partition(b'\n');buf[:]=rest
                if line.startswith(b'%error'):raise RuntimeError(line.decode())
                if line.startswith(b'%end'):return
            if not select.select([control.stdout],[],[],max(0,deadline-time.monotonic()))[0]:break
            data=os.read(control.stdout.fileno(),65536)
            if not data:raise RuntimeError('control ended')
            buf.extend(data)
        raise RuntimeError('control reply timeout')
    read_block()
    def send(cmd):
        control.stdin.write(cmd.encode()+b'\n');read_block()
    send('refresh-client -C 139x36')
    master,slave=os.openpty()
    fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',50,188,0,0))
    def setup():
        os.setsid();fcntl.ioctl(0,termios.TIOCSCTTY,0)
    native=subprocess.Popen(prefix+['attach-session','-t','sizing'],stdin=slave,stdout=slave,stderr=slave,preexec_fn=setup,env={**os.environ,'TERM':'xterm-256color'})
    os.close(slave)
    screen=bytearray();deadline=time.monotonic()+10
    while b'CMUX_NATIVE_READY' not in screen:
        if not select.select([master],[],[],max(0,deadline-time.monotonic()))[0]:raise RuntimeError(('native attach timeout', native.poll(), repr(screen[-500:])))
        screen.extend(os.read(master,65536))
    def drain():
        try:
            while os.read(master,65536):pass
        except OSError:pass
    threading.Thread(target=drain,daemon=True).start()
    def grid():return tmux('display-message','-p','-t',w,'#{window_width}x#{window_height}')
    def claim(cols):
        for cmd in ["refresh-client -f '!ignore-size'",f'set-option -w -t {w} window-size latest',f'select-window -t sizing:{w}',f'refresh-client -C {cols}x36']:send(cmd)
    claim(139);assert grid()=='139x36',grid();print('cmux claim: 139x36',flush=True)
    os.write(master,b'x\x1b[24~');tmux('wait-for','cmux-native-key')
    assert grid()=='188x49',grid();print('native actual key: 188x49',flush=True)
    send('refresh-client -f ignore-size');send('refresh-client -C 120x36')
    assert grid()=='188x49',grid();print('background replay: native stays 188x49',flush=True)
    claim(120);assert grid()=='120x36',grid();print('cmux reclaim: 120x36',flush=True)
    send('display-message -p cmux-focus-fence')
    os.write(master,b'\x1b[I')
    deadline=time.monotonic()+10
    seen=False
    while not seen and time.monotonic()<deadline:
        while b'\n' in buf:
            line,_,rest=buf.partition(b'\n');buf[:]=rest
            if line.startswith(b'%layout-change '+w.encode()+b' ') and b',188x49,' in line:
                seen=True;break
        if seen:break
        if not select.select([control.stdout],[],[],max(0,deadline-time.monotonic()))[0]:break
        buf.extend(os.read(control.stdout.fileno(),65536))
    assert seen,'native focus-in did not publish wide layout' 
    assert grid()=='188x49',grid();print('native actual focus-in: 188x49',flush=True)
    send('refresh-client -C 120x36');assert grid()=='188x49',grid()
    claim(139);assert grid()=='139x36',grid()
    print('PASS: native key/focus, background replay, unchanged cmux reclaim',flush=True)
finally:
    if control:
        control.terminate()
        try:control.wait(timeout=3)
        except subprocess.TimeoutExpired:control.kill();control.wait()
    if native:
        native.terminate()
        try:native.wait(timeout=3)
        except subprocess.TimeoutExpired:native.kill();native.wait()
    if master is not None:os.close(master)
    try:tmux('kill-server')
    except Exception:pass
