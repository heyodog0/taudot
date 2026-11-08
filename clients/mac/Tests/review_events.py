# review_events.py PID CMD ...: input for one process. Keys go to it alone (CGEventPostToPid), so they can't land in
# another app. Mouse events must go through the window server (an event posted to a process has no window), so
# they are sent only when every point is over a window of PID. CMD: click X,Y | drag X1,Y1 X2,Y2 |
# key CODE [cmd,opt,shift] | type TEXT | flick X,Y DY N [momentum] (a trackpad gesture: N finger events of DY
# points at 120 Hz with scroll phases, then momentum decaying from DY, like the shell's Bench but real events)
import sys, time
import Quartz as Q

pid = int(sys.argv[1])
cmd = sys.argv[2]

def post(e):
    Q.CGEventPostToPid(pid, e)
    time.sleep(0.02)

def owner(x, y):
    # The frontmost on-screen window containing the point (CG's list is front to back).
    for w in Q.CGWindowListCopyWindowInfo(Q.kCGWindowListOptionOnScreenOnly | Q.kCGWindowListExcludeDesktopElements, Q.kCGNullWindowID):
        b = w.get('kCGWindowBounds'); layer = w.get('kCGWindowLayer', 0)
        if layer != 0 or not b: continue
        if b['X'] <= x < b['X'] + b['Width'] and b['Y'] <= y < b['Y'] + b['Height']:
            return w.get('kCGWindowOwnerPID')
    return None

def guard(*pts):
    for x, y in pts:
        if owner(x, y) != pid:
            sys.exit(f'not sending: {x:.0f},{y:.0f} is not over a window of {pid}')

def mouse(t, x, y, clicks=1):
    e = Q.CGEventCreateMouseEvent(None, t, (x, y), Q.kCGMouseButtonLeft)
    Q.CGEventSetIntegerValueField(e, Q.kCGMouseEventClickState, clicks)
    Q.CGEventPost(Q.kCGHIDEventTap, e)
    time.sleep(0.02)

def pt(s):
    x, y = s.split(','); return float(x), float(y)

if cmd == 'click':
    x, y = pt(sys.argv[3])
    guard((x, y))
    mouse(Q.kCGEventMouseMoved, x, y); mouse(Q.kCGEventLeftMouseDown, x, y); mouse(Q.kCGEventLeftMouseUp, x, y)
elif cmd == 'drag':
    (x1, y1), (x2, y2) = pt(sys.argv[3]), pt(sys.argv[4])
    guard((x1, y1), (x2, y2))
    mouse(Q.kCGEventMouseMoved, x1, y1); mouse(Q.kCGEventLeftMouseDown, x1, y1)
    for i in range(1, 21):
        f = i / 20
        mouse(Q.kCGEventLeftMouseDragged, x1 + (x2 - x1) * f, y1 + (y2 - y1) * f)
        time.sleep(0.01)
    mouse(Q.kCGEventLeftMouseUp, x2, y2)
elif cmd == 'key':
    code = int(sys.argv[3])
    mods = sys.argv[4].split(',') if len(sys.argv) > 4 else []
    flags = 0
    for m, f in (('cmd', Q.kCGEventFlagMaskCommand), ('opt', Q.kCGEventFlagMaskAlternate), ('shift', Q.kCGEventFlagMaskShift)):
        if m in mods: flags |= f
    for down in (True, False):
        e = Q.CGEventCreateKeyboardEvent(None, code, down)
        Q.CGEventSetFlags(e, flags)
        post(e)
elif cmd == 'flick':
    x, y = pt(sys.argv[3]); dy = float(sys.argv[4]); n = int(sys.argv[5])
    momentum = len(sys.argv) > 6 and sys.argv[6] == 'momentum'
    guard((x, y))
    def scroll(d, phase, mom):
        e = Q.CGEventCreateScrollWheelEvent2(None, Q.kCGScrollEventUnitPixel, 1, int(round(d)), 0, 0)
        Q.CGEventSetIntegerValueField(e, Q.kCGScrollWheelEventIsContinuous, 1)
        Q.CGEventSetIntegerValueField(e, Q.kCGScrollWheelEventScrollPhase, phase)
        Q.CGEventSetIntegerValueField(e, Q.kCGScrollWheelEventMomentumPhase, mom)
        Q.CGEventSetDoubleValueField(e, Q.kCGScrollWheelEventPointDeltaAxis1, d)
        Q.CGEventSetDoubleValueField(e, Q.kCGScrollWheelEventFixedPtDeltaAxis1, d)
        Q.CGEventSetLocation(e, (x, y))
        Q.CGEventPost(Q.kCGHIDEventTap, e)
    mouse(Q.kCGEventMouseMoved, x, y)
    scroll(0, 128, 0)                       # may begin
    scroll(dy, 1, 0)                        # began
    for _ in range(n):
        time.sleep(1 / 120); scroll(dy, 2, 0)   # changed
    scroll(0, 4, 0)                         # ended
    if momentum:
        d = dy; first = True
        while abs(d) > 0.5:
            time.sleep(1 / 120); scroll(d, 0, 1 if first else 2); first = False
            d *= 0.95
        scroll(0, 0, 3)
elif cmd == 'type':
    for ch in sys.argv[3]:
        for down in (True, False):
            e = Q.CGEventCreateKeyboardEvent(None, 0, down)
            Q.CGEventKeyboardSetUnicodeString(e, len(ch), ch)
            post(e)
