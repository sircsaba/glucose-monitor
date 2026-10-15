"""Adjusts the Flutter web project.

  python3 scripts/patch_web.py web    before the build: app name, colors, icon
  python3 scripts/patch_web.py build  after the build: relative base address, so the
                                      same files work at a server's root (/) and on
                                      GitHub Pages (/glucose-monitor/)
"""
import json
import os
import re
import shutil
import sys

name = os.environ.get("APP_NAME", "Glucose Monitor")
step = sys.argv[1] if len(sys.argv) > 1 else "web"

if step == "web":
    p = "web/index.html"
    s = open(p).read()
    s = re.sub(r"<title>.*?</title>", f"<title>{name}</title>", s, flags=re.S)
    s = re.sub(r'(name="apple-mobile-web-app-title" content=")[^"]*', r"\g<1>" + name, s)
    s = re.sub(r'(name="description" content=")[^"]*', r"\g<1>" + name, s)
    if 'name="theme-color"' not in s:
        s = s.replace("</head>", '  <meta name="theme-color" content="#0D1117">\n</head>')
    open(p, "w").write(s)

    p = "web/manifest.json"
    m = json.load(open(p))
    m.update(name=name, short_name=name, background_color="#0D1117", theme_color="#0D1117",
             description=name, display="standalone")
    json.dump(m, open(p, "w"), indent=2)

    icon = "assets/icon/icon.png"
    if os.path.exists(icon):
        shutil.copy(icon, "web/favicon.png")
        for f in os.listdir("web/icons"):
            shutil.copy(icon, os.path.join("web/icons", f))
    print("web project patched")

elif step == "build":
    p = "build/web/index.html"
    s = open(p).read()
    s, n = re.subn(r'<base href="/">', '<base href="./">', s)
    if n != 1:
        sys.exit("base href not found in build/web/index.html")
    open(p, "w").write(s)
    open("build/web/.nojekyll", "w").close()
    # No service worker: it keeps its own copy of the app in the browser, so an
    # update could stay hidden. The server always has the latest files.
    bp = "build/web/flutter_bootstrap.js"
    if os.path.exists(bp):
        b = open(bp).read()
        b2 = re.sub(r"serviceWorkerSettings\s*:\s*\{[^{}]*\}\s*,?", "", b)
        if b2 != b:
            open(bp, "w").write(b2)
            print("service worker registration removed")
    print("build patched")
