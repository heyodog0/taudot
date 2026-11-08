import sys, time
from ApplicationServices import AXUIElementCreateApplication, AXUIElementCopyAttributeValue, AXUIElementPerformAction, AXUIElementSetAttributeValue
from AppKit import NSWorkspace, NSRunningApplication
pid = int(sys.argv[1])
app = AXUIElementCreateApplication(pid)
for i in range(10):
    err, wins = AXUIElementCopyAttributeValue(app, 'AXWindows', None)
    AXUIElementPerformAction(wins[0], 'AXRaise')
    AXUIElementSetAttributeValue(wins[0], 'AXMain', True)
    AXUIElementSetAttributeValue(app, 'AXFrontmost', True)
    NSRunningApplication.runningApplicationWithProcessIdentifier_(pid).activateWithOptions_(2)
    time.sleep(0.25)
    if NSWorkspace.sharedWorkspace().frontmostApplication().processIdentifier() == pid:
        print('front', i); sys.exit(0)
print('not front'); sys.exit(1)
