# Agent Directive — Autonomous Kali Linux VM Provisioning on Windows

`KaliVMAgentDirective-v2.pdf` is a 50-page, print-ready rebuild of the original
`KaliVMAgentDirective.pdf`. Same mission and same commands, restructured as a gated phase model
and typeset as an operational document.

## What changed from rev 1.0

| Area | rev 1.0 | rev 2.0 |
| --- | --- | --- |
| Structure | Continuous prose, 18 pages | Five parts, 50 pages, with part dividers and a resolved table of contents |
| Identifiers | Gates and rules mentioned in text | `G1–G7`, `R1–R7`, `A1–A9` and `GATE-P*` cross-referenced, indexed in Appendix B |
| Phases | Narrative steps | Each phase opens with an inputs → actions → outputs → exit-criterion contract |
| Diagrams | None | 12 inline SVG figures: phase pipeline, layered architecture, consent flow, gate resolution, checksum path, the uppercase-username failure, snapshot lifecycle, control-panel mockup, failure triage, risk heat map, resume logic, timeline |
| Code | Plain blocks | Syntax-highlighted, captioned with target file, elevation and expected runtime |
| New material | — | Risk register with heat map (App. C), resumable state machine and telemetry schema (App. D), command reference (App. A), glossary (App. E), operator quick-start card (App. F), pre-run conditions, download-resume handling, one-pass final verification, handover script |
| Navigation | — | PDF bookmarks, running heads, folios, document metadata |

Nothing from the original was dropped: every command, gate, table and warning in rev 1.0 is
present, in the same operational order.

## Building

```bash
python3 build.py -o KaliVMAgentDirective-v2.pdf
```

The build is a three-step pipeline in `build.py`:

1. **Pass 1** renders `src/directive.html` with headless Chromium and reads back which printed
   page each section marker landed on.
2. **Pass 2** re-renders with those page numbers substituted into the table of contents.
3. **Stamping** merges a single ReportLab overlay carrying the running heads and folios, adds PDF
   bookmarks and metadata, and compresses the content streams.

### Requirements

- Python 3.11+ with `playwright`, `pypdf`, `reportlab`
- Chromium (the script points at `/opt/pw-browsers/chromium`; change `CHROME` in `build.py` for
  another path)
- Fonts **Inter**, **Inter Display** and **JetBrains Mono** installed system-wide. Without them the
  layout still builds but falls back to Liberation Sans / DejaVu Sans Mono.

## Editing

`src/directive.html` is the single source. Two conventions matter:

- **Page markers.** `<span class="pgm">PGMK<key>KMGP</span>` inside a heading is how `build.py`
  discovers that heading's page number. Keys must be letters only — digits are substituted by
  Inter's tabular-figure feature and do not survive text extraction. `PGNOFOOTGP` marks a
  full-bleed page that gets no running head or folio.
- **New sections.** Add the key to `SECTION_RAIL` (running head) and `BOOKMARKS` (PDF outline) in
  `build.py`, and add a matching `data-pg="<key>"` cell in the contents list.

Full-bleed pages use the named page rule `@page bleedpg { margin: 0 }` via `page: bleedpg`;
everything else uses the default `@page` margins.
