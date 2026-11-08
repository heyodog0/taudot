# MIT. Where a paragraph pass spends its time: Time Profiler samples (xctrace export of the time-profile table) of
# the pass processes only (pids from tau-live's TAU_LIVE_LOG "B ... warm" lines), by leaf function and inclusive.
#   uv run --no-project tests/prof.py PROF.xml LIVE.log
import collections
import re
import sys
import xml.etree.ElementTree as ET

xml_path, log = sys.argv[1], sys.argv[2]
passes = set()
for line in open(log):
    f = line.split()
    if len(f) > 7 and f[2] == "B" and f[7] == "warm" and "tid" in f:
        passes.add(int(f[f.index("tid") + 1]))  # thread ids are never reused (pids are, at this fork rate)

# Phases, by what is on the stack (first match), and the top leaves of each
PHASES = [("setup (orders, text)", ("para_setup",)), ("parked: pre-touch", ("fork_warm", "pretouch", "pretouch_hot")),
          ("stop signal + after", ("magic",)), ("exit (no stop)", ("uexit", "jumpout", "exit")),
          ("ship (\\shipout)", ("zpdfshipout", "zshipout", "shipout")),
          ("line breaking", ("zlinebreak", "zpostlinebreak", "ztrybreak")),
          ("page builder / \\output", ("zbuildpage", "zfireup", "buildpage", "fireup")),
          ("reading lines", ("input_line",)), ("expansion", ("expand", "macrocall")), ("other", ())]
phase, phase_leaf = collections.Counter(), collections.defaultdict(collections.Counter)

ids = {}
under = collections.Counter()
shipstack = collections.Counter()
leaf, incl, n = collections.Counter(), collections.Counter(), 0
for ev, el in ET.iterparse(xml_path, events=("end",)):
    if "id" in el.attrib:
        ids[el.attrib["id"]] = el
    if el.tag != "row":
        continue
    th = el.find("thread")
    if th is not None and "ref" in th.attrib:
        th = ids[th.attrib["ref"]]
    tid_el = th.find("tid") if th is not None else None
    if tid_el is not None and "ref" in tid_el.attrib:
        tid_el = ids[tid_el.attrib["ref"]]
    tid = int(tid_el.text) if tid_el is not None and tid_el.text else -1
    if tid in passes:
        bt = el.find("tagged-backtrace")
        bt = bt if bt is not None else el.find("backtrace")
        if bt is not None and "ref" in bt.attrib:
            bt = ids[bt.attrib["ref"]]
        frames = []
        if bt is not None:
            for fr in bt.iter("frame"):
                if "ref" in fr.attrib:
                    fr = ids[fr.attrib["ref"]]
                frames.append(fr.attrib.get("name", "?"))
        n += 1
        fs = set(frames)
        for nm, keys in PHASES:
            if not keys or fs & set(keys):
                phase[nm] += 1
                if frames:
                    phase_leaf[nm][frames[0]] += 1
                break
        if "pdfhlistout" in fs:
            k = frames.index("pdfhlistout")
            shipstack[" > ".join(reversed(frames[max(0, k - 5):k]))] += 1
        if frames and not fs & {"magic", "fork_warm", "uexit", "para_setup"} and "maincontrol" in fs:
            k = frames.index("maincontrol")
            under[" > ".join(reversed(frames[max(0, k - 3):k]))] += 1
        if frames:
            leaf[frames[0]] += 1
            for name in set(frames):
                incl[name] += 1


print(f"{n} samples (1 ms each) in {len(passes)} passes")
print("leaf:")
for k, v in leaf.most_common(25):
    print(f"  {v:5d} {100 * v / max(n, 1):5.1f}%  {k}")
print("inclusive (TeX and libtau functions):")
for k, v in incl.most_common(60):
    if re.match(r"^(main|start|mainbody|maincontrol|_?pthread|<|0x)", k):
        continue
    print(f"  {v:5d} {100 * v / max(n, 1):5.1f}%  {k}")

print("phases:")
for k, v in phase.most_common():
    top = ", ".join(f"{a} {b}" for a, b in phase_leaf[k].most_common(4))
    print(f"  {v:5d} {100 * v / max(n, 1):5.1f}%  {k}: {top}")

# under main_control: the frame just above it (what TeX was doing), for TeX-work samples

print("TeX work, by the 3 frames above main_control:")
for k, v in under.most_common(25):
    print(f"  {v:5d}  {k}")

print("under pdf_hlist_out (5 frames):")
for k, v in shipstack.most_common(12):
    print(f"  {v:5d}  {k}")
