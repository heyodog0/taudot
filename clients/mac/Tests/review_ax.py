# ax.py PID DESCRIPTION -> "x,y" centre (screen points) of the first AX element whose description or title is it.
import sys
from ApplicationServices import (AXUIElementCreateApplication, AXUIElementCopyAttributeValue, AXValueGetValue,
                                 kAXValueCGPointType, kAXValueCGSizeType)

def attr(e, name):
    err, v = AXUIElementCopyAttributeValue(e, name, None)
    return v if err == 0 else None

def walk(e, want, depth=0):
    if depth > 40:
        return None
    for k in ('AXDescription', 'AXTitle', 'AXPlaceholderValue', 'AXHelp'):
        if attr(e, k) == want:
            return e
    for c in attr(e, 'AXChildren') or []:
        r = walk(c, want, depth + 1)
        if r is not None:
            return r
    return None

app = AXUIElementCreateApplication(int(sys.argv[1]))
for w in attr(app, 'AXWindows') or []:
    e = walk(w, sys.argv[2])
    if e is not None:
        _, p = AXValueGetValue(attr(e, 'AXPosition'), kAXValueCGPointType, None)
        _, s = AXValueGetValue(attr(e, 'AXSize'), kAXValueCGSizeType, None)
        print(f"{round(p.x + s.width / 2)},{round(p.y + s.height / 2)}")
        break
