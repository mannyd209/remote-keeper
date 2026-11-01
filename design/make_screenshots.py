#!/usr/bin/env python3
"""Builds Remote Keeper's marketing screenshots (README, website) from raw captures.

  design/raw/phone-*.png   iPhone 18 Pro Max captures (1320x2868) of the web app's #demo mode
                            (made-up computers and sessions; never real ones)
  design/raw/mac-*.png     Mac window captures
  docs/screenshots/        framed screenshots: label pill, two-line headline, subline, device

Each phone shot is 1320x2868 (App Store 6.9" size); Mac shots are 2880x1800. Some scenes are
drawn in HTML (the restart alert and the encryption diagram). Rendered by headless Chrome.
Run:  python3 design/make_screenshots.py
"""
import html, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RAW = ROOT / "raw"
OUT = ROOT.parent / "docs" / "screenshots"
ICON = ROOT.parent / "web" / "icons" / "icon-512.png"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

PHONE = (1320, 2868)
MAC = (2880, 1800)

# (output, canvas, pill, [line1, line2], subline, scene, raw)
SHOTS = [
    ("01-reconnect", PHONE, "Remote Keeper for Claude Code", ["Remote Control off?", "One tap. Back on."],
     "Reconnect your Claude Code sessions from your phone", "phone", "phone-sessions.png"),
    ("02-alerts", PHONE, "Restart alerts", ["Claude restarted?", "You'll know."],
     "An alert, and a badge with how many sessions went offline", "alert", None),
    ("03-choose", PHONE, "Your sessions", ["Pick up to 10.", "We watch only those."],
     "Choose the sessions to keep connected on each computer", "phone", "phone-choose.png"),
    ("04-computers", PHONE, "Every computer", ["All your Macs.", "One app."],
     "Switch computers with a tap, and see every session back online", "phone", "phone-connected.png"),
    ("05-home-screen", PHONE, "No App Store needed", ["Scan, then add to", "your Home Screen."],
     "A bouncing arrow shows exactly where to tap in your browser", "phone", "phone-install.png"),
    ("06-private", PHONE, "Private by design", ["End-to-end", "encrypted."],
     "The relay can't read your sessions or fake a tap. And it's open source", "diagram", None),
    ("07-mac-setup", MAC, "One-time setup", ["Scan once.", "You're linked."],
     "Remote Keeper lives in your Mac's menu bar", "mac", "mac-setup.png"),
    ("08-mac-settings", MAC, "Guided setup", ["A setting off?", "One click fixes it."],
     "Buttons open the exact spot in System Settings or Claude", "mac", "mac-settings.png"),
]

STYLE = """
html,body{{margin:0;width:{w}px;height:{h}px;overflow:hidden}}
body{{font-family:-apple-system,"SF Pro Display","Helvetica Neue",Helvetica,sans-serif;color:#fff;
  background:radial-gradient({gw}px {gh}px at 50% 64%,rgba(139,127,255,.42),rgba(139,127,255,0) 70%),
             linear-gradient(160deg,#110D2B 0%,#1C1650 55%,#33279A 100%)}}
.grid{{position:absolute;inset:0;background-image:radial-gradient(rgba(255,255,255,.10) 2px,transparent 2.5px);
  background-size:{gs}px {gs}px;mask-image:linear-gradient(180deg,rgba(0,0,0,.9),rgba(0,0,0,0) 55%)}}
.wrap{{position:relative;padding:{top}px 60px 0;display:flex;flex-direction:column;align-items:center}}
.pill{{display:flex;align-items:center;gap:{u14}px;padding:{u12}px {u28}px {u12}px {u20}px;border-radius:999px;
  background:rgba(255,255,255,.10);box-shadow:inset 0 0 0 2px rgba(183,174,255,.28);
  font-size:{pill}px;font-weight:650;letter-spacing:.08em;text-transform:uppercase}}
.dot{{width:{u16}px;height:{u16}px;border-radius:50%;background:#8B7FFF;box-shadow:0 0 18px #8B7FFF}}
h1{{margin:{u28}px 0 0;font-size:{h1}px;line-height:1.03;font-weight:800;letter-spacing:-.025em;text-align:center}}
h1 .accent{{background:linear-gradient(90deg,#CFC8FF,#8B7FFF);-webkit-background-clip:text;color:transparent}}
p{{margin:{u24}px 0 0;font-size:{sub}px;line-height:1.25;font-weight:500;text-align:center;color:rgba(255,255,255,.78)}}
.dev{{box-sizing:border-box;background:#0B0B0C;
  box-shadow:0 0 0 2px rgba(255,255,255,.16),0 0 0 10px rgba(139,127,255,.12),0 50px 110px rgba(0,0,0,.6)}}
.dev img{{display:block;width:100%;height:auto}}
"""


def scale(w, h):
    s = w / 1320 if h > w else h / 1320 * 0.92
    s = min(s, 1.6)
    r = lambda v: round(v * s)
    return dict(w=w, h=h, gw=r(1100), gh=r(900), gs=r(56), top=r(150), pill=r(30), h1=r(112), sub=r(48),
                u12=r(12), u14=r(14), u16=r(16), u20=r(20), u24=r(24), u28=r(28)), s


def phone_frame(inner, w, s):
    """A phone outline around `inner` (HTML filling a 1320x2868 screen, scaled to fit)."""
    dw = round(w * 0.84)
    pad, rad = round(22 * s), round(190 * s)
    return (f'<div class="dev" style="margin-top:{round(80*s)}px;width:{dw}px;padding:{pad}px;border-radius:{rad}px">'
            f'<div style="position:relative;overflow:hidden;border-radius:{rad - pad}px;aspect-ratio:1320/2868">{inner}</div></div>')


def scene_html(scene, raw, w, h, s):
    if scene == "phone":
        return phone_frame(f'<img src="file://{raw}" style="width:100%">', w, s)
    if scene == "alert":
        # A lock screen with Remote Keeper's restart alert, and its app icon with a badge.
        u = (w * 0.84 - 2 * 22 * s) / 1320  # screen pixels per capture pixel
        q = lambda v: f"{round(v * u)}px"
        return phone_frame(f"""
<div style="position:absolute;inset:0;background:radial-gradient(120% 70% at 30% 20%,#5b4cf0,#1b1446 60%,#0c0a1f);color:#fff;text-align:center">
  <div style="margin-top:{q(330)};font-size:{q(84)};font-weight:600;opacity:.9">Saturday, November 1</div>
  <div style="font-size:{q(380)};font-weight:700;line-height:1;letter-spacing:-.02em">9:41</div>
  <div style="margin:{q(180)} {q(60)} 0;padding:{q(44)};border-radius:{q(70)};background:rgba(255,255,255,.18);
       -webkit-backdrop-filter:blur(30px);text-align:left;display:flex;gap:{q(36)};align-items:flex-start;box-shadow:0 {q(20)} {q(60)} rgba(0,0,0,.25)">
    <img src="file://{ICON}" style="width:{q(120)};height:{q(120)};border-radius:{q(28)};flex:none">
    <div style="flex:1">
      <div style="display:flex;justify-content:space-between;font-size:{q(52)};opacity:.75"><b style="font-weight:600">KEEPER</b><span>now</span></div>
      <div style="font-size:{q(60)};font-weight:700;margin-top:{q(8)}">Claude restarted on Studio MacBook Pro</div>
      <div style="font-size:{q(58)};margin-top:{q(6)};opacity:.92">Remote Control is off for 2 of your sessions. Tap to reconnect.</div>
    </div>
  </div>
  <div style="position:absolute;left:50%;bottom:{q(560)};transform:translateX(-50%)">
    <div style="position:relative;width:{q(300)};height:{q(300)}">
      <img src="file://{ICON}" style="width:100%;height:100%;border-radius:{q(68)};box-shadow:0 {q(30)} {q(80)} rgba(0,0,0,.45)">
      <div style="position:absolute;top:-{q(38)};right:-{q(38)};min-width:{q(110)};height:{q(110)};border-radius:{q(55)};background:#ff3b30;
           display:flex;align-items:center;justify-content:center;font-size:{q(68)};font-weight:700;box-shadow:0 {q(8)} {q(20)} rgba(0,0,0,.3)">2</div>
    </div>
    <div style="margin-top:{q(30)};font-size:{q(56)};font-weight:600">Keeper</div>
  </div>
</div>""", w, s)
    if scene == "diagram":
        u = s * 1.32
        q = lambda v: f"{round(v * u)}px"
        box = lambda title, sub, icon: f"""
<div style="width:{q(860)};padding:{q(44)} {q(50)};border-radius:{q(48)};background:rgba(255,255,255,.08);
     box-shadow:inset 0 0 0 2px rgba(183,174,255,.25);display:flex;gap:{q(36)};align-items:center">
  <div style="font-size:{q(96)};width:{q(130)};text-align:center">{icon}</div>
  <div style="text-align:left"><div style="font-size:{q(56)};font-weight:750">{title}</div>
  <div style="font-size:{q(40)};color:rgba(255,255,255,.72);margin-top:{q(8)}">{sub}</div></div>
</div>"""
        arrow = f'<div style="font-size:{q(80)};color:#8B7FFF;line-height:1;margin:{q(26)} 0">⇅</div>'
        chips = "".join(f'<span style="padding:{q(14)} {q(28)};border-radius:999px;background:rgba(139,127,255,.22);font-size:{q(38)};font-weight:600">{c}</span>'
                        for c in ["AES-256-GCM", "Key only in the QR code", "Open source (MIT)", "No account"])
        return f"""
<div style="margin-top:{q(150)};display:flex;flex-direction:column;align-items:center">
  {box("Your phone", "Seals every message with your key", "📱")}
  {arrow}
  {box("The relay", "Only passes along scrambled data", "🔒")}
  {arrow}
  {box("Your Mac", "Opens it, and types one fixed message", "💻")}
  <div style="margin-top:{q(90)};display:flex;flex-wrap:wrap;gap:{q(18)};justify-content:center;width:{q(1000)}">{chips}</div>
</div>"""
    if scene == "mac":
        # The window on a desktop, under a menu bar with Remote Keeper's icon highlighted.
        mw = round(w * 0.50)
        return f"""
<div style="position:relative;flex:none;width:{round(w*0.52)}px;height:{round(h*0.86)}px;border-radius:{round(28*s)}px;overflow:hidden;
     background:linear-gradient(150deg,#3a2c9a,#14102f);box-shadow:0 0 0 2px rgba(255,255,255,.14),0 50px 110px rgba(0,0,0,.6)">
  <div style="height:{round(56*s)}px;background:rgba(20,16,47,.55);-webkit-backdrop-filter:blur(20px);display:flex;align-items:center;
       justify-content:flex-end;gap:{round(30*s)}px;padding:0 {round(36*s)}px;font-size:{round(30*s)}px;font-weight:600;color:rgba(255,255,255,.9)">
    <span style="padding:{round(4*s)}px {round(12*s)}px;border-radius:{round(10*s)}px;background:rgba(255,255,255,.22)">↻</span><span>Sat 9:41 AM</span>
  </div>
  <img src="file://{raw}" style="position:absolute;left:50%;top:52%;transform:translate(-50%,-50%);width:{mw * 0.86}px;max-height:{round(h*0.72)}px;object-fit:contain;
       filter:drop-shadow(0 {round(30*s)}px {round(60*s)}px rgba(0,0,0,.55))">
</div>"""
    raise ValueError(scene)


def render(name, size, pill, lines, sub, scene, raw):
    w, h = size
    v, s = scale(w, h)
    raw = (RAW / raw).resolve() if raw else None
    head = f"""<div class="pill"><span class="dot"></span><span>{html.escape(pill)}</span></div>
    <h1>{html.escape(lines[0])}<br><span class="accent">{html.escape(lines[1])}</span></h1>
    <p>{html.escape(sub)}</p>"""
    if scene == "mac":
        body = f"""<div style="position:relative;height:{h}px;display:flex;align-items:center;gap:{round(70*s)}px;padding:0 {round(110*s)}px;box-sizing:border-box">
  <div style="flex:1;display:flex;flex-direction:column;align-items:flex-start">
    <style>h1,p{{text-align:left!important}} h1{{font-size:{round(v['h1']*0.86)}px!important}}</style>{head}</div>
  {scene_html(scene, raw, w, h, s)}</div>"""
    else:
        body = f'<div class="wrap">{head}{scene_html(scene, raw, w, h, s)}</div>'
    page = f'<!doctype html><html><head><meta charset="utf-8"><style>{STYLE.format(**v)}</style></head><body><div class="grid"></div>{body}</body></html>'
    with tempfile.TemporaryDirectory() as tmp:
        f = Path(tmp) / "page.html"
        f.write_text(page)
        shot = Path(tmp) / "shot.png"
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
                        f"--window-size={w},{h}", "--force-device-scale-factor=1", f"--screenshot={shot}", f"file://{f}"],
                       capture_output=True, text=True)
        if not shot.exists():
            raise SystemExit(f"render failed: {name}")
        OUT.mkdir(parents=True, exist_ok=True)
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "88", str(shot), "--out", str(OUT / f"{name}.jpg")],
                       capture_output=True)
    print("rendered", f"docs/screenshots/{name}.jpg")


if __name__ == "__main__":
    for shot in SHOTS:
        render(*shot)
