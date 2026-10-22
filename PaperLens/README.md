# PaperLens

Read a research paper end to end with Claude. Give it a title, DOI or link; PaperLens finds the paper, saves the supplements, writes a summary shaped by the kind of paper it is, and builds a **Paper Reader** page where you select any passage to ask Claude about it or translate it.

## What you get for each paper

- **A paper folder** with the main text, the publisher's supplementary files (SI, tables, peer review file, reporting summary), plain-text copies for fast search, and `links.md`: every code, data and portal link the paper points to.
- **summary.md**, opened in the side panel, in a layout that fits the paper type:

  | Type | Example | Extra in the reader |
  | --- | --- | --- |
  | A · Omics / data-driven | atlases, single-cell and spatial profiling | — |
  | B · Wet-lab / mechanistic | knockouts, drugs, rescue experiments | **Experiments**: models, assays, the logic map |
  | C · Method / tool | new algorithms, software packages | **Parameters & training**, **Tutorial** (from the official tutorial, with Copy buttons) |
  | D · Review | reviews and perspectives | **Timeline**: every cited paper by year, key papers first |

  Every summary covers citations and the authors' earlier work, the technology, the logic of the paper, the main findings with figure panels, the story figure by figure, the exact parameters, what the reviewers attacked, and the paper in plain words. If you give your research direction, it also explains how to apply the paper to your work.
- **A Paper Reader** (a private web page in your Claude account): the real PDF pages with selectable text, the summary and the other tabs, a contents drawer, and two buttons on any selection:
  - **Ask Claude** saves your question on the page; say "go" in the chat and Claude answers every waiting question there and on the page.
  - **Translate** answers instantly in 50 languages, with pronunciation and meanings for single words.
- **On request:** a read-only walk through the authors' code (what they really ran, with exact parameters), a scan of related literature, and Google Scholar search, cited-by tracking and export to Zotero.

## First use

The first time you give it a paper, PaperLens asks four quick questions and saves the answers:

1. **Where you keep papers:** Zotero, or Skip (then just give a title and it finds a legal copy online).
2. **Your research direction**, in your own words, or Skip (then summaries leave out the "apply it to your research" part).
3. **Where paper folders go:** next to your library, a folder you choose, or don't download supplements.
4. **Remember this folder choice?** If not, it asks again for each paper.

Say "change my research direction" or "reset PaperLens settings" any time to change them.

## Install

**Claude (web, desktop):** find **PaperLens** in Skills → Discover and click **+** (once listed), or upload the plugin folder as a zip in Customize → Skills.

**Claude Code:**

```
/plugin install paperlens --marketplace yufchen723/usefultools
```

or, on older versions:

```
/plugin marketplace add yufchen723/usefultools
/plugin install paperlens@usefultools
```

## What works where

| Feature | Claude desktop app, linked to your computer | Claude on the web, not linked | Claude Code in a terminal |
| --- | --- | --- | --- |
| Find papers in your Zotero folder, save paper folders | ✓ | attach the PDF instead | ✓ |
| Download supplements | ✓ (through a browser on your computer) | — | ✓ where the publisher allows it |
| summary.md and the other files | ✓ | ✓ (as files in the chat) | ✓ |
| Paper Reader with Ask Claude and Translate | ✓ | ✓ | needs the artifact tools of the Claude app |

## Privacy and data

- **Your files:** PaperLens reads only the folders you connect (your Zotero folder and the papers folder) and writes only inside the papers folder. It never changes your Zotero PDFs or library; adding papers to Zotero always asks first.
- **Downloads:** only the publisher's supplementary files, after you confirm the list for each paper. It never downloads raw sequencing data or large datasets, and it uses legal sources only (open access, your own institutional access, PMC, preprints). Files that land in your Downloads folder are moved into the paper folder and removed from Downloads only after a byte-for-byte check, and only with your permission.
- **Settings:** `settings.json` in the `_paperlens` folder inside your papers folder (and a note of its location in Claude's memory if you choose "remember").
- **Paper Reader:** a private artifact in your own Claude account. Your questions and Claude's answers are stored in that artifact's own storage; it stays private unless you share it. Translate uses your Claude account directly from the page and saves nothing.
- **Code:** the authors' repositories are read, never run. Paper2Agent pipelines run only when you ask.
- No data is sent to the author of this plugin.

## Files

| Path | What it is |
| --- | --- |
| `skills/paperlens/SKILL.md` | the workflow Claude follows |
| `skills/paperlens/reader/reader_template.html` | the Paper Reader page template |
| `skills/paperlens/reader/build_reader.py` | builds a reader for one paper (`--type`, `--add-tab`, `--research`, `--translate-to`; needs PyMuPDF) |
| `skills/paperlens/reader/crop_cover.py` | crops the article header from a screenshot for the reader's cover |
| `skills/paperlens/reader/pdf.worker.min.js` | pdf.js worker |

## Credits

- [pdf.js](https://github.com/mozilla/pdf.js) 3.11.174 by Mozilla (Apache-2.0); `pdf.worker.min.js` is included unchanged. The reader also loads pdf.js, [marked](https://github.com/markedjs/marked) (MIT) and [DOMPurify](https://github.com/cure53/DOMPurify) (Apache-2.0 / MPL-2.0) from cdnjs.
- The Google Scholar toolkit is adapted from [cookjohn/gs-skills](https://github.com/cookjohn/gs-skills) (MIT).
- Code-to-tools pipelines come from [Paper2Agent](https://github.com/jmiao24/Paper2Agent) (Miao et al., *Nature* 2026), used only on request.

## License

MIT, see [LICENSE](../LICENSE).
