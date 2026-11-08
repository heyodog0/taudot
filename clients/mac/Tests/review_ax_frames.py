# review_ax_frames.py PID: JSON of what the add-comment test needs from Accessibility: the window, the split group,
# its splitters (the editor sits between the first two), the Comment pill, the new-comment field.
import sys, json
from ApplicationServices import AXUIElementCreateApplication, AXUIElementCopyAttributeValue, AXValueGetValue, kAXValueCGPointType, kAXValueCGSizeType

def attr(e, n):
    err, v = AXUIElementCopyAttributeValue(e, n, None); return v if err == 0 else None
def frame(e):
    p, s = attr(e, 'AXPosition'), attr(e, 'AXSize')
    if not p or not s: return None
    p = AXValueGetValue(p, kAXValueCGPointType, None)[1]; s = AXValueGetValue(s, kAXValueCGSizeType, None)[1]
    return [p.x, p.y, s.width, s.height]
out = {'splitters': []}
def walk(e, d=0):
    if d > 30: return
    role, desc = attr(e, 'AXRole'), attr(e, 'AXDescription') or ''
    if role == 'AXSplitGroup' and 'split' not in out: out['split'] = frame(e)
    if role == 'AXSplitter': out['splitters'].append(frame(e))
    if desc == 'Comment' and role == 'AXButton': out['pill'] = frame(e)
    if desc == 'Add a comment': out['field'] = frame(e)
    for c in attr(e, 'AXChildren') or []: walk(c, d + 1)
app = AXUIElementCreateApplication(int(sys.argv[1]))
for w in attr(app, 'AXWindows') or []:
    out['window'] = frame(w); walk(w); break
print(json.dumps(out))
