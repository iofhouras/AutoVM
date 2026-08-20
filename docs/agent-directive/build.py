#!/usr/bin/env python3
"""
Build the Agent Directive PDF from src/directive.html.

Pipeline
--------
1. Render pass 1 with Chromium (Playwright) to discover which printed page each
   section marker lands on.
2. Substitute the discovered page numbers into the table of contents.
3. Render pass 2 — the final page geometry.
4. Stamp running headers, folios and a section rail onto every body page, add
   PDF bookmarks and document metadata.

Usage:  python3 build.py [-o output.pdf]
"""
import argparse
import io
import json
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "src" / "directive.html"
DEFAULT_OUT = HERE / "KaliVMAgentDirective-v2.pdf"
CHROME = "/opt/pw-browsers/chromium"

MARK_RE = re.compile(r"PGMK([A-Za-z0-9]+)KMGP")
NOFOOT = "PGNOFOOTGP"

# Running-header labels, in document order: (marker key, part label, section label)
SECTION_RAIL = [
    ("front",    "Front matter",              "Document control & reading guide"),
    ("toc",      "Front matter",              "Contents"),
    ("mission",  "I · Mission & standing orders", "§0 Mission"),
    ("accept",   "I · Mission & standing orders", "§0.1 Definition of done"),
    ("nongoals", "I · Mission & standing orders", "§0.2 Non-goals and blast radius"),
    ("glance",   "I · Mission & standing orders", "§0.3 The build at a glance"),
    ("arch",     "I · Mission & standing orders", "§0.4 Target architecture"),
    ("timeline", "I · Mission & standing orders", "§0.5 Timeline & resource envelope"),
    ("rules",    "I · Mission & standing orders", "§1 Standing operating rules"),
    ("pone",       "II · Prepare the host",      "§2 Phase 1 — Host reconnaissance"),
    ("gates",    "II · Prepare the host",      "§2.1 Gate table"),
    ("ptwo",       "II · Prepare the host",      "§3 Phase 2 — Teardown"),
    ("protected","II · Prepare the host",      "§3.2 Protected classes"),
    ("destroy",  "II · Prepare the host",      "§3.3 Execution under consent"),
    ("pthree",       "II · Prepare the host",      "§4 Phase 3 — Prerequisites"),
    ("pfour",       "III · Build the guest",      "§5 Phase 4 — Image acquisition"),
    ("sizing",   "III · Build the guest",      "§5.2 Resource sizing"),
    ("checksum", "III · Build the guest",      "§5.3 Checksum verification"),
    ("pfive",       "III · Build the guest",      "§6 Phase 5 — VM creation & install"),
    ("upper",    "III · Build the guest",      "§6.2 The uppercase-username problem"),
    ("preseed",  "III · Build the guest",      "§6.3 Preseed template"),
    ("monitor",  "III · Build the guest",      "§6.5 Monitoring & stall diagnosis"),
    ("psix",       "IV · Prove it & hand over",  "§7 Phase 6 — Validation & baseline"),
    ("secpost",  "IV · Prove it & hand over",  "§7.4 Security posture"),
    ("pseven",       "IV · Prove it & hand over",  "§8 Phase 7 — Desktop control app"),
    ("ui",       "IV · Prove it & hand over",  "§8.1 Control Center interface"),
    ("smoke",    "IV · Prove it & hand over",  "§8.4 Smoke test"),
    ("playbook", "IV · Prove it & hand over",  "§9 Failure playbook"),
    ("report",   "IV · Prove it & hand over",  "§10 Final report format"),
    ("appA",     "V · Reference",              "Appendix A — Command reference"),
    ("appB",     "V · Reference",              "Appendix B — Index of gates & rules"),
    ("appC",     "V · Reference",              "Appendix C — Risk register"),
    ("appD",     "V · Reference",              "Appendix D — State machine & telemetry"),
    ("appE",     "V · Reference",              "Appendix E — Glossary"),
    ("appF",     "V · Reference",              "Appendix F — Operator quick-start"),
]

# Bookmarks: (title, marker key, depth)
BOOKMARKS = [
    ("Document control & reading guide", "front", 0),
    ("Contents", "toc", 0),
    ("Part I — Mission & standing orders", "mission", 0),
    ("0.1  Definition of done", "accept", 1),
    ("0.2  Non-goals and blast radius", "nongoals", 1),
    ("0.3  The build at a glance", "glance", 1),
    ("0.4  Target architecture", "arch", 1),
    ("0.5  Timeline & resource envelope", "timeline", 1),
    ("1  Standing operating rules", "rules", 1),
    ("Part II — Prepare the host", "pone", 0),
    ("2  Phase 1 — Host reconnaissance", "pone", 1),
    ("2.1  Gate table G1–G7", "gates", 1),
    ("3  Phase 2 — Teardown", "ptwo", 1),
    ("3.2  Protected classes", "protected", 1),
    ("3.3  Execution under consent", "destroy", 1),
    ("4  Phase 3 — Prerequisite provisioning", "pthree", 1),
    ("Part III — Build the guest", "pfour", 0),
    ("5  Phase 4 — Image acquisition", "pfour", 1),
    ("5.2  Resource sizing profiles", "sizing", 1),
    ("5.3  Checksum verification", "checksum", 1),
    ("6  Phase 5 — VM creation & unattended install", "pfive", 1),
    ("6.2  The uppercase-username problem", "upper", 1),
    ("6.3  Preseed template", "preseed", 1),
    ("6.5  Monitoring & stall diagnosis", "monitor", 1),
    ("Part IV — Prove it & hand it over", "psix", 0),
    ("7  Phase 6 — Validation & baseline snapshot", "psix", 1),
    ("7.4  Security posture", "secpost", 1),
    ("8  Phase 7 — Desktop control application", "pseven", 1),
    ("8.1  Control Center interface", "ui", 1),
    ("8.4  Smoke test", "smoke", 1),
    ("9  Failure playbook", "playbook", 1),
    ("10  Final report format", "report", 1),
    ("Part V — Reference appendices", "appA", 0),
    ("A  VBoxManage command reference", "appA", 1),
    ("B  Index of gates, rules & codes", "appB", 1),
    ("C  Risk register and heat map", "appC", 1),
    ("D  Resumable state machine & telemetry", "appD", 1),
    ("E  Glossary", "appE", 1),
    ("F  Operator quick-start card", "appF", 1),
]


def render(html: str, out_path: Path) -> None:
    from playwright.sync_api import sync_playwright
    tmp_html = (out_path.parent / "_render.html").resolve()
    tmp_html.write_text(html, encoding="utf-8")
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=CHROME, args=["--no-sandbox", "--font-render-hinting=none"])
        page = browser.new_page()
        page.goto(tmp_html.as_uri(), wait_until="networkidle")
        page.emulate_media(media="print")
        page.wait_for_timeout(600)
        page.pdf(path=str(out_path), format="A4", print_background=True,
                 prefer_css_page_size=True, display_header_footer=False)
        browser.close()
    tmp_html.unlink(missing_ok=True)


def page_map(pdf_path: Path) -> dict:
    from pypdf import PdfReader
    reader = PdfReader(str(pdf_path))
    marks, nofoot = {}, set()
    for i, pg in enumerate(reader.pages, start=1):
        text = pg.extract_text() or ""
        if NOFOOT in text:
            nofoot.add(i)
        for key in MARK_RE.findall(text):
            marks.setdefault(key, i)
    return {"marks": marks, "nofoot": sorted(nofoot), "pages": len(reader.pages)}


def fill_toc(html: str, marks: dict) -> str:
    def sub(m):
        key = m.group(1)
        return f'data-pg="{key}">{marks.get(key, "—")}<'
    return re.sub(r'data-pg="([a-zA-Z0-9_-]+)">[^<]*<', sub, html)


def stamp(pdf_in: Path, pdf_out: Path, info: dict) -> None:
    from pypdf import PdfReader, PdfWriter
    from reportlab.pdfgen import canvas
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont

    fdir = Path("/usr/share/fonts/truetype/custom")
    pdfmetrics.registerFont(TTFont("JB", fdir / "JetBrainsMono-Regular.ttf"))
    pdfmetrics.registerFont(TTFont("JBB", fdir / "JetBrainsMono-Bold.ttf"))
    pdfmetrics.registerFont(TTFont("IN", fdir / "Inter-Medium.ttf"))
    pdfmetrics.registerFont(TTFont("INB", fdir / "Inter-SemiBold.ttf"))

    reader = PdfReader(str(pdf_in))
    total = len(reader.pages)
    marks = info["marks"]
    nofoot = set(info["nofoot"])

    # page -> (part, section) from the rail
    rail = sorted(
        [(marks[k], part, sec) for k, part, sec in SECTION_RAIL if k in marks],
        key=lambda r: r[0])

    def label_for(pno):
        cur = ("Agent Directive", "AD-KALI-VM rev 2.0")
        for start, part, sec in rail:
            if start <= pno:
                cur = (part, sec)
        return cur

    W, H = A4
    # One overlay document for the whole run so the fonts are embedded once.
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=A4)
    for idx in range(1, total + 1):
        if idx not in nofoot:
            part, sec = label_for(idx)
            c.setFont("JB", 5.6)
            c.setFillColorRGB(0.53, 0.58, 0.67)
            c.drawString(45.4, H - 30.5, part.upper())
            c.setFont("IN", 6.4)
            c.setFillColorRGB(0.35, 0.41, 0.50)
            c.drawRightString(W - 45.4, H - 30.5, sec)
            c.setStrokeColorRGB(0.86, 0.89, 0.94)
            c.setLineWidth(0.5)
            c.line(45.4, H - 37, W - 45.4, H - 37)
            c.line(45.4, 34, W - 45.4, 34)
            c.setFont("JB", 5.6)
            c.setFillColorRGB(0.60, 0.65, 0.72)
            c.drawString(45.4, 24, "AD-KALI-VM \u00b7 rev 2.0 \u00b7 executable agent instruction set")
            c.setFont("IN", 5.8)
            c.drawRightString(W - 45.4, 24, "Halt and report. Never improvise around a failed gate.")
            c.setFillColorRGB(0.04, 0.06, 0.11)
            c.roundRect(W / 2 - 21, 18.5, 42, 13, 6.5, stroke=0, fill=1)
            c.setFont("JBB", 6.2)
            c.setFillColorRGB(1, 1, 1)
            c.drawCentredString(W / 2, 22.6, f"{idx} / {total}")
        c.showPage()
    c.save()
    buf.seek(0)
    overlay = PdfReader(buf)

    writer = PdfWriter()
    for idx, page in enumerate(reader.pages, start=1):
        if idx not in nofoot:
            page.merge_page(overlay.pages[idx - 1])
        writer.add_page(page)
    for page in writer.pages:
        page.compress_content_streams()

    # bookmarks
    parents = {}
    for title, key, depth in BOOKMARKS:
        if key not in marks:
            continue
        pno = marks[key] - 1
        if depth == 0:
            parents[0] = writer.add_outline_item(title, pno, bold=True)
        else:
            writer.add_outline_item(title, pno, parent=parents.get(0))

    writer.add_metadata({
        "/Title": "Agent Directive rev 2.0 — Autonomous Kali Linux VM Provisioning on Windows",
        "/Subject": "Gated, idempotent, verifiable build directive for an autonomous provisioning agent",
        "/Keywords": "Kali Linux, VirtualBox, PowerShell, unattended install, preseed, agent directive",
        "/Creator": "AutoVM · docs/agent-directive/build.py",
    })
    writer.page_mode = "/UseOutlines"
    with open(pdf_out, "wb") as fh:
        writer.write(fh)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default=str(DEFAULT_OUT))
    ap.add_argument("--pass1-only", action="store_true")
    args = ap.parse_args()

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    html = SRC.read_text(encoding="utf-8")

    tmp1 = out.parent / "_pass1.pdf"
    print("· pass 1 — discovering pagination")
    render(html, tmp1)
    info = page_map(tmp1)
    print(f"  {info['pages']} pages, {len(info['marks'])} markers, "
          f"{len(info['nofoot'])} full-bleed pages")
    missing = [k for k, *_ in SECTION_RAIL if k not in info["marks"]]
    if missing:
        print(f"  ! markers not found: {', '.join(missing)}", file=sys.stderr)

    if args.pass1_only:
        shutil.move(tmp1, out)
        return

    print("· pass 2 — final layout with resolved contents")
    tmp2 = out.parent / "_pass2.pdf"
    render(fill_toc(html, info["marks"]), tmp2)
    info2 = page_map(tmp2)

    print("· stamping folios, running heads, bookmarks and metadata")
    stamp(tmp2, out, info2)
    tmp1.unlink(missing_ok=True)
    tmp2.unlink(missing_ok=True)
    size = out.stat().st_size / 1024
    print(f"✓ {out}  —  {info2['pages']} pages, {size:.0f} KB")


if __name__ == "__main__":
    main()
