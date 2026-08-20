#!/usr/bin/env python3
"""
Generate the README artwork.

Every figure is emitted twice, once per GitHub canvas colour, so the README can
pair them in a <picture> element and neither theme gets a washed-out image. The
application mockups are drawn from the real WPF geometry in
src/AutoVM.App/MainWindow.xaml, so what the README shows is what ships.

Usage:  python3 docs/assets/build-assets.py
"""
from pathlib import Path
from xml.sax.saxutils import escape

OUT = Path(__file__).resolve().parent

SANS = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
MONO = "ui-monospace,SFMono-Regular,'SF Mono',Menlo,Consolas,'Liberation Mono',monospace"

# GitHub's own canvas colours, so the figures sit flush against the page.
THEMES = {
    "light": dict(
        canvas="#ffffff", panel="#f6f8fc", panel2="#eceff5", line="#d5dbe6",
        text="#0e1726", muted="#55627a", faint="#8592ab",
        accent="#2a78d6", accentSoft="#e8f0fd", accentLine="#b9d3f5",
        ok="#0a7c52", okSoft="#e6f6ef", warn="#b4650a", warnSoft="#fdf3e3",
        bad="#c8302a", badSoft="#fdecea", grid="#e9edf4",
    ),
    "dark": dict(
        canvas="#0d1117", panel="#161b22", panel2="#1b2230", line="#2b3444",
        text="#e6edf7", muted="#9aa8bf", faint="#6e7c95",
        accent="#3987e5", accentSoft="#14243c", accentLine="#28456e",
        ok="#3fd69b", okSoft="#10281f", warn="#e0a44a", warnSoft="#2a2013",
        bad="#ff7b6e", badSoft="#2c1614", grid="#1d2430",
    ),
}

# The application's own palette, from MainWindow.xaml. The app is dark either way,
# so the mockups use one set of colours in both themes.
APP = dict(
    ink="#0b1020", side="#080d1b", panel="#131b32", panel2="#18213c", field="#0e1730",
    line="#26314f", text="#e8eef9", muted="#93a3c0", faint="#6c7da0",
    accent="#3e8bff", ok="#3fd69b", warn="#f0b84e", bad="#ff6b5e",
)


# --------------------------------------------------------------------- helpers
def svg(w, h, body, defs=""):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" '
        f'role="img" font-family="{SANS}">\n{defs}\n{body}\n</svg>\n'
    )


def rect(x, y, w, h, fill, r=0, stroke=None, sw=1, opacity=None, extra=""):
    s = f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}"'
    if stroke:
        s += f' stroke="{stroke}" stroke-width="{sw}"'
    if opacity is not None:
        s += f' opacity="{opacity}"'
    return s + f" {extra}/>"


def text(x, y, s, fill, size=14, weight=400, anchor="start", family=None, spacing=None, opacity=None):
    f = family or SANS
    t = f'<text x="{x}" y="{y}" fill="{fill}" font-size="{size}" font-weight="{weight}" ' \
        f'text-anchor="{anchor}" font-family="{f}"'
    if spacing:
        t += f' letter-spacing="{spacing}"'
    if opacity is not None:
        t += f' opacity="{opacity}"'
    return t + f">{escape(s)}</text>"


def mono(x, y, s, fill, size=12, weight=400, anchor="start", spacing=None, opacity=None):
    return text(x, y, s, fill, size, weight, anchor, MONO, spacing, opacity)


def label(x, y, s, fill, size=10.5):
    """Small uppercase eyebrow used to title a block."""
    return mono(x, y, s.upper(), fill, size, 600, spacing="0.14em")


def line_(x1, y1, x2, y2, stroke, sw=1, dash=None, cap="butt"):
    s = f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{stroke}" stroke-width="{sw}" stroke-linecap="{cap}"'
    if dash:
        s += f' stroke-dasharray="{dash}"'
    return s + "/>"


def chip(x, y, s, fg, bg, border=None, size=11.5, pad=11, h=24, family=None):
    """A pill. Width is estimated from the string, with slack for font fallback."""
    w = int(len(s) * (size * 0.60 if family == MONO else size * 0.56)) + pad * 2
    out = [rect(x, y, w, h, bg, r=h // 2, stroke=border, sw=1)]
    out.append(text(x + pad, y + h / 2 + size * 0.36, s, fg, size, 600, family=family))
    return "".join(out), w


def arrow_down(x, y1, y2, stroke, sw=1.6):
    return (line_(x, y1, x, y2 - 7, stroke, sw)
            + f'<path d="M{x - 4.5},{y2 - 8} L{x},{y2 - 1} L{x + 4.5},{y2 - 8} Z" fill="{stroke}"/>')


def arrow_right(x1, x2, y, stroke, sw=1.6):
    return (line_(x1, y, x2 - 7, y, stroke, sw)
            + f'<path d="M{x2 - 8},{y - 4.5} L{x2 - 1},{y} L{x2 - 8},{y + 4.5} Z" fill="{stroke}"/>')


def window_chrome(x, y, w, h, title, t=APP):
    """Rounded application window with a title bar."""
    out = [
        rect(x, y, w, h, t["ink"], r=10, stroke=t["line"], sw=1),
        f'<path d="M{x},{y + 10} a10,10 0 0 1 10,-10 h{w - 20} a10,10 0 0 1 10,10 v22 h-{w} z" fill="{t["panel"]}"/>',
        line_(x, y + 32, x + w, y + 32, t["line"], 1),
    ]
    for i, c in enumerate(("#ff5f57", "#febc2e", "#28c840")):
        out.append(f'<circle cx="{x + 18 + i * 15}" cy="{y + 16}" r="5" fill="{c}"/>')
    out.append(text(x + w / 2, y + 21, title, t["muted"], 12, 500, anchor="middle"))
    return "".join(out)


# ------------------------------------------------------------------------ hero
def hero(t):
    W, H = 1280, 400
    defs = f'''<defs>
  <linearGradient id="hg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="{t["accent"]}" stop-opacity="0.16"/>
    <stop offset="0.55" stop-color="{t["accent"]}" stop-opacity="0.03"/>
    <stop offset="1" stop-color="{t["accent"]}" stop-opacity="0"/>
  </linearGradient>
  <linearGradient id="wordmark" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="{t["text"]}"/>
    <stop offset="1" stop-color="{t["accent"]}"/>
  </linearGradient>
  <pattern id="grid" width="32" height="32" patternUnits="userSpaceOnUse">
    <path d="M32 0 L0 0 0 32" fill="none" stroke="{t["line"]}" stroke-width="0.7" opacity="0.5"/>
  </pattern>
  <mask id="gridfade"><rect width="{W}" height="{H}" fill="url(#gf)"/></mask>
  <linearGradient id="gf" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#fff" stop-opacity="0.55"/>
    <stop offset="1" stop-color="#fff" stop-opacity="0"/>
  </linearGradient>
</defs>'''

    b = [
        rect(0, 0, W, H, t["canvas"], r=0),
        f'<rect width="{W}" height="{H}" fill="url(#grid)" mask="url(#gridfade)"/>',
        f'<rect width="{W}" height="{H}" fill="url(#hg)"/>',
        rect(0.5, 0.5, W - 1, H - 1, "none", r=14, stroke=t["line"], sw=1),
    ]

    # ---- left column
    x = 64
    b.append(label(x, 74, "windows  ·  one click  ·  unattended", t["accent"]))
    b.append(text(x, 152, "AutoVM", "url(#wordmark)", 64, 800, spacing="-0.02em"))
    b.append(text(x, 196, "Autonomously creates a virtual machine of your choosing.",
                  t["text"], 21, 500))
    b.append(text(x, 228, "Type the login and password you want inside it. AutoVM measures the",
                  t["muted"], 15))
    b.append(text(x, 250, "device, sizes a machine that fits, and installs it without a single prompt.",
                  t["muted"], 15))

    cx = x
    for s in ("Sizes itself to your PC", "Verified images", "Nothing deleted by default"):
        c, w = chip(cx, 286, s, t["muted"], t["panel"], t["line"], 12)
        b.append(c)
        cx += w + 8

    b.append(mono(x, 344, "30–90 min", t["text"], 15, 700))
    b.append(text(x + 86, 344, "mostly unattended", t["faint"], 13))
    b.append(line_(x + 196, 330, x + 196, 350, t["line"], 1))
    b.append(mono(x + 216, 344, "~45 GB", t["text"], 15, 700))
    b.append(text(x + 286, 344, "free disk", t["faint"], 13))
    b.append(line_(x + 350, 330, x + 350, 350, t["line"], 1))
    b.append(mono(x + 370, 344, "0", t["text"], 15, 700))
    b.append(text(x + 382, 344, "installer questions", t["faint"], 13))

    # ---- right column: device -> plan -> machine
    px, pw = 720, 496
    rows = [
        ("this device", t["muted"], [("8 GB", "memory"), ("8 cores", "processor"), ("240 GB", "free")]),
        ("autovm plans it", t["accent"], [("3072 MB", "38% of host"), ("4 vCPU", "half the cores"), ("60 GB", "on C:")]),
        ("your machine", t["ok"], [("Kali Linux", "running"), ("Analyst", "sign in as"), ("Snapshot", "restore point taken")]),
    ]
    y = 62
    for i, (head, colour, cells) in enumerate(rows):
        h = 88
        fill = t["panel"] if i != 1 else t["accentSoft"]
        edge = t["line"] if i != 1 else t["accentLine"]
        b.append(rect(px, y, pw, h, fill, r=12, stroke=edge, sw=1))
        b.append(rect(px, y + 14, 3, h - 28, colour, r=2))
        b.append(label(px + 22, y + 28, head, colour))
        for j, (big, small) in enumerate(cells):
            cxx = px + 22 + j * 160
            b.append(text(cxx, y + 58, big, t["text"], 19, 700))
            b.append(text(cxx, y + 76, small, t["faint"], 11.5))
        if i < 2:
            b.append(arrow_down(px + pw / 2, y + h + 2, y + h + 22, t["faint"], 1.4))
        y += h + 24

    return svg(W, H, "\n".join(b), defs)


# ------------------------------------------------------------------------ flow
def flow(t):
    W, H = 1280, 430
    b = [rect(0, 0, W, H, t["canvas"])]

    b.append(label(40, 40, "what you do  ·  six screens", t["accent"]))
    steps = [
        ("1", "Welcome", "read what it will do"),
        ("2", "This device", "it checks and reports"),
        ("3", "Your account", "login + password"),
        ("4", "Review", "nothing changed yet"),
        ("5", "Building", "leave it running"),
        ("6", "Ready", "control panel on desktop"),
    ]
    bw, gap = 182, 18
    x = 40
    for i, (n, title, sub) in enumerate(steps):
        fill = t["panel"]
        edge = t["line"]
        b.append(rect(x, 58, bw, 86, fill, r=10, stroke=edge, sw=1))
        b.append(f'<circle cx="{x + 24}" cy="{82}" r="12" fill="{t["accent"]}"/>')
        b.append(text(x + 24, 87, n, "#ffffff", 12.5, 700, anchor="middle"))
        b.append(text(x + 44, 87, title, t["text"], 15, 700))
        b.append(text(x + 16, 118, sub, t["muted"], 12))
        if i < len(steps) - 1:
            b.append(arrow_right(x + bw + 2, x + bw + gap - 2, 101, t["faint"], 1.4))
        x += bw + gap

    b.append(line_(40, 178, W - 40, 178, t["line"], 1))

    b.append(label(40, 208, "what it does  ·  seven phases, each proved before the next starts", t["muted"]))
    phases = [
        ("P1", "Profile", "gates evaluated", t["accent"]),
        ("P2", "Clean up", "skipped by default", t["faint"]),
        ("P3", "Hypervisor", "VirtualBox 7.x", t["accent"]),
        ("P4", "Image", "SHA-256 verified", t["accent"]),
        ("P5", "Install", "unattended", t["warn"]),
        ("P6", "Verify", "sign in + snapshot", t["ok"]),
        ("P7", "Hand over", "desktop shortcut", t["ok"]),
    ]
    pw = 156
    x = 40
    for i, (pid, title, sub, colour) in enumerate(phases):
        b.append(rect(x, 226, pw, 78, t["panel"], r=10, stroke=t["line"], sw=1))
        b.append(rect(x, 226, pw, 3, colour, r=2))
        b.append(mono(x + 16, 254, pid, colour, 11, 700, spacing="0.1em"))
        b.append(text(x + 16, 276, title, t["text"], 14.5, 700))
        b.append(text(x + 16, 294, sub, t["faint"], 11.5))
        if i < len(phases) - 1:
            b.append(arrow_right(x + pw + 1, x + pw + 15, 265, t["faint"], 1.3))
        x += pw + 16

    # failure rail
    b.append(rect(40, 326, W - 80, 62, t["badSoft"], r=10, stroke=t["bad"], sw=1, opacity=0.9))
    b.append(label(58, 350, "if a phase cannot prove it worked", t["bad"]))
    b.append(text(58, 372,
                  "AutoVM stops, names the step, and says what to do about it. Work already finished is recorded, "
                  "so starting again continues instead of repeating.", t["text"], 13))
    return svg(W, H, "\n".join(b))


# ---------------------------------------------------------------------- sizing
def sizing(t):
    """
    How the guest is sized. One series (guest memory), so no legend for it - the
    title names it. The two rules that shape the curve are reference lines, not
    a second series.
    """
    W, H = 1180, 500
    b = [rect(0, 0, W, H, t["canvas"])]

    b.append(text(40, 46, "What AutoVM gives the guest, by how much memory the PC has",
                  t["text"], 19, 700))
    b.append(text(40, 70, "Guest memory in MB. Two rules shape it: never more than half the host, never more than 8192 MB.",
                  t["muted"], 13))

    px, py, pw, ph = 92, 112, W - 92 - 60, 250
    ymax = 9216.0

    def ypx(v):
        return py + ph - (v / ymax) * ph

    for gv in (0, 2048, 4096, 6144, 8192):
        yy = ypx(gv)
        b.append(line_(px, yy, px + pw, yy, t["grid"], 1))
        b.append(mono(px - 12, yy + 4, f"{gv:,}", t["faint"], 11, anchor="end"))
    b.append(mono(px - 12, py - 12, "MB", t["faint"], 11, anchor="end"))
    b.append(line_(px, py, px, py + ph, t["line"], 1))
    b.append(line_(px, py + ph, px + pw, py + ph, t["line"], 1))

    # (host label, host MB, guest MB, logical cores, vCPU)
    data = [
        ("4 GB PC", 4096, 2048, 4, 2),
        ("8 GB PC", 8192, 3072, 8, 4),
        ("16 GB PC", 16384, 6144, 8, 4),
        ("32 GB PC", 32768, 8192, 16, 4),
        ("64 GB PC", 65536, 8192, 16, 4),
    ]

    cap_y = ypx(8192)
    b.append(line_(px, cap_y, px + pw, cap_y, t["warn"], 1.4, dash="6 5"))
    b.append(mono(px + 10, cap_y - 9, "8192 MB cap", t["warn"], 11, 600))

    slot = pw / len(data)
    bw = 82
    for i, (name, host_mb, guest_mb, cores, vcpu) in enumerate(data):
        cx = px + slot * i + slot / 2
        x0, y0 = cx - bw / 2, ypx(guest_mb)
        b.append(f'<path d="M{x0},{py + ph} L{x0},{y0 + 4} q0,-4 4,-4 h{bw - 8} q4,0 4,4 '
                 f'L{x0 + bw},{py + ph} Z" fill="{t["accent"]}"/>')

        # the half-of-host ceiling, only when it is on the scale
        half = host_mb / 2
        if half <= ymax:
            hy = ypx(half)
            b.append(line_(x0 - 12, hy, x0 + bw + 12, hy, t["muted"], 1.5, dash="5 4"))

        share = round(100 * guest_mb / host_mb)
        b.append(text(cx, y0 - 12, f"{guest_mb:,}", t["text"], 16, 700, anchor="middle"))
        b.append(text(cx, y0 + 22, f"{share}%", "#ffffff", 12, 700, anchor="middle"))
        b.append(text(cx, py + ph + 26, name, t["text"], 13.5, 600, anchor="middle"))
        b.append(mono(cx, py + ph + 45, f"{cores} cores", t["faint"], 11, anchor="middle"))
        b.append(mono(cx, py + ph + 62, f"{vcpu} vCPU", t["accent"], 11, 600, anchor="middle"))

    # reference-line key, out of the plot
    b.append(line_(W - 232, 66, W - 210, 66, t["muted"], 1.5, dash="5 4"))
    b.append(text(W - 202, 70, "half of that device", t["muted"], 11.5))

    b.append(rect(40, 444, W - 80, 44, t["panel"], r=10, stroke=t["line"], sw=1))
    b.append(text(58, 471,
                  "A 4 GB PC is held at the guest minimum, which is also its ceiling. From 32 GB up the cap takes over, "
                  "so the rest of the machine stays yours.", t["muted"], 13))
    return svg(W, H, "\n".join(b))


# ---------------------------------------------------------------- architecture
def architecture(t):
    W, H = 1180, 372
    b = [rect(0, 0, W, H, t["canvas"])]
    b.append(text(40, 44, "How it fits together", t["text"], 19, 700))
    b.append(text(40, 68, "The engine never talks to the window. It emits records; the wizard is one listener, a script is another.",
                  t["muted"], 13))

    layers = [
        ("AutoVM.exe", "C# launcher — one icon, one elevation prompt", t["faint"]),
        ("AutoVM.ps1  +  MainWindow.xaml", "WPF wizard — six screens, no engine logic of its own", t["accent"]),
        ("AutoVM module", "seven phases · gates · planning · resume ledger · VirtualBox driver", t["ok"]),
        ("VBoxManage  ·  winget", "the only external commands AutoVM runs", t["faint"]),
    ]
    x, w = 40, 720
    y = 96
    for i, (title, sub, colour) in enumerate(layers):
        b.append(rect(x, y, w, 56, t["panel"], r=10, stroke=t["line"], sw=1))
        b.append(rect(x, y + 12, 3, 32, colour, r=2))
        b.append(text(x + 22, y + 26, title, t["text"], 14.5, 700))
        b.append(text(x + 22, y + 44, sub, t["muted"], 12))
        if i < len(layers) - 1:
            b.append(arrow_down(x + w / 2, y + 57, y + 66, t["faint"], 1.4))
        y += 66

    # side rail: the console caller
    b.append(rect(x + w + 40, 96, W - (x + w + 40) - 40, 122, t["panel"], r=10,
                  stroke=t["line"], sw=1))
    b.append(label(x + w + 62, 124, "same engine, no window", t["muted"]))
    b.append(mono(x + w + 62, 150, "AutoVM.Console.ps1", t["text"], 13, 600))
    b.append(text(x + w + 62, 172, "Scripted or repeated builds.", t["muted"], 12))
    b.append(text(x + w + 62, 190, "Prints a plan with -Plan and", t["muted"], 12))
    b.append(text(x + w + 62, 206, "changes nothing.", t["muted"], 12))
    b.append(arrow_right(x + w + 4, x + w + 36, 224, t["faint"], 1.4))

    b.append(rect(x + w + 40, 236, W - (x + w + 40) - 40, 92, t["okSoft"], r=10,
                  stroke=t["ok"], sw=1, opacity=0.85))
    b.append(label(x + w + 62, 264, "tested without a hypervisor", t["ok"]))
    b.append(text(x + w + 62, 288, "Sizing, gates, credentials, answer", t["text"], 12))
    b.append(text(x + w + 62, 304, "files and deletion safety are pure", t["text"], 12))
    b.append(text(x + w + 62, 320, "functions. 65 tests, any OS.", t["text"], 12))
    return svg(W, H, "\n".join(b))


# ------------------------------------------------------------------- app shell
A = APP
CW, CH = 920, 668          # client area, matching the real window
SIDE = 228
CX = SIDE + 34             # content left edge
CWID = CW - CX - 34


def app_shell(step, body, next_label="Continue", back=True, footer="", top=32):
    """Sidebar + footer chrome shared by every wizard mockup."""
    steps = ["Welcome", "This device", "Your account", "Review", "Building", "Ready"]
    out = [rect(0, top, CW, CH, A["ink"])]
    out.append(rect(0, top, SIDE, CH, A["side"]))

    out.append(text(24, top + 44, "AutoVM", A["text"], 21, 700))
    out.append(text(24, top + 62, "virtual machines, set up for you", A["muted"], 10.5))

    y = top + 100
    for i, s in enumerate(steps):
        if i < step:
            colour, mark = A["ok"], "✓"
        elif i == step:
            colour, mark = A["text"], str(i + 1)
        else:
            colour, mark = A["muted"], str(i + 1)
        out.append(mono(24, y, mark, colour, 12, 700))
        out.append(mono(46, y, s, colour, 12.5, 600 if i == step else 400))
        y += 26

    out.append(line_(24, y + 12, SIDE - 24, y + 12, A["line"], 1))
    out.append(text(24, y + 36, "AutoVM leaves your machines and", A["faint"], 10.5))
    out.append(text(24, y + 51, "your security settings alone unless", A["faint"], 10.5))
    out.append(text(24, y + 66, "you tell it otherwise.", A["faint"], 10.5))

    out.append(body)

    fy = top + CH - 52
    if footer:
        out.append(text(CX, fy + 20, footer, A["faint"], 11.5))
    out.append(rect(CW - 34 - 168, fy, 168, 36, A["accent"], r=6))
    out.append(text(CW - 34 - 84, fy + 23, next_label, "#ffffff", 13, 600, anchor="middle"))
    out.append(rect(CW - 34 - 168 - 122, fy, 112, 36, A["panel2"], r=6, stroke=A["line"], sw=1,
                    opacity=1 if back else 0.4))
    out.append(text(CW - 34 - 168 - 66, fy + 23, "Back", A["text"], 13, 400, anchor="middle",
                    opacity=1 if back else 0.4))
    return "".join(out)


def head(y, title, deck_lines):
    out = [text(CX, y, title, A["text"], 24, 600)]
    yy = y + 26
    for l in deck_lines:
        out.append(text(CX, yy, l, A["muted"], 13))
        yy += 19
    return "".join(out), yy


def field(x, y, w, lab, value, placeholder=False, hint=None, hint_colour=None):
    out = [label(x, y, lab, A["muted"], 10),
           rect(x, y + 8, w, 34, A["field"], r=5, stroke=A["line"], sw=1),
           text(x + 11, y + 30, value, A["faint"] if placeholder else A["text"], 14)]
    if hint:
        out.append(text(x, y + 60, hint, hint_colour or A["muted"], 11.5))
    return "".join(out)


def app_svg(body, w=CW, h=CH + 32, title="AutoVM"):
    return svg(w, h, window_chrome(0, 0, w, h, title) + body)


# ---------------------------------------------------------------- 1 · welcome
def screen_welcome():
    b, y = head(80, "Set up a Linux virtual machine", [
        "AutoVM looks at this computer, works out a machine that will run well on it,",
        "downloads a verified system image, and installs it without you having to answer",
        "installer questions. You choose the login and password; everything else is decided.",
    ])
    y += 18
    b += rect(CX, y, CWID, 132, A["panel"], r=8, stroke=A["line"], sw=1)
    b += text(CX + 20, y + 28, "What happens next", A["text"], 13.5, 600)
    rows = [
        "1.  AutoVM checks that this computer can run a virtual machine at all.",
        "2.  You pick the system and type the login and password you want inside it.",
        "3.  You see exactly what will be created before anything is installed.",
        "4.  AutoVM builds it and puts a control panel on your desktop.",
    ]
    yy = y + 54
    for r in rows:
        b += text(CX + 20, yy, r, A["muted"], 12.5)
        yy += 21
    y += 148
    b += rect(CX, y, CWID, 76, "#1b2038", r=8, stroke="#3a3050", sw=1)
    b += text(CX + 18, y + 28, "AutoVM needs administrator rights to install the virtualization software, and it", A["muted"], 12.5)
    b += text(CX + 18, y + 47, "downloads several gigabytes. It will not change your firewall, your Windows security", A["muted"], 12.5)
    b += text(CX + 18, y + 66, "settings, or any virtual machine you already have.", A["muted"], 12.5)
    return app_svg(app_shell(0, b, "Get started", back=False))


# ----------------------------------------------------------------- 2 · device
def screen_device():
    b, y = head(80, "This device", ["Ready, with a trade-off to confirm: G5"])
    y += 14
    listw = CWID - 236
    b += rect(CX, y, listw, 420, A["panel"], r=8, stroke=A["line"], sw=1)

    gates = [
        ("✓", A["ok"], "Hardware virtualization enabled", "VirtualizationFirmwareEnabled = True", None),
        ("✓", A["ok"], "Second level address translation", "SLAT = Extended Page Tables", None),
        ("✓", A["ok"], "Sufficient host memory", "8 GB installed, 6 GB required", None),
        ("✓", A["ok"], "Free disk space", "best fixed volume has 240 GB free", None),
        ("!", A["warn"], "Exclusive use of the extensions", "VBS running, Memory Integrity on",
         "Runs in a slower hosted mode. AutoVM leaves those protections on."),
        ("✓", A["ok"], "Administrator rights", "elevated = True", None),
    ]
    yy = y + 40
    for mark, colour, title, detail, advice in gates:
        b += text(CX + 16, yy, mark, colour, 13, 700)
        b += text(CX + 38, yy, title, A["text"], 12.5)
        b += mono(CX + 38, yy + 15, detail, A["faint"], 10.5)
        if advice:
            b += text(CX + 38, yy + 31, advice, colour, 11)
            yy += 18
        yy += 58

    fx = CX + listw + 16
    b += rect(fx, y, 220, 196, A["panel"], r=8, stroke=A["line"], sw=1)
    facts = [("device", "ThinkPad L14"), ("memory", "8 GB installed"),
             ("processor", "8 logical cores"), ("free space", "240 GB free on C:")]
    yy = y + 30
    for lab, val in facts:
        b += label(fx + 18, yy, lab, A["muted"], 10)
        b += text(fx + 18, yy + 20, val, A["text"], 13)
        yy += 44
    b += rect(fx, y + 210, 220, 34, A["panel2"], r=6, stroke=A["line"], sw=1)
    b += text(fx + 110, y + 232, "Check again", A["text"], 12.5, anchor="middle")

    return app_svg(app_shell(1, b, footer="You can continue — the trade-off is recorded in the build report."))


# ---------------------------------------------------------------- 3 · account
def screen_account():
    b, y = head(80, "Your account inside the machine", [
        "This is the login you will use every time you start the virtual machine.",
        "AutoVM does not store the password anywhere.",
    ])
    y += 16
    b += label(CX, y, "system", A["muted"], 10)
    b += f'<circle cx="{CX + 7}" cy="{y + 22}" r="7" fill="none" stroke="{A["accent"]}" stroke-width="1.6"/>'
    b += f'<circle cx="{CX + 7}" cy="{y + 22}" r="3.4" fill="{A["accent"]}"/>'
    b += text(CX + 22, y + 26, "Kali Linux", A["text"], 13)
    b += f'<circle cx="{CX + 132}" cy="{y + 22}" r="7" fill="none" stroke="{A["muted"]}" stroke-width="1.6"/>'
    b += text(CX + 147, y + 26, "Debian", A["text"], 13)
    b += text(CX, y + 50, "Debian-derived security distribution with the Xfce desktop  -  about 60 minutes to install.",
              A["muted"], 12)

    y += 76
    half = (CWID - 26) / 2
    b += field(CX, y, half, "login name", "Analyst")
    b += text(CX, y + 60,
              "Created as 'analyst', renamed to 'Analyst' after install.", A["warn"], 11.5)
    b += field(CX + half + 26, y, half, "machine name (optional)", "AutoVM-kali", placeholder=True)
    b += text(CX + half + 26, y + 60, "How the machine is listed in VirtualBox.", A["muted"], 11.5)

    y += 92
    b += field(CX, y, half, "password", "•" * 12)
    b += rect(CX, y + 50, half, 5, A["field"], r=3)
    b += rect(CX, y + 50, half * 0.8, 5, A["ok"], r=3)
    b += text(CX, y + 74, "Strength: strong.", A["ok"], 11.5)
    b += field(CX + half + 26, y, half, "confirm password", "•" * 12)

    y += 106
    b += rect(CX, y, CWID, 52, "#1b2038", r=8, stroke="#3a3050", sw=1)
    b += text(CX + 18, y + 22, "Linux logins are case-sensitive. Whatever you type here is exactly what", A["muted"], 12.5)
    b += text(CX + 18, y + 40, "you will type to sign in.", A["muted"], 12.5)
    return app_svg(app_shell(2, b))


# ----------------------------------------------------------------- 4 · review
def screen_review():
    b, y = head(80, "Before anything is installed", ["This is what AutoVM will create on this device."])
    y += 16
    b += rect(CX, y, CWID, 140, A["panel"], r=8, stroke=A["line"], sw=1)
    left = [("system", "Kali Linux (Light package set)"),
            ("memory given to the machine", "3072 MB  -  38% of this device"),
            ("processors", "4 of 8 logical cores")]
    right = [("disk", "up to 60 GB on drive C:  (grows as needed)"),
             ("sign in as", "Analyst"), ("estimated time", "about 60 minutes")]
    for col, items in ((CX + 20, left), (CX + CWID / 2 + 4, right)):
        yy = y + 30
        for lab, val in items:
            b += label(col, yy, lab, A["muted"], 9.5)
            b += text(col, yy + 20, val, A["text"], 12.5)
            yy += 44

    y += 154
    warnings = [
        "The light desktop package set was chosen automatically to fit this device.",
        "Windows virtualization-based security is active, so the guest runs in a slower mode.",
    ]
    for w in warnings:
        b += rect(CX, y, CWID, 34, "#241e12", r=7, stroke="#4b3b1b", sw=1)
        b += text(CX + 16, y + 22, w, A["warn"], 12)
        y += 42

    b += rect(CX, y, CWID, 34, A["panel"], r=7, stroke=A["line"], sw=1)
    b += text(CX + 16, y + 22, "▸   Remove virtual machines already on this device", A["muted"], 12.5)
    b += mono(CX + CWID - 76, y + 22, "off", A["faint"], 11, 600)
    return app_svg(app_shell(3, b, "Build my machine", footer="Nothing has been changed on this device yet."))


# --------------------------------------------------------------- 5 · building
def screen_building(animate=True):
    b, y = head(80, "Building your machine", [
        "You can leave this running. Keep the computer awake and plugged in."])
    y += 20
    pct = 0.62
    b += rect(CX, y, CWID, 8, A["field"], r=4)
    if animate:
        b += (f'<rect x="{CX}" y="{y}" width="{CWID * pct}" height="8" rx="4" fill="{A["accent"]}">'
              f'<animate attributeName="width" values="{CWID * 0.44};{CWID * pct};{CWID * 0.44}" '
              f'dur="9s" repeatCount="indefinite" calcMode="spline" '
              f'keySplines="0.4 0 0.2 1;0.4 0 0.2 1" keyTimes="0;0.55;1"/></rect>')
    else:
        b += rect(CX, y, CWID * pct, 8, A["accent"], r=4)

    b += text(CX, y + 30, "Installing - 00:24:31 elapsed, machine is running", A["text"], 13)
    b += mono(CX + CWID, y + 30, "00:41:07", A["muted"], 12, anchor="end")

    y += 48
    logh = CH - y - 76
    b += rect(CX, y, CWID, logh, "#070c18", r=8, stroke=A["line"], sw=1)
    log = [
        ("09:19:12", "P1 PASS - created 1, destroyed 0, elapsed 00:04:12", A["ok"]),
        ("09:19:14", "Phase 3 of 7 - installing VirtualBox", A["accent"]),
        ("09:26:48", "VirtualBox 7.1.4 is ready", A["ok"]),
        ("09:26:50", "Phase 4 of 7 - downloading Kali Linux", A["accent"]),
        ("09:27:02", "Looking up the current Kali Linux image at cdimage.kali.org", A["muted"]),
        ("09:27:09", "Selected kali-linux-2025.3-installer-amd64.iso", A["muted"]),
        ("09:41:55", "Downloading - 3.9 of 4.1 GB (95%)", A["muted"]),
        ("09:43:20", "Verifying the download", A["muted"]),
        ("09:44:02", "Image verified: kali-linux-2025.3-installer-amd64.iso", A["ok"]),
        ("09:44:05", "Phase 5 of 7 - building the virtual machine", A["accent"]),
        ("09:44:41", "Creating a 60 GB dynamic disk", A["muted"]),
        ("09:45:20", "Starting the unattended installation", A["muted"]),
        ("10:09:31", "Installing - 00:24:11 elapsed, machine is running", A["muted"]),
    ]
    yy = y + 26
    for stamp, msg, colour in log:
        b += mono(CX + 16, yy, stamp, A["faint"], 10.5)
        b += mono(CX + 84, yy, msg, colour, 10.5)
        yy += 18
    return app_svg(app_shell(4, b, "Building...", back=False))


# ------------------------------------------------------------------ 6 · ready
def screen_ready():
    b, y = head(80, "Your machine is ready", ["Finished in 01:07:44."])
    y += 16
    notew = CWID - 220
    b += rect(CX, y, notew, 300, A["panel"], r=8, stroke=A["line"], sw=1)
    note = [
        ("Your Kali Linux virtual machine is ready.", A["text"]),
        ("", None),
        ("Start it        Double-click 'AutoVM Control Center' on your", A["muted"]),
        ("                desktop, then Start (Window).", A["muted"]),
        ("Sign in as      Analyst  - exactly as typed. Linux logins are", A["text"]),
        ("                case-sensitive.", A["text"]),
        ("Password        the one you chose. AutoVM did not keep a copy.", A["muted"]),
        ("Shut it down    Use Shut Down in the control panel.", A["muted"]),
        ("Undo changes    Restore to first-boot state discards everything", A["muted"]),
        ("                saved inside the machine since the build.", A["muted"]),
        ("", None),
        ("Memory          3072 MB, about 38% of this device.", A["muted"]),
        ("Network         Outbound only. Nothing can reach into the guest,", A["warn"]),
        ("                which is why a simple password is acceptable.", A["warn"]),
    ]
    yy = y + 28
    for lineText, colour in note:
        if lineText:
            b += mono(CX + 20, yy, lineText, colour, 10.5)
        yy += 18

    bx = CX + notew + 16
    buttons = [("Open the control panel", A["accent"], "#ffffff"),
               ("Show the build log", A["panel2"], A["text"]),
               ("Copy these notes", A["panel2"], A["text"])]
    yy = y
    for lab, bg, fg in buttons:
        b += rect(bx, yy, 204, 38, bg, r=6, stroke=None if bg == A["accent"] else A["line"], sw=1)
        b += text(bx + 102, yy + 24, lab, fg, 12.5, 600 if bg == A["accent"] else 400, anchor="middle")
        yy += 48
    return app_svg(app_shell(5, b, "Finish", back=False))


# --------------------------------------------------------- the control centre
def control_center():
    W, H = 450, 372 + 32
    t = dict(A, ink="#101420", panel="#22252e", panel2="#2d303a", line="#3a3e4a")
    b = window_chrome(0, 0, W, H, "AutoVM Control Center", t)
    top = 32
    b += rect(0, top, W, H - top, "#101420")
    b += text(20, top + 48, "KALI LINUX", "#78c8ff", 19, 600)
    b += mono(22, top + 68, "machine: AutoVM-kali", "#8291aa", 10.5)
    b += rect(22, top + 78, 406, 22, "#1e212a", r=4)
    b += mono(30, top + 93, "status:  running", "#5fd98a", 11)

    rows = [("Start (Window)", "Start (Headless)"), ("Settings...", "VirtualBox Manager"),
            ("Shut Down", "Save State")]
    y = top + 110
    for a1, a2 in rows:
        for i, lab in enumerate((a1, a2)):
            x = 22 + i * 210
            b += rect(x, y, 196, 42, "#2d303a", r=4, stroke="#3a3e4a", sw=1)
            b += text(x + 98, y + 26, lab, "#ffffff", 12.5, anchor="middle")
        y += 50
    b += rect(22, y, 406, 42, "#3a2d34", r=4, stroke="#5a3a42", sw=1)
    b += text(225, y + 26, "Restore to first-boot state", "#ffb3a7", 12.5, anchor="middle")
    b += rect(22, y + 54, 406, 22, "#1e212a", r=4)
    b += mono(30, y + 69, "sign in as  Analyst   (case-sensitive)", "#8291aa", 10)
    return svg(W, H, b)


# ------------------------------------------------------------------ safety map
def safety(t):
    W, H = 1180, 300
    b = [rect(0, 0, W, H, t["canvas"])]
    b.append(text(40, 44, "What AutoVM touches, and what it will not", t["text"], 19, 700))
    b.append(text(40, 68, "The right-hand column is not a setting. Nothing in the codebase can do those things.",
                  t["muted"], 13))

    cols = [
        ("changes, with your say-so", t["accent"], t["accentSoft"], t["accentLine"], [
            "Installs Oracle VirtualBox and 7-Zip",
            "Creates one virtual machine and its disk",
            "Downloads a verified system image to ProgramData",
            "Writes a control panel and a desktop shortcut",
            "Removes existing machines — only if you opt in and type DESTROY",
        ]),
        ("never touches", t["bad"], t["badSoft"], t["bad"], [
            "Your firewall rules",
            "Virtualization-based security, Memory Integrity, WSL2",
            "Driver signature enforcement — it reports a block instead",
            "WSL disks, recovery images, Windows.old, mounted disks",
            "Anything on removable or network media",
        ]),
    ]
    x = 40
    w = (W - 80 - 24) / 2
    for title, colour, fill, edge, items in cols:
        b.append(rect(x, 92, w, 176, fill, r=10, stroke=edge, sw=1, opacity=0.9))
        b.append(label(x + 22, 120, title, colour))
        yy = 148
        for it in items:
            b.append(f'<circle cx="{x + 27}" cy="{yy - 4}" r="3" fill="{colour}"/>')
            b.append(text(x + 40, yy, it, t["text"], 12.5))
            yy += 24
        x += w + 24
    return svg(W, H, "\n".join(b))


# ------------------------------------------------------------- social preview
def social():
    """1280x640 card for the repository's social preview (Settings > General)."""
    t = THEMES["dark"]
    W, H = 1280, 640
    defs = f'''<defs>
  <linearGradient id="sg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="{t["accent"]}" stop-opacity="0.30"/>
    <stop offset="0.6" stop-color="{t["accent"]}" stop-opacity="0.05"/>
    <stop offset="1" stop-color="{t["accent"]}" stop-opacity="0"/>
  </linearGradient>
  <linearGradient id="sw" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="{t["accent"]}"/>
  </linearGradient>
  <pattern id="sgrid" width="40" height="40" patternUnits="userSpaceOnUse">
    <path d="M40 0 L0 0 0 40" fill="none" stroke="{t["line"]}" stroke-width="1" opacity="0.55"/>
  </pattern>
</defs>'''
    b = [rect(0, 0, W, H, "#0b1020"),
         f'<rect width="{W}" height="{H}" fill="url(#sgrid)" opacity="0.5"/>',
         f'<rect width="{W}" height="{H}" fill="url(#sg)"/>']

    # the application mark
    mx, my, ms = 96, 96, 92
    b.append(rect(mx, my, ms, ms, "#0b1020", r=int(ms * 0.22), stroke=t["line"], sw=2))
    b.append(rect(mx + ms * 0.19, my + ms * 0.245, ms * 0.62, ms * 0.40, "none",
                  r=int(ms * 0.055), stroke=t["accent"], sw=5))
    b.append(rect(mx + ms * 0.465, my + ms * 0.645, ms * 0.07, ms * 0.11, t["accent"]))
    b.append(rect(mx + ms * 0.31, my + ms * 0.735, ms * 0.38, ms * 0.06, t["accent"], r=3))
    cx0, cy0 = mx + ms * 0.505, my + ms * 0.445
    hh = ms * 0.12
    b.append(f'<path d="M{cx0 - hh * 0.72},{cy0 - hh} L{cx0 - hh * 0.72},{cy0 + hh} '
             f'L{cx0 + hh * 0.78},{cy0} Z" fill="#3fd69b"/>')

    b.append(label(212, 122, "windows  ·  one click  ·  unattended", t["accent"], 15))
    b.append(text(212, 200, "AutoVM", "url(#sw)", 78, 800, spacing="-0.02em"))

    b.append(text(96, 296, "Autonomously creates a virtual machine", "#ffffff", 40, 600))
    b.append(text(96, 348, "of your choosing.", "#ffffff", 40, 600))
    b.append(text(96, 396, "Type a login and a password. AutoVM measures the device, sizes a machine",
                  t["muted"], 20))
    b.append(text(96, 426, "that fits, verifies the image, and installs it without a single prompt.",
                  t["muted"], 20))

    stats = [("6", "screens"), ("7", "phases"), ("65", "tests"), ("0", "installer questions")]
    x = 96
    for big, small in stats:
        b.append(rect(x, 470, 250, 92, "#131b32", r=12, stroke=t["line"], sw=1))
        b.append(text(x + 24, 522, big, "#ffffff", 34, 700))
        b.append(text(x + 24 + len(big) * 21 + 10, 522, small, t["muted"], 16))
        x += 262
    return svg(W, H, "\n".join(b), defs)


# -------------------------------------------------------------------- writing
def write(name, content):
    path = OUT / name
    path.write_text(content, encoding="utf-8")
    print(f"  {name:34s} {len(content) / 1024:6.1f} KB")


def main():
    print("themed figures")
    for mode, t in THEMES.items():
        write(f"hero-{mode}.svg", hero(t))
        write(f"flow-{mode}.svg", flow(t))
        write(f"sizing-{mode}.svg", sizing(t))
        write(f"architecture-{mode}.svg", architecture(t))
        write(f"safety-{mode}.svg", safety(t))

    print("application mockups")
    write("screen-1-welcome.svg", screen_welcome())
    write("screen-2-device.svg", screen_device())
    write("screen-3-account.svg", screen_account())
    write("screen-4-review.svg", screen_review())
    write("screen-5-building.svg", screen_building())
    write("screen-6-ready.svg", screen_ready())
    write("control-center.svg", control_center())

    print("social preview")
    write("social-preview.svg", social())


if __name__ == "__main__":
    main()
