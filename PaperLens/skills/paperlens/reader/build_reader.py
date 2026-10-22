#!/usr/bin/env python3
"""Build the Paper Reader artifact for one paper: light PDFs + index.html from reader_template.html.

Tabs in the reader: Main text, any --extra PDFs (e.g. a separate Methods PDF), Supplementary,
then the text tabs for the paper type (--type), each filled from the page's db document <key>/current:
  omics   Summary · Links                                   (default)
  wet     Summary · Experiments · Links
  dry     Summary · Parameters & training · Tutorial · Links
  review  Summary · Timeline · Links                        (Timeline renders timeline.json items)
--add-tab experiments|parameters|tutorial|timeline adds a tab from another type (mixed papers); repeatable.

Usage:
  python3 build_reader.py --main <Zotero main PDF> [--extra "Methods=<methods.pdf>" ...] [--si <SI PDF>] --out <dir> \
      --title "<full title>" --short "<First author> et al. <year> · <Journal>" --name "<Firstauthor> <year> Paper Reader" \
      [--cover <cover.png> --url <article URL>] [--type omics|wet|dry|review] [--add-tab <key> ...] \
      [--research "<the user's research direction>"] [--translate-to <code>] --template reader_template.html

<year> = the year the paper was first published online (e.g. "Published: 18 December 2024" -> 2024),
not the issue year. --research (from the PaperLens settings) adds a "For my research" quick question to Ask Claude;
--translate-to sets the Translate default (e.g. zh-Hans, es, ja); otherwise it follows the browser language. --cover is the crop of the article header from the publisher's page; it is shown
above page 1 of the main text and links to --url.

Writes <out>/main.pdf (+ extra1.pdf…, si.pdf, cover.png), <out>/index.html. Copy pdf.worker.min.js (pdfjs-dist 3.11.174,
build/pdf.worker.min.js) next to them, then publish index.html with files main.pdf, extra*.pdf, si.pdf, cover.png,
pdf.worker.min.js and capabilities {"db": {}, "user": {}, "sample": {}} (sample = the Translate button).
"""
import argparse, json, os, re, shutil
import pymupdf


def light(src, dst):
    d = pymupdf.open(src)
    d.rewrite_images(dpi_threshold=160, dpi_target=150, quality=70)
    d.save(dst, garbage=4, deflate=True)
    return pymupdf.open(dst)


def main_toc(doc):
    secs, figs, ed, methods = [], [], [], None
    for lvl, t, p in doc.get_toc():
        t = t.strip().replace("\xa0", " ")
        if p < 1 or lvl == 1:
            continue
        (figs if t.startswith("Fig") else ed if t.startswith("Extended Data") else secs).append({"t": t, "p": p})
    for i, pg in enumerate(doc):
        head = pg.get_text()[:400]
        if re.search(r"(^|\n)\s*Methods\s*\n", head):
            methods = i + 1
            secs.append({"t": "Methods", "p": methods})
            break
    if not figs:  # no outline: find figure legends
        for i, pg in enumerate(doc):
            for m in re.finditer(r"(?m)^(Fig\.\s*\d+|Extended Data Fig\.\s*\d+)\s*\|", pg.get_text()):
                (ed if m.group(1).startswith("Extended") else figs).append({"t": m.group(1), "p": i + 1})
    secs.sort(key=lambda x: x["p"])
    return [{"group": "Sections", "items": secs}, {"group": "Figures", "items": figs},
            {"group": "Extended Data", "items": ed}], methods


def si_toc(doc):
    items, seen = [], set()
    for i, pg in enumerate(doc):
        for line in pg.get_text().split("\n"):
            m = re.match(r"\s*Supplementary Fig(?:ure)?\.?\s*(\d+)", line)
            if m and m.group(1) not in seen:
                seen.add(m.group(1)); items.append({"t": f"Supplementary Fig. {m.group(1)}", "p": i + 1}); break
    return [{"group": "Supplementary figures", "items": items}]


TAB = {
    "summary": {"key": "summary", "label": "Summary"},
    "experiments": {"key": "experiments", "label": "Experiments"},
    "parameters": {"key": "parameters", "label": "Parameters & training"},
    "tutorial": {"key": "tutorial", "label": "Tutorial"},
    "timeline": {"key": "timeline", "label": "Timeline", "kind": "timeline"},
    "links": {"key": "links", "label": "Links"},
}
TYPE_TABS = {"omics": [], "wet": ["experiments"], "dry": ["parameters", "tutorial"], "review": ["timeline"]}


def text_tabs(kind, extra):
    middle = []
    for k in TYPE_TABS[kind] + list(extra):
        if k not in middle:
            middle.append(k)
    return [TAB["summary"]] + [TAB[k] for k in middle] + [TAB["links"]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--main", required=True); ap.add_argument("--si"); ap.add_argument("--out", required=True)
    ap.add_argument("--extra", action="append", default=[], help='"Label=path.pdf", e.g. "Methods=methods.pdf"; repeatable')
    ap.add_argument("--title", required=True); ap.add_argument("--short", required=True)
    ap.add_argument("--name", required=True); ap.add_argument("--template", required=True)
    ap.add_argument("--cover", help="article-header crop from the publisher page (png/jpg/webp)")
    ap.add_argument("--url", help="article URL on the publisher site (the cover links to it)")
    ap.add_argument("--type", default="omics", choices=sorted(TYPE_TABS), help="paper type: picks the extra text tabs")
    ap.add_argument("--add-tab", action="append", default=[], choices=["experiments", "parameters", "tutorial", "timeline"],
                    help="extra text tab borrowed from another type (mixed papers)")
    ap.add_argument("--research", help="the user's research direction (adds the 'For my research' quick question)")
    ap.add_argument("--translate-to", help="default Translate target language code, e.g. zh-Hans")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    m = light(a.main, os.path.join(a.out, "main.pdf"))
    toc, methods = main_toc(m)
    docs = [{"key": "main", "label": "Main text", "file": "main.pdf", "toc": toc}]
    for i, spec in enumerate(a.extra, 1):
        label, path = spec.split("=", 1)
        x = light(path, os.path.join(a.out, f"extra{i}.pdf"))
        items = [{"t": t.strip(), "p": p} for lvl, t, p in x.get_toc() if p >= 1]
        docs.append({"key": f"extra{i}", "label": label.strip(), "file": f"extra{i}.pdf",
                     "toc": [{"group": label.strip(), "items": items}]})
    if a.si:
        s = light(a.si, os.path.join(a.out, "si.pdf"))
        docs.append({"key": "si", "label": "Supplementary", "file": "si.pdf", "toc": si_toc(s)})
    cfg = {"title": a.title, "short": a.short, "type": a.type, "docs": docs, "tabs": text_tabs(a.type, a.add_tab)}
    if a.url:
        cfg["url"] = a.url
    if a.research:
        cfg["research"] = a.research.strip()
    if a.translate_to:
        cfg["translate_to"] = a.translate_to
    if a.cover:
        ext = os.path.splitext(a.cover)[1].lower() or ".png"
        shutil.copyfile(a.cover, os.path.join(a.out, "cover" + ext))
        cfg["cover"] = "cover" + ext
    t = open(a.template, encoding="utf-8").read()
    t = t.replace("__TITLE__", a.name).replace("__CFG__", json.dumps(cfg).replace("</", "<\\/"))
    open(os.path.join(a.out, "index.html"), "w", encoding="utf-8").write(t)
    for f in os.listdir(a.out):
        print(f, round(os.path.getsize(os.path.join(a.out, f)) / 1e6, 1), "MB")


if __name__ == "__main__":
    main()
