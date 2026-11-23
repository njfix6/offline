#!/usr/bin/env python3
"""Prints the crashed thread of the newest macOS crash report (CI helper)."""
import glob, json, os, sys

reports = sorted(
    glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/*.ips")),
    key=os.path.getmtime,
)
if not reports:
    print("no crash report found")
    sys.exit(0)
path = reports[-1]
print("crash report:", os.path.basename(path))
text = open(path, errors="replace").read()
try:
    body = json.loads(text.split("\n", 1)[1])
except Exception as error:  # not the JSON format: show the start of the file
    print("could not parse report:", error)
    print(text[:6000])
    sys.exit(0)
print("exception:", json.dumps(body.get("exception")))
images = body.get("usedImages", [])
for thread in body.get("threads", []):
    if not thread.get("triggered"):
        continue
    frames = thread.get("frames", [])
    print("crashed thread, %d frames (showing up to 70):" % len(frames))
    for frame in frames[:70]:
        index = frame.get("imageIndex", -1)
        image = images[index].get("name", "?") if 0 <= index < len(images) else "?"
        print("  %-28s %s + %s" % (image, frame.get("symbol", "?"), frame.get("symbolLocation", "?")))
