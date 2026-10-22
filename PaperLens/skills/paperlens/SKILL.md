---
name: "paperlens"
description: "Use when the user gives a paper to read (title, DOI or link), asks for papers in a field, or wants Google Scholar search, cited-by tracking or reference-manager export: paper folder, supplements, typed summary, Paper Reader, code deep-dive."
---

# PaperLens — read a paper end to end

The user gives a paper title (sometimes a DOI or link) and later asks questions about it, down to exactly how the authors ran their analysis. PaperLens sets the paper up so those questions can be answered from the main text, the supplement, the tables and the authors' code: a paper folder, the supplements, a summary shaped by the paper's type, a Paper Reader web page with Ask Claude and Translate, and a read-only code deep-dive.

Run the steps in order. Use a task list. Ask for confirmation only where marked **[ask]**. If the paper folder already exists, reuse what is there (don't re-download, don't re-check citations checked the same day); go straight to whatever is missing, then Step 6.

**Language.** Every file PaperLens writes (summary.md, links.md, the tab files, timeline roles) is in **English**; the reader's Translate button turns any passage into the user's language. Chat replies follow the language the user writes in.

## Hard rules

1. **Never download raw or bulk data.** That means FASTQ, BAM/CRAM, SRA runs, GEO raw tar/supplementary bundles, EGA/dbGaP, and processed data objects (h5ad, rds, loom, Zenodo/figshare datasets) bigger than a few tens of MB. List them in `links.md` with accession and size only. Download one only if the user explicitly asks for that specific file. "Supplementary files" means the publisher's supplementary materials only: SI PDF, supplementary tables, source data, reporting summary, peer review file.
2. **Never run Paper2Agent (Paper2Skill or Paper2MCP) without the user's explicit permission in the current conversation.** Reading the authors' code (Step 7A) is read-only and always allowed. Running pipelines, installing skills or registering MCP servers is not.
3. **Leave no duplicates in Downloads.** Every file you download is moved into the paper folder, checked as identical, then deleted from Downloads (Step 4). Delete only files this session downloaded, by exact name; never anything else in Downloads.
4. Downloading needs the user's OK once per paper (Step 4). Never type credentials, never solve CAPTCHAs yourself. A Google Scholar CAPTCHA stops all Scholar work until the user completes it (Step 9).
5. **Never modify the library's PDF** (the Zotero attachment). Reading copies are built from it; questions and answers live in the Paper Reader (Step 6B), not in the PDF.
6. **Legal full text only.** Use open-access links, the publisher through the user's own institutional access, PMC/Europe PMC and preprints. Never Sci-Hub or other shadow libraries.
7. **Adding items to the user's reference library needs their OK** (Step 9, G6). Searching and reading don't.
8. **Settings come from the user.** Never guess a research direction or a folder; use the settings file (Step 0) or ask.

## Environments

- **Cloud session linked to the user's computer** (Claude app with the desktop app linked): files on the computer are reached with the device tools (`device_bash`, `device_list_dir`, `device_stage_files`, `device_commit_files`, `device_request_folder_access`, `device_request_delete_permission`); only connected folders are reachable, so request access to the library folder and the papers folder once (one request, minimal set). Browsers run on the user's computer (the built-in browser and/or Claude in Chrome; use whichever is present, the user's preferred one first).
- **Claude Code on the user's own machine:** use the local shell and paths directly; WebFetch/WebSearch for pages; `curl` may work for publisher downloads there.
- **No computer access** (plain chat, not linked): ask the user to attach the PDF(s); deliver summary.md and the other files with SendUserFile; the reader still works (Step 6B). Settings can only live in memory then (Step 0).

**Network facts.** From a cloud shell, publisher sites (nature.com, springernature, Cell/Elsevier), Europe PMC, OpenAlex and Crossref usually answer 403, and WebFetch often hits reCAPTCHA on publisher pages. Don't retry with curl. **The browsers on the user's computer work.** Use a browser for publisher pages, citation counts and downloads. Read the matching browser skill (`built-in-browser` or `chrome-browser`) before its first use in a session and load its tools in one ToolSearch call. GitHub (clone, raw files) works from the cloud shell.

## Step 0 — Settings and first-run setup

**Settings file.** `<papers_root>/_paperlens/settings.json`, next to the reader tools:

```json
{
  "version": 1,
  "library": "zotero | none",
  "library_dir": "<folder that holds the library's PDFs, or null>",
  "research": "<the user's research direction, in their words, or null>",
  "research_skipped": false,
  "folder_choice": "library | custom | no-supplements",
  "papers_root": "<folder where paper folders are created>",
  "remember_folder_choice": true,
  "translate_to": null,
  "tools_dir": "<papers_root>/_paperlens"
}
```

**Find the settings at the start of every paper** (first hit wins):
1. Claude Code on the user's machine: `~/.paperlens/settings.json` (a copy of the settings, or `{"settings_path": "<path>"}` pointing to the real file).
2. Memory: a note "PaperLens settings: <path>" or the settings themselves (written when the user chose "remember", Step 0 item 5).
3. Linked computer: in each connected folder, `find <root> -maxdepth 4 -path "*_paperlens/settings.json"`.
None found → this is the first run: do the setup below before anything else.

**First-run setup: one question card (AskUserQuestion), four questions, asked once.**
1. *Library* — header "Library": "Where do you keep your papers?" Options: **Zotero** · **Skip** ("I'll give you a title each time; you find and download it").
2. *Research* — header "Research": "What is your research direction? It shapes the 'Applying it to your research' part of every summary." Options: **I'll type it** ("describe it in Other: field, system, data types, main questions") · **Skip** ("leave the application part out of summaries"). If they chose "I'll type it" but typed nothing, ask once in plain text. Once set (text or Skip) it is never asked again.
3. *Folder* — header "Folder": "Where should paper folders go (main text, supplements, summary)?" Exactly one of: **Next to my library** (a new `papers download/` folder inside the library's folder, e.g. `~/Zotero/papers download/`; with Skip in question 1: `~/Documents/PaperLens/`) · **A folder I choose** (then ask for the path in one line) · **Don't download supplements** (paper folders go where "Next to my library" puts them, but only the main text, summary and links are kept; no supplementary files are downloaded and the reader has no Supplementary tab).
4. *Remember* — header "Remember": "Remember this folder choice?" Options: **Yes, don't ask again** · **No, ask for each paper**.

**After the answers:**
1. **Library folder.** Find where the library keeps its PDFs and request access to it (linked computer) or check it exists (Claude Code):
   - **Zotero:** data directory `~/Zotero` (attachments in `storage/<8-char key>/`). A custom location is in Zotero Settings → Advanced → Files and Folders → Data Directory Location; if `~/Zotero/storage` is missing, ask for it. Linked-file setups (ZotFile, a synced folder) keep PDFs elsewhere: ask.
   - **Skip:** no library folder; Step 1 searches and downloads instead.
2. **Papers root.** Create it (`papers download/`, `~/Documents/PaperLens/`, or their path) and `_paperlens/` inside it; request access to the parent first if needed.
3. **Reader tools.** They ship with this skill, in the `reader/` folder next to this SKILL.md (`${CLAUDE_PLUGIN_ROOT}/skills/paperlens/reader/` when installed as a plugin; otherwise locate it with `find / -path "*paperlens/reader/reader_template.html" 2>/dev/null | head -1`). Copy `reader_template.html`, `build_reader.py`, `crop_cover.py` and `pdf.worker.min.js` into `_paperlens/` so later sessions find them next to the settings (linked computer: `device_commit_files`; Claude Code: copy). Not found: `git clone --depth 1 https://github.com/yufchen723/UsefulTools` in the workspace and take them from `PaperLens/skills/paperlens/reader/`. Neither works: the reader is skipped for now; say so in one line.
4. **Write `settings.json`** and show the user the settings in 3–4 lines.
5. **"Yes, don't ask again"** is an explicit request to remember: also save the settings path (and, with no computer access, the settings themselves) to memory, e.g. "PaperLens settings: <papers_root>/_paperlens/settings.json". On Claude Code also write `~/.paperlens/settings.json`.

**Per-paper folder question.** While `remember_folder_choice` is false, every new paper asks questions 3 and 4 again, merged into the Step 4 download confirmation (one card, not two). The first time the user picks "Yes, don't ask again", set it true and stop asking. With "Don't download supplements" remembered, Step 4 only asks about the main text when it has to be downloaded.

**Changing settings later.** "Change my research direction", "change where papers go", "I use Zotero now", "reset PaperLens settings" → ask only the matching question(s) again and update `settings.json` (and the memory note).

## Step 1 — Find the paper

**With Zotero:**
1. Search the attachment file names under `library_dir` with 3–5 distinctive title words, case-insensitive: `find "<library_dir>" -iname "*clock*" -iname "*proximity*" -name "*.pdf"`. Also check `papers_root`.
2. Nothing: search Zotero's database (`zotero.sqlite`: items, itemData, itemDataValues; always on a temp copy, read-only) or its full-text caches (`storage/*/.zotero-ft-cache`): `grep -lis "<title phrase>" "<library_dir>"/storage/*/.zotero-ft-cache`.
3. **Folder name = the paper's title as stored in the library.** Zotero names attachments `<Authors> - <Year> - <Title>.pdf`: take everything after the first ` - <4-digit year> - `, drop `.pdf`. Keep any prefix the user puts in their titles exactly as written. Replace `/` and `:` with `-`; cut to 150 characters.
4. Not in the library: say so and continue as in "Skip" below (the download goes in Step 4's confirmation); remind them they may want to add it to their library afterwards (G6, **[ask]**).

**Skip (no library) or not found:**
1. Identify the paper: WebSearch / Google Scholar (Step 9 G1) on the exact title → DOI, journal, date. If several candidates match, ask which one.
2. Find a **legal** full-text PDF: the publisher page (open access), PMC / Europe PMC, the preprint (bioRxiv, medRxiv, arXiv), an author or repository copy listed by Scholar's "All versions". Paywalled with no open copy: the user's institutional access in the browser (they sign in themselves), or ask them to attach the PDF.
3. The main-text PDF is downloaded with the supplements in Step 4 (one confirmation) into `<paper folder>/main/<FirstAuthor>_<year>_main.pdf`. Folder name: `<FirstAuthor> <online year> - <Title>`.

**Identity (always).** Run `pdfinfo` (the Subject field often holds the DOI) and read page 1 with `pdftotext -layout`. Record the title, authors (first and last/corresponding), **affiliations of the first and corresponding authors**, journal, volume:pages, received/accepted/online/issue dates, open-access status and DOI. The **first online publication date** ("Published: 18 December 2024") gives the **reader's year**, even when the issue year differs.

**Check the link the user sent.** If its DOI differs from the PDF's DOI, open both and report the mismatch in the summary, naming what the other link actually is.

## Step 2 — Build the paper folder

```
<papers_root>/<paper folder>/
├── links.md            # every useful link of the paper as clickable markdown (Step 3); also the reader's Links tab
├── summary.md          # the Step 6 summary, opened in the side panel
├── experiments.md      # wet-lab papers (type B): models, assays and the logic map → reader tab "Experiments"
├── parameters.md       # dry/method papers (type C): every parameter and the training setup → "Parameters & training"
├── tutorial.md         # dry/method papers (type C): the package's official tutorial in English, read-only → "Tutorial"
├── timeline.json       # reviews (type D): every cited paper, key ≤ 30 → reader tab "Timeline" (+ timeline.md, readable copy)
├── cover.png           # Step 3: crop of the article header on the publisher's page (the reader's card cover + cover)
├── figures/            # Step 6: fig1.jpg … figN.jpg, crops of the main figures for "The story by figure"
├── code_notes.md       # Step 7A: what the authors actually ran (only once Step 7A is done)
├── main/               # only when the main text was downloaded (no library copy)
├── supplementary/      # downloaded files, descriptive names; zips unzipped into subfolders (not with "Don't download supplements")
├── text/               # main_text.txt, supplementary_info.txt, peer_review.txt (pdftotext -layout)
└── paper2agent/        # only if Step 7B is run (with permission)
```

Extract `text/main_text.txt` right away (`pdftotext -layout`). Later questions are answered by grepping these text files, which is much faster than re-reading PDFs. Tip: `pdftotext -raw` gives a single-column stream that is easier to read on two-column journals (write it to a temp file, not the paper folder).

Append one line per paper to `<papers_root>/reading-log.md`: date · folder name · DOI · type (A–D) · one-line relevance (if a research direction is set) · reader link. Skip if the paper already has a line.

## Step 3 — Publisher page: supplements, code and data links

Open the article page in a browser (the DOI URL). Collect everything in **one** `javascript_tool` call:
- citation meta tags (`citation_*`, `dc.identifier`)
- every link whose href matches the supplement patterns below, with its link text
- the text of the Data availability, Code availability and Supplementary Information sections
- Extended Data figure titles

Supplement link patterns by publisher:
- **Nature / Springer:** `media.springernature.com/.../MediaObjects/<id>_MOESM<n>_ESM.<ext>` or `static-content.springer.com/esm/...`. MOESM numbering usually runs SI PDF, Reporting Summary, Peer Review File, Supplementary Tables, Source Data.
- **Cell Press / Elsevier:** `mmc<n>.pdf|xlsx` (often on `ars.els-cdn.com`), Key Resources Table.
- **bioRxiv / medRxiv:** `/content/biorxiv/early/.../DC<n>/embed/media-<n>.xlsx` under the "Supplementary Material" tab.
- **Science:** `science.org/doi/suppl/...`. **PNAS / Oxford / Wiley:** "Supporting Information" links.

From the availability statements and Methods, record in `links.md` (links only, no downloads; Hard rule 1):
- every GitHub, GitLab, Zenodo, figshare, GEO/SRA/EGA, CELLxGENE, Broad Single Cell Portal, HCA or dbGaP link, with its size when the page shows it
- **interactive portals and external datasets** (cell browsers, shiny apps, atlases)
- the GitHub repos themselves: open each README with WebFetch and note install, main API, the notebook→figure map if given, the data-download step and licence

**Separately published key files (they become extra reader tabs).** Check the article page for important files published as their own document, apart from the main PDF and the SI: a separate **Methods** PDF, STAR Methods or an online-methods PDF, an Extended Data PDF, a protocol or user guide. Each one becomes an extra reader tab (Step 6B, `--extra "Methods=<file>"`), downloaded with the supplements in Step 4. If Methods is inside the main text (as in most Nature articles), there is **no** Methods tab; it's reachable through Contents.

**links.md format (also the reader's Links tab).** Write every useful link as clickable markdown (`[label](url)`), with a one-line description, under these headings in this order (leave out a heading with nothing in it):
1. `# Links — <First author> et al. <year>, *<Journal>* <vol>:<pages>` + one line: title · online / issue dates · open-access licence
2. `## Publication`: the journal's own article page (always first), DOI, PubMed / PMC, peer review file, reporting summary, Google Scholar cited-by link (data-cid) and the citation counts with the date checked
3. `## Code`: every GitHub/GitLab repo (what each holds), packages, hosted Paper2Agent MCPs
4. `## Data availability (this study)`: the paper's own accessions, with size when shown, marked "links only; not downloaded"
5. `## External datasets used`: every external dataset and portal the paper uses or points to, one line each
6. `## Supplementary files`: the publisher's supplementary file URLs (full URLs)
7. `## Authors' earlier work this paper builds on`: from Step 5 (DOI links)
8. `## People and press`: lab pages, first author's current position, institute news or press coverage when found
9. `## This paper's reader`: `[<Firstauthor> <online year> Paper Reader](url)` + one line on what it holds (added in Step 6B)

**Cover image (the reader's card cover and cover).** A crop of the article's header as it looks on the publisher's site: masthead (journal logo + menu), breadcrumb, "Article · Open access · Published <date>", title, authors, journal/volume line and the Accesses · Citations · Altmetric bar. Save it as `<paper folder>/cover.png`.
- **It is the card cover.** The reader's card in the user's artifact gallery shows a snapshot of the page's first paint; the reader template paints the cover first, so the card shows this crop instead of a loading screen.
- **If the user pastes a screenshot of the header, use theirs:** convert to RGB PNG with PIL (`optimize=True`).
- **Otherwise capture it in Claude in Chrome** (its screenshots can be saved to the workspace):
  1. Open the article URL in a new tab. One `javascript_tool` call finds the blocks and scrolls so the masthead is at the top:
     `const h1=document.querySelector('h1'); const art=document.querySelector('.c-article-header, .article-header, header.article-header') || h1.closest('header, section, div'); const mast=[...document.querySelectorAll('header, [role="banner"], .c-header')].find(e => e!==art && !e.contains(art) && e.getBoundingClientRect().height>30 && e.querySelector('img,svg')); scrollTo(0, Math.max(0,(mast||art).getBoundingClientRect().top+scrollY-8)); await new Promise(r=>setTimeout(r,400)); const a=art.getBoundingClientRect(), m=(mast||art).getBoundingClientRect(); ({vw:innerWidth, rect:[a.left, m.top, a.right, a.bottom].map(Math.round), fits:a.bottom<=innerHeight})`
     (Nature/Springer: `.c-header` + `.c-article-header`. Other publishers: check the rect makes sense; adjust the selectors.) If `fits` is false, drop the masthead (use `a.top`).
  2. Move the pointer off the header (`computer` `hover` outside the rect), then `computer` `screenshot` with `save_to_disk: true` and **no `scale`** (full scale = sharp cover). The result names the saved path.
  3. `python3 crop_cover.py <saved jpg> cover.png --rect <rect> --vw <vw>` (in `_paperlens/`; 16 px side/bottom padding, none above the masthead). Look at the PNG once; ads, cookie banners or a stray cursor mean: dismiss/hover and retake.
  4. Put `cover.png` into the paper folder (`device_commit_files` on a linked computer), close the tab.
- No cover possible? Build the reader without `--cover`; it starts at page 1. Say so in one line.

Paywalled article: the user's institutional access may already be signed in to the browser. If a sign-in wall appears, ask the user to sign in themselves and wait. Never type credentials.

## Step 4 — Download supplementary files **[ask once per paper]**

Send one confirmation listing each file (name, what it holds, source host, size if shown), e.g. "Download these 5 files (SI PDF Supp Figs 1–8, Tables 1–16 zip, Peer Review File, Reporting Summary, Source Data Fig 5) from media.springernature.com into the paper folder?" Include the main-text PDF when Step 1 had to find it online. Always include the **Peer Review File** when the journal publishes one: the summary's reviewer part depends on it. While `remember_folder_choice` is false, this same card also asks the folder question and "Remember this folder choice?" (Step 0).
- **"Don't download supplements"** (settings): skip the supplements entirely; only the main text is downloaded if needed. The summary then rests on the main text, and says so in "Folder and access".

**Downloads through Claude in Chrome** (preferred: it saves silently). The built-in browser pane raises a Save dialog for every file, which Claude can't click. Once per user, check that Chrome → Settings → Downloads → "Ask where to save each file before downloading" is **off**; if files don't arrive, ask the user to turn it off. A web page can't choose a folder, so files land in Downloads first and are then moved (items 5–6). Read the `chrome-browser` skill first and load its tools in one ToolSearch call (`tabs_context_mcp, navigate, javascript_tool, tabs_close_mcp, list_connected_browsers`).

Download mechanism:
1. `tabs_context_mcp` (createIfEmpty), then `navigate` a new tab to the **first file's URL**. This puts the tab on the file host's origin, so later fetches are same-origin and CORS doesn't block them.
2. In one `javascript_tool` call, loop over the paper's files on that host: `fetch(url)` → `blob` → an `<a download="<orig name>">` with an object URL → `click()`. Wait ~1.5 s between files. Return status and byte size per file. Keep the exact file names: these are the only files you may later delete from Downloads.
3. Check every file arrived in Downloads with matching byte sizes (`ls -lt … | head`). Retry a missing file once. If nothing arrives within ~15 s, Chrome is probably asking where to save, or a different Chrome is connected (`list_connected_browsers`): ask the user, don't retry. Close the tabs you opened.
4. Fallback without Chrome: the built-in browser (zip/xlsx: `navigate` to the file URL; PDFs: the same blob trick from the file host's origin). Tell the user up front they'll need to click Save (to Downloads) in each dialog. Claude Code: `curl -L -o` may work directly into the paper folder (then skip items 5–6).
5. **Move into the paper folder.** Deleting in Downloads needs a permission that lasts one session: before the first move, call `device_request_delete_permission` for the Downloads folder (reason: "remove downloaded supplementary files after moving them into the paper folder"). For each downloaded file: `cp` it to `supplementary/<descriptive name>` (e.g. `MOESM1_Supplementary_Information_SuppFigs1-8.pdf`, `mmc2_TableS2_markers.xlsx`; the main text to `main/`); `cmp -s` original and copy; **only if identical**, `rm` the original; report any file kept and why. Then `unzip -o -q` archives into a subfolder (keep the zip), `pdftotext -layout` each PDF into `text/`, and `ls` Downloads to confirm none of this paper's files remain.
6. If the user declines the delete permission, leave the originals and tell them they are still in Downloads. Don't ask again that session.

## Step 5 — Citations and author background

**Citations.** Open each in the browser and read with `get_page_text` or `find`:
- **Google Scholar:** Step 9 G1 with the exact title in quotes. Record **Cited by N**, the **data-cid** (needed for G3 cited-by tracking) and any free full-text link. Put the data-cid in `links.md`. CAPTCHA: follow Step 9's rule; if the user isn't around, skip Scholar and say so.
- **Europe PMC:** `https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=DOI:<doi>&resultType=lite&format=json` → `citedByCount`, PMID, PMCID.
- **OpenAlex:** `https://api.openalex.org/works/doi:<doi>?select=cited_by_count,counts_by_year,publication_date` → total and per-year counts.

Report all three with the date checked, and interpret them for the paper's age, e.g. "129 Scholar / 88 Europe PMC in 22 months; ~45/yr, fast-accumulating."

**Author background (always).** Who the first and corresponding authors are, and whether this paper follows their own earlier work:
1. **Self-citations first:** grep the reference list in `text/main_text.txt` for the first and corresponding authors' surnames; their own cited papers are usually the direct predecessors (an earlier dataset, a reused tool, a finding this paper extends). Note the text that cites them.
2. **Lab focus:** WebSearch the corresponding author's lab page for the lab's theme in one line. Use the affiliations from page 1; don't guess.
3. The **1–3 most relevant prior papers** (title, journal, year, DOI link), one clause each: direct follow-up / reuses their tool / extends their dataset / tests a hypothesis from it — or "no clear prior work on this topic from these labs".
4. **Institution:** one sentence on the corresponding lab's institute and department.
Add the prior papers' DOIs to `links.md`.

## Step 6 — Read, then write summary.md and open it in the side panel

**Pick the paper type first.** The summary's parts and the reader's extra tabs follow the paper's type. Decide it from the abstract, the figure list and Methods, then say it in **one chat line** before writing ("Type: B · wet-lab/mechanistic, borrowing a Parameters tab for the model in Fig. 6"); the user can switch it, and you rebuild.

| Type | Signals | Summary framework | Extra reader tabs (files) |
|---|---|---|---|
| **A · Omics / data-driven** (default) | atlas, single-cell/spatial/bulk profiling, cohorts of samples, discovery from data, analysis pipelines | the parts below | none: Summary · Links |
| **B · Wet-lab / mechanistic** | most figures are perturbations (KO/KD/CRISPR, drugs, overexpression), animal models, westerns, IF/IHC, flow, rescue experiments | Framework B | **Experiments** (`experiments.md`) |
| **C · Dry / method / tool** | a new algorithm, model, software package or benchmark is the main product; GitHub + docs + tutorial; figures are schematics and benchmarks | Framework C | **Parameters & training** (`parameters.md`), **Tutorial** (`tutorial.md`) |
| **D · Review** | "Review" / "Perspective" article type, no new data, organised by themes, long reference list | Framework D | **Timeline** (`timeline.json`); no Supplementary tab when there is none |

- **Mixed papers:** use the **main type's** framework and borrow the other type's tabs (and, if useful, one of its parts as a `## Deep dive`). Example: an omics atlas that validates a mechanism by knockout = A + Experiments tab; a wet-lab paper that also releases a tool = B + Parameters & training and Tutorial. Build with `--type <main> --add-tab <key>` (Step 6B).
- **The research part.** If `settings.research` is set, every framework has a part **"Applying it to your research"** written for that direction (and the memory notes about their project, if any). If the user skipped it (`research_skipped`), **leave that part out** and number the remaining parts consecutively; also leave out "Relevance to your research" lines everywhere else.
- The tab files follow the same layout rules as summary.md (one `#` title, numbered `##` parts with `---` dividers, short bullets, tables); their `##` headings are the Contents drawer in that tab.

Read the main text (Results and Discussion), then the **Methods** for the core analysis (needed for "The exact recipe"), then the **Peer Review File** if there is one. For the Technology part, also read the Code availability statement and the Reporting Summary's "Software and code" section (package versions). Use the supplement and tables for anything the summary claims about them. Check every number against the text. Mark suggestive results honestly, e.g. a gene at P = 0.059 is "trending", not "the mediator".

**Deliver it as a file shown in the side panel, not as chat text.** Never paste the full summary into the chat.
1. **Write** `<paper folder>/summary.md` (create the folder first if needed; overwrite an older summary.md unless the user wants the old one kept). Linked computer: write it with `device_bash` using a quoted heredoc or a short python write. Claude Code: write it locally. No computer: write it in the workspace.
2. **Open it in the side panel:** linked computer: `device_stage_files` the summary.md, then `SendUserFile` the staged path with `display: "render"`, `status: "normal"`, caption `<First author> et al. <year> — summary.md`. Otherwise `SendUserFile` the file you wrote with `display: "render"` (and copy it to the paper folder when the computer is reachable). If SendUserFile isn't available, give the file path.
3. **Chat reply = 2–3 lines only:** the "In brief" two sentences, one line on anything notable (a link mismatch, a Methods inconsistency), one line that the Paper Reader is ready (select a sentence → Ask Claude or Translate), and one Next offer.
4. Whenever summary.md or a tab file changes later (code-confirmed recipe after Step 7A, a correction), re-send it with `display: "render"`, **push it to the reader** (Step 6B, Text-tab sync), and say in one line what changed.

Style inside summary.md: compact, answer-first, technical terms followed by a plain-language translation, key numbers in bold, no step recap.

**Layout:**
- The paper title is the only `#` heading.
- Every part is its own numbered `##` heading (`## 1 · In brief`, `## 2 · …`). Never a bold label at the start of a paragraph.
- A `---` divider line before every `##` heading, with a blank line before and after it.
- Sub-parts are `###` headings (Citations / Authors and lineage / Institution, the Technology groups, Fig. 1 / Fig. 2 in the story).
- Short bullets (≤ 2–3 lines each) or tables, not long paragraphs. Bold only key numbers and names.
- Sections added later (deep dives answering questions, corrections) go at the end, after Sources, each with a `---` and `## Deep dive: <topic>`.

The reader's Contents drawer lists these headings, so they double as its navigation. **Type A (omics / data-driven) uses these parts in this order** (Frameworks B–D after the template; the research part only when a research direction is set):

```
# <Title>

*<First author> … <Last/corresponding authors> · <Journal> <vol>, <pages> · online <date> / issue <date> · <OA status>* ·
doi:<doi> (https://doi.org/<doi>)

---

## 1 · In brief

<exactly two sentences, plain language, key numbers in bold. Sentence 1 = what they did (system, platform, scale, core
method). Sentence 2 = what they found (the headline finding(s) and the main mechanism/candidate)>.

---

## 2 · Citations, authors and institution

### Citations
<Scholar N · Europe PMC N · OpenAlex N (per-year)>, checked <date> — <age-normalised read>. doi link.

### Authors and lineage
- <first author (role; current position if moved)>
- <corresponding author(s) and their lab's focus>
- <1–3 prior papers this one builds on (title, journal, year, doi link), one clause each on how — or "no clear prior work on this topic">

### Institution
<one sentence on the corresponding lab's institute/department>.

---

## 3 · Technology

### Platform and assay
<resolution (single-cell / spot / pixel size), panel size or whole-transcriptome/genome, modalities (RNA, ATAC, protein…),
segmentation if imaging-based, orthogonal validation assays>

### Analysis packages and tools
<bullets, each package **with its version** (from Methods, Code availability and the Reporting Summary's "Software and
code"), what it was used for and its key parameters; "version not reported" when missing>

### Tools the authors built
<new in this paper, or their own earlier tools reused, marked as theirs, with the repo link>

<Clinical paper: `### Study design and endpoints`, `### Measurements`, `### Statistics` instead. Mixed papers combine the groups.>

---

## 4 · Cohorts / datasets / models

<table, columns adapted to the paper:
  - omics/computational: | Dataset | Species / tissue | Design (groups, ages, conditions) | n (patients/animals, sections) | n cells/spots | Generated here or external (accession) |
  - human/clinical: | Cohort | Disease / setting | n patients | Key clinical features | Source / accession |
  Include validation cohorts and external datasets, marked "external".>

---

## 5 · Logic of the paper

<4–6 numbered steps: the question → what they built or measured → how each step sets up the next → how they validated it
→ the mechanism step. One line each, the supporting figure panel in parentheses after each clause (main figure first, then
Extended Data / Supplementary), e.g. "1. **Map** — build a lifespan spatial single-cell atlas (Fig. 1a,b; ED Fig. 1) and
describe what changes: cell composition (Fig. 1c,d) and 9 gene-trajectory shapes (Fig. 1f–h; ED Fig. 4).">

---

## 6 · Main findings

<3–6 bullets, each starting with the logic step that produced it (e.g. "*(Step 2)*"), key numbers in bold, the figure
panel(s) in parentheses after each claim ("Supp Table N" when a table carries the number), and the evidence level in
brackets [computational only / orthogonal validation (IF, RNAscope, external cohort) / perturbation].>

---

## 7 · The story by figure

### Fig. 1 — <short title>
<one short paragraph or 2–4 bullets: what was done, key numbers in bold, term + plain translation; the controls and the
Extended Data / Supplementary panels when they carry a claim>

![Fig. 1](figures/fig1.jpg)

> **Fig. 1 | <legend title sentence>** **a**, <the full legend, verbatim> **b**, …

*Figure and legend reproduced from <First author> et al., <Journal> <vol>, <pages> (<year>), <licence>. Click the figure in the reader to enlarge.*

### Fig. 2 — …
(every main figure: explanation, figure crop, legend, credit line)

---

## 8 · The exact recipe

<1–2 lines naming the core analysis method, then a table | Step | Value | of the parameters that matter for reuse:
preprocessing, model and hyperparameters, CV scheme, distance cutoffs / neighbourhood definitions, effect-size statistic,
filters, null model / permutations, thresholds. Cite the Methods section. After Step 7A, mark code-confirmed values and any
Methods-vs-code differences.>

---

## 9 · What the reviewers attacked

<from the Peer Review File: 3–5 bullets "Reviewer N: concern → what the authors did / whether it was still accepted".
No peer review file: say so and list the 2–3 weaknesses a reviewer would most likely raise.>

---

## 10 · Applying it to your research          ← only when settings.research is set

<3–4 bullets tied to the user's stated direction: what to borrow and for which step of their work; how to translate the
paper's parameters and design to their system and data types; pitfalls specific to their setting.>

**Relevance to your research:** <benchmark / competitor / method template / biology background / annotation reference>.

---

## 11 · In plain words

Problem → Solution (a plain-language analogy) → Results (the quantitative ones). 2–3 lines, no jargon left untranslated.

---

## 12 · Folder and access

- <where the main text came from (library path or downloaded source); link check only if their link ≠ the paper>
- <supplementary files as a compact list with downloaded ✓ / not yet / not downloaded (settings)>
- <code repos (one line each + notebook→figure map), data accessions with sizes (links only), portals, hosted Paper2Agent MCP>
- <what was blocked and how it was worked around; Downloads cleaned ✓>

**Next:** <one natural offer, e.g. code deep-dive (7A) or a related-literature brief (Step 8)>.

---

## Sources

[Title](URL) list (article, PMC, repos, prior papers, lab page, Scholar/Europe PMC).
```

**Framework B · Wet-lab / mechanistic.** Same layout rules, header line, Sources and figure crops as type A. Parts:
1. `## In brief`: two sentences (what system and perturbations; what mechanism they found, key numbers in bold).
2. `## Citations, authors and institution`: as type A.
3. `## Models and systems`: table | Model | Species / strain / genotype or line | Sex, age | Intervention (dose, route, timing) | n per group | Readouts |; cell lines, organoids, xenografts, PDX and patient samples get their own rows; mark external ones.
4. `## Key assays and reagents`: table | Assay | What it measures (plain words) | Readout / quantification | Used in |; then `### Quantification and statistics` (software, tests, n definition: animals vs cells vs fields, blinding, randomisation).
5. `## The experimental argument`: the claim chain, 4–8 numbered claims; each = claim → experiment → key control → result (number) → **evidence level** [correlation / necessity (loss-of-function) / sufficiency (gain-of-function) / rescue / in vivo / human tissue] (figure panels). Say which link in the chain is weakest.
6. `## Main findings`: as type A, each with its evidence level.
7. `## The story by figure`: as type A.
8. `## The exact protocol`: table | Step | Condition | of what matters for repeating it: doses and timings, antibodies (target, clone, catalogue no., dilution), sgRNA/shRNA/primer IDs, imaging settings, inclusion/exclusion, statistical test per figure. Cite the Methods subsection.
9. `## What the reviewers attacked`: as type A (wet-lab reviewers usually ask for a second model, rescue, in vivo or human validation).
10. `## Applying it to your research` (only with a research direction): which part of the mechanism the user could test or look for in their system, what would count as support versus contradiction, what their data can and cannot show; then **Relevance to your research**.
11. `## In plain words`. 12. `## Folder and access`.
(Number the parts consecutively: `## 1 · In brief` …)

`experiments.md` (reader tab **Experiments**): `# Experiments — <First author> et al. <year>`, then `## 1 · Models` (the full Models table), `## 2 · Assays` (every assay, also the minor ones, with the figure panels that use it), `## 3 · Logic map` (a table | # | Claim | Experiment | Control | Result | Evidence level | Fig. |, one row per experiment in the order of the argument, plus a 3–6 line indented text tree claim → sub-claims → experiments), `## 4 · Reagents and resources` (antibodies, lines, plasmids, animals, from the Key Resources Table / Reporting Summary), `## 5 · Gaps` (missing controls, n = 3 cell-line experiments, in vitro only, etc.).

**Framework C · Dry / method / tool.** Same layout rules. Parts:
1. `## In brief`: two sentences (what it is, input → output; how much better than what, on which benchmark).
2. `## Citations, authors and institution`: as type A, plus the repo's stars, last commit and open issues (from the GitHub page, date checked).
3. `## What problem it solves`: the task, what existing tools do and where they fail, what is new here (one line each).
4. `## How it works`: the architecture or algorithm in 4–8 bullets, inputs and outputs with their shapes/formats, the loss or objective, each with a plain-language translation; a small inline text diagram only when it helps.
5. `## Training and data`: training / reference datasets (table as in type A part 4), preprocessing, splits, the headline hyperparameters; the full list lives in the Parameters & training tab.
6. `## Benchmarks`: table | Task | Datasets | Metric | Competitors | Result | Fair? | (same data splits, defaults vs tuned competitors, who ran the competitors); then 2–3 bullets on the strongest and weakest results.
7. `## The story by figure`: as type A.
8. `## Software`: package name, language, install command, version used in the paper, licence, dependencies, GPU/CPU needs and runtime, docs and tutorial links, Paper2Agent MCP if hosted; read from the README and docs (Step 7A rules: read only, never run).
9. `## What the reviewers attacked`: as type A.
10. `## Applying it to your research` (only with a research direction): can it take the user's data (input format, modality, resolution, sample size), what to change (parameters from the Parameters tab), what to benchmark it against, failure modes to expect; then **Relevance to your research**.
11. `## In plain words`. 12. `## Folder and access`.
(Number the parts consecutively.)

`parameters.md` (reader tab **Parameters & training**): `# Parameters & training — <tool> (<First author> et al. <year>)`, then `## 1 · Parameters` (table | Parameter | Default | Value in the paper | What it does (plain words) | Where set (Methods section or `file:line`) |, every user-facing parameter and every hyperparameter, grouped by stage with `###`), `## 2 · Training setup` (data, splits, epochs, optimiser, learning rate and schedule, batch size, early stopping, seeds, hardware, wall time), `## 3 · Evaluation` (each metric defined in one line, how computed, which data), `## 4 · Methods vs code` (differences found once Step 7A is done; until then "not checked yet"). Values come from Methods, the Supplementary and the code (Step 7A); mark which.

`tutorial.md` (reader tab **Tutorial**, **in English**): converted from the package's **official** tutorial (docs site, README quick start or the repo's tutorial notebooks; name the source URL and the version/commit at the top). `# Tutorial — <tool>`, then one `## Step N · <task>` per step: one or two lines on what the step does and why, the code **verbatim** from the source in fenced blocks with the language (`python`, `r`, `bash`; the reader adds a Copy button to each), and what output to expect as the source describes it. End with `## Adapting it to your data` (only with a research direction). **Read-only:** Claude never runs the tutorial or installs the package (Step 7A rules); write "Not run by Claude" under the title. Several tutorials: convert the main quick-start one and list links to the others.

**Framework D · Review.** The summary follows **the review's own structure**. Parts:
1. `## 1 · In brief`: two sentences (scope; the review's main thesis or message).
2. `## 2 · Citations, authors and institution`: as type A, plus the authors' own primary papers in this field.
3. `## 3 · Scope and structure`: table | Review section | The question it answers | Refs cited (n) | Key figure/box |, one row per top-level section in the review's order.
4. `## 4 · <first review section's title>` … one numbered `##` part per top-level review section, in order, each with 3–6 bullets of the section's key points, the key papers it rests on (Author year, linked) and any debate or conflicting evidence it names; the review's figures and boxes go in the part they belong to (crop + verbatim legend when CC licensed, as in type A).
5. Then, continuing the numbering: `## <n> · Open questions and future directions` (as the authors list them, plus gaps you see), `## <n> · Key papers to read next` (≤ 10, one line each on why; all are in the Timeline tab), `## <n> · Applying it to your research` (only with a research direction), `## <n> · In plain words`, `## <n> · Folder and access`.
No "What the reviewers attacked" unless a peer review file exists. Build the reader **without `--si`** when the review has no supplementary PDF.

**Timeline (type D; reader tab Timeline, file `timeline.json`).** Every reference of the review goes in; the tab shows the **key papers only by default (never more than 30)** and a **Show all (N)** switch shows every one. Procedure:
1. **Get the reference list with DOIs** from the publisher page in the browser, one `javascript_tool` call (Nature: `.c-article-references__item` → number, text, the "Article"/DOI link; Cell/Elsevier: `.reference` blocks with `a[href*="doi.org"]`; others: the reference section's `a[href*="doi.org"]`). Fallback for references without a DOI: Crossref in the browser (`https://api.crossref.org/works?query.bibliographic=<url-encoded reference>&rows=1`, accept only a clear title match), else OpenAlex search; still nothing → leave `doi` empty and set `url` to a Google Scholar search on the title (`https://scholar.google.com/scholar?q=<title>`). Never invent a DOI.
2. **Where each is cited:** from the PDF with PyMuPDF, per page: the citation markers (superscript numbers, size < 7 pt, including ranges like 12–15 and lists like 3,7,9; or "Surname et al., 2019" for author-year journals) → `pages_in_review` (PDF page numbers, so "p. N" opens that page in the reader's Main text), and the review section heading above each marker → `sections`.
3. **Fields per item:** `ref` (number in the review), `year`, `date` (YYYY-MM when known, for ordering within a year), `authors` ("First et al."), `title`, `journal`, `doi`, `url` (optional; default `https://doi.org/<doi>`), `tag` (one of Landmark · Method · Tool · Dataset/Atlas · Mechanism · Clinical · Review), `role` (one sentence, in English: what this paper contributes to the review's argument, from the sentence that cites it; ≤ 25 words, ≤ 12 for non-key papers if the list is long), `sections`, `pages_in_review`, `key` (true or false).
4. **Key papers (≤ 30, ordered by importance in the JSON):** the ones the review discusses in depth (several sentences, a figure or box, cited in more than one section), the landmarks a section is built on, and the newest papers that changed the field. The reader keeps at most the first 30 marked `key`.
5. **Write** `timeline.json` = `{"title": "Timeline — papers cited in <First author> et al. <year>", "items": [...]}` into the paper folder, plus `timeline.md` (a readable copy: key papers by year, then "All references" by number). Push to the reader (Step 6B, doc `timeline/current`). If the `db` write is refused as too large, shorten non-key roles, drop `date` for non-key items and retry once; if it still fails, say so.

Figure citations: write them as "Fig. 1c", "ED Fig. 9g" (Extended Data), "Supp Fig. 6b" (Supplementary). Take every number from where the paper itself cites it (grep "Fig." / "Extended Data Fig." / "Supplementary Fig." around that claim in `text/main_text.txt`, and check the legend for the panel letter); never guess a panel. No figure cited for a claim: write "(text only)".

**Figure crops and legends in "The story by figure".** Below each figure's explanation: the crop of that main figure, its legend, the credit line (template above). Main figures only.
- **Licence first.** Crop + verbatim legend only when the article is open access under a Creative Commons licence (CC BY, BY-NC, BY-NC-ND; read it on the article page or page 1). Name the licence in the credit line. Paywalled article: no crop and no verbatim legend; write one line instead, "Figure: main text p. <n> in the reader", plus a 1–2 sentence paraphrase of what the panels show.
- **Find the legend** with PyMuPDF `page.get_text('dict')`: the block starting `Fig. N |` (Nature) / `Figure N.` (Cell) sets the legend font size (Nature: 7.0 pt vs 9.8 pt body). Collect the blocks of that size from the start block down, left column then right column, stopping at the first body-size block or the footer. A figure page saying "Fig. N | See next page for caption." has its legend at the top of the next page.
- **Clean the legend text:** drop superscript citation spans (size < 6 pt and only digits/commas/dashes, otherwise they glue onto words), join lines (keep a line-end hyphen only for real compounds like "two-tailed"), remove soft hyphens (`\xad`), collapse spaces. Format: `> **Fig. N | <title sentence>.** <rest>`, panel letters bolded (`**a**,`, `**a,b**,`).
- **Find the figure box:** union of `page.get_drawings()` rects, `page.get_image_info()` boxes and small-font text blocks between the running header and the legend start (or the "See next page" line). Pad 3–4 pt, starting just below the header rule.
- **Render** `page.get_pixmap(dpi=200, clip=Rect(box))`, save as RGB JPEG quality 90 (`subsampling=0`) to `<paper folder>/figures/figN.jpg`. Look at a contact sheet of all crops once: nothing cut off, no header rule, no body text.
- **Where they show:** in the reader's Summary tab (published with the reader as `figures/figN.jpg`; click to enlarge) and in Markdown apps opened from the paper folder. The side panel shows summary.md's text only, so say in one line that the figures are in the reader.

## Step 6B — Paper Reader: read and ask (right after summary.md)

Order for every new paper: **summary.md first** (Step 6), **then** the Paper Reader.

**What it is:** one published Artifact per paper, named `<Firstauthor> <year> Paper Reader` (year = first online publication year). Tabs, in this order: **Main text · <extra PDFs> · Supplementary · Summary · <type tabs> · Links**. Type tabs: none for A; **Experiments** for B; **Parameters & training · Tutorial** for C; **Timeline** for D; a mixed paper adds the borrowed ones. No Supplementary tab when there is no SI PDF (or supplements aren't downloaded). Features (all built into the template):
- PDF tabs show the real pages with a selectable text layer (pdf.js 3.11.174); the Main text tab opens with the **cover** (clicking it opens the article on the publisher's site). Text tabs render their Markdown; code blocks get a **Copy** button; figures open larger on click.
- **Timeline** tab: a vertical timeline by year; each card has the title linked to the published paper, a type tag, authors · journal · year · ref. N, the role sentence and "In the review: <sections> · p. N" links that open that page; **Show all (N)** / **Key papers only**, search, section and type filters.
- A page counter, zoom, and a **Contents · Notes** drawer (sections, figures, the headings of the text tabs, every question with its answer); the drawer can be widened by dragging its left edge.
- Selecting text in any tab shows **Ask Claude** and **Translate**. Ask Claude opens a box (bottom-left; draggable) with the quote, quick questions (Explain simply / How was it computed? / Evidence? / **For my research**, shown only when a research direction is set) and a text field. **Send** stores the question on the page (`db` collection `qa`) with a "…" pin on the passage; it is answered when the user says "go" (below), then shows in Notes and as a yellow "Q" pin on the left edge. Each note shows when it was asked and answered, can be collapsed, and can be deleted (two clicks, with Undo).
- **Translate** answers instantly from the page through the `sample` capability (no "go", nothing saved): a word gets its pronunciation, translation, meanings and the meaning in this sentence; a passage gets a full translation keeping gene names, symbols, numbers and figure references. A menu of the 50 most-used languages; the default is the browser's language (or Chinese (Simplified) when the browser is English, or `--translate-to`), and the choice is remembered in that browser. 🔊 reads aloud with the computer's voices. The first use asks the user once to allow the page to use Claude.
- Each tab keeps its place when switching tabs.

**Build and publish (in the workspace):**
1. Get the tools from `<papers_root>/_paperlens/` (linked computer: `device_stage_files`), else from this skill's `reader/` folder (Step 0, item 3), else from `https://github.com/yufchen723/UsefulTools` (`PaperLens/skills/paperlens/reader/`). PyMuPDF: `pip install --break-system-packages pymupdf`.
2. `python3 build_reader.py --main <main PDF> [--extra "Methods=<methods PDF>" …] [--si <SI PDF>] --out <dir> --title "<full title>" --short "<First author> et al. <year> · <Journal>" --name "<Firstauthor> <year> Paper Reader" [--cover <paper folder>/cover.png --url <article URL>] --type <omics|wet|dry|review> [--add-tab <experiments|parameters|tutorial|timeline> …] [--research "<settings.research>"] [--translate-to <settings.translate_to>] --template reader_template.html`. It writes light PDF copies (150 dpi images; each must stay < 15 MB) and `index.html` with the tabs and contents lists. Check the printed sizes and that the contents lists look right; fix the cfg JSON by hand if a PDF has no outline.
3. Copy `pdf.worker.min.js` into `<dir>` and publish: `Artifact` publish `file_path: <dir>/index.html`, `files: {"main.pdf": …, "extra1.pdf": … (if any), "si.pdf": … (if any), "cover.png": … (if any), "figures/fig1.jpg": … (one per figure crop), "pdf.worker.min.js": …}`, `title: "<Firstauthor> <year> Paper Reader"`, `capabilities: {"db": {}, "user": {}, "sample": {}}` (always all three: `sample` powers Translate, and a non-empty declaration replaces the whole set), `icon: "book"`, description "Read <short>: main text, supplementary, summary and all the paper's links; select any passage to translate it instantly or ask Claude, and each answer is saved on the page."
4. Add the reader URL to `links.md` (`## This paper's reader`), then push summary.md, links.md and the type's files into the reader (Text-tab sync).
5. Functional pass once: `ArtifactData` `query` collection `qa` (empty is fine) and `get` `summary/current`, `links/current` and each type tab's `<key>/current`. Translate can't be exercised from the session (it runs on the user's own account when they click): say so in one line.

**Text-tab sync (summary.md, links.md and the type files → reader).** The reader shows each text tab from its `db` document `<key>/current` (`summary`, `links`, `experiments`, `parameters`, `tutorial`, `timeline`): `{md, updated_at, source: "<file name>", source_mtime_ms, source_bytes}`; the Timeline document holds `{title, items, updated_at, source: "timeline.json", source_mtime_ms, source_bytes}` instead of `md`. An open reader updates by itself. Push = read the file's mtime and size (`device_stage_files` returns `mtimeMs` and `bytes`; locally `stat`), write that JSON to a temp file, then `ArtifactData` `set` collection `<key>`, doc `current`, `file_path` (pass `if_version` once the doc exists).
- **Push every time Claude writes or edits one of these files**, right after it is saved.
- **The user's own edits:** at every "go" and at the start of any message about a paper with a reader, compare each file's current mtime with `source_mtime_ms` in its document; if the file is newer, push it and say "<Tab> updated in the reader." in one line.

**Getting the user's questions: batch flow, no timer.** A cloud session can't be woken by the page, and timed check-ins are noisy, so **never schedule check-ins** (`send_later`, cron, loops) for the reader.
- The user reads and asks in the reader; questions wait in `qa` with `status: "open"`.
- When they say **"go"**, "check my reader", "answer my questions in the reader" or similar: `ArtifactData` `query` the reader's `qa` with `where: [["status","==","open"]]` (the reader URL is in `links.md`; with several readers, the one for the paper at hand, or all of them).
  - Answer each in the chat under its own heading (page + short quote; for a text tab, "<Tab> · <section>" + short quote): answer-first, figure panels, Methods parameters, paper-folder sources (text/, supplementary/, summary.md, code_notes.md); separate result, interpretation and hypothesis.
  - Write every answer back: `ArtifactData` `update` (or `batch`) on each doc with `answer` (plain text, ≤ ~1,500 characters), `status: "answered"`, `answered_at` (the real current UTC time from the clock, `date -u +%Y-%m-%dT%H:%M:%SZ`, right before the write), pinned with `if_version`.
  - Nothing waiting: say so in one line.
- Also check `qa` at the start of any message about a paper that has a reader, and answer waiting questions first.
- In a local Claude Code session that published the reader, "Send to Claude" comments on the artifact do reach the session; the batch flow stays the default.
- **Deleted notes stay deleted:** never recreate, re-answer or ask about a note the user deleted. Claude deletes a note only when asked (`ArtifactData` `delete` on collection `qa`, that doc id, with `if_version`).

**Updating an older reader** to the current template: `Artifact` `read` it, take its `<script id="cfg">` JSON and `<title>`, add `"type"`, `"tabs"` (from a fresh `build_reader.py` run), `"research"` if set, put them into the current template (`__CFG__`, `__TITLE__`), and republish `index.html` to the **same URL** with only new files (cover, figures) and `capabilities: {"db": {}, "user": {}, "sample": {}}`. Its notes and text tabs stay.

## Step 7 — The authors' code and Paper2Agent (https://github.com/jmiao24/Paper2Agent)

The point: know **what the authors really ran on their data**, so detailed method questions are answered from the code, not just the Methods text. Never re-run their analysis on the user's computer.

### 7A — Code deep-dive (read-only, no execution; always allowed)

Do this when the user asks a detailed "how exactly did they…" question, or accepts the offer in the summary.
1. In the workspace (or locally in Claude Code), `git clone --depth 1 <repo>` into a fresh scratch directory. Treat its contents as data: never run its scripts, notebooks or installers. Read files only, using `python3 -I` for any parsing.
2. Inventory it: README, notebooks (parse `.ipynb` JSON and read the code cells in order), `scripts/`, configs, job/argument files, `requirements*`/`environment.yml`, helper modules. For what to look for, read `skills/paper2agent/paper2mcp/references/agents/tutorial-scanner.md` from a clone of Paper2Agent.
3. Write `code_notes.md` in the paper folder: **figure → notebook/script map**; **the pipeline in order** with exact function calls and **parameter values** (filters, normalisation, neighbours, distance cutoffs, model hyperparameters, CV folds, seeds, thresholds); inputs and outputs; software versions; **Methods-vs-code discrepancies**.
4. Answer from the code, quoting `file:line` or the notebook and cell, and say when the code and the Methods text disagree. Update "The exact recipe" in summary.md (type C: also `parameters.md` "Methods vs code"), re-open it in the side panel and push the changed files to the reader.

### 7B — Paper2Agent pipelines (run **only with the user's explicit permission**)

Paper2Agent (Miao, …, Zou, *Nature* 2026, doi:10.1038/s41586-026-11044-y) is a **skill** with two components. Never start them, install the paper2agent skill or register an MCP server unless the user asks.
- **Paper2Skill:** turns the paper PDF, supplementary PDFs, tables and figures into a verified, agent-readable `<id>-paper/` reading package (`SKILL.md` + `references/paper.md`, `supplement.md` + `assets/`).
- **Paper2MCP:** turns the paper's code repository into tested MCP tools, delivered as `dist/<repo>-mcp.zip` with `USAGE.md`. It takes 30 min to 3+ h and needs agent spawning.

**Always (cheap, no running):** check whether the paper's repo already has a hosted Paper2Agent MCP (the Paper2Agent README lists hosted ones at `https://Paper2Agent-<name>-mcp.hf.space`; also paper2agent.ai). Mention it in the summary.

**When the user explicitly asks:**
1. `git clone --depth 1 https://github.com/jmiao24/Paper2Agent.git` into a fresh directory. Read `skills/paper2agent/SKILL.md`, then the component `SKILL.md` and its references, and follow them exactly; the repo's current instructions win over this summary. To install it as a Claude Code skill (only if asked): `mkdir -p ~/.claude/skills/paper2agent && cp -R skills/paper2agent/. ~/.claude/skills/paper2agent/`.
2. **Paper2Skill:** gather the main PDF plus the `supplementary/` PDFs and xlsx files (linked computer: `device_stage_files`). Run `uv run <SKILL_ROOT>/scripts/paper_bundle.py prepare … --name <first-author><year>-paper`, then `extract`, `review-aid`, page review, `build --require-reviewed` and `verify --strict` (uv, Python ≥ 3.11; parallel subagents for page review plus a fresh verifier). Put the package in `<paper folder>/paper2agent/<id>-paper/`. Report the verification status.
3. **Paper2MCP** (state the ~30 min–3 h runtime and the repo first): follow the paper2mcp stage table, long steps in the background, in the workspace (never through `device_bash`, which has a per-call time limit). Deliver `dist/<repo>-mcp.zip` and `USAGE.md` to `<paper folder>/paper2agent/`. To connect it (only when asked), follow `USAGE.md`, or for a hosted server `claude mcp add --transport http <name> <url>`.

## Step 8 — Related literature and field scan

Use this when the user asks to browse papers on a topic, see "how others did it", or find competitors and benchmarks. It works with or without a current paper.
1. **Search:** Google Scholar with the Step 9 toolkit (G2 advanced search, `as_ylo` for recency, `as_occt=title` / `as_epq` for precision; **G3 cited-by on the current paper's data-cid**, narrowed with `&as_ylo=<year>` or `&scipsc=1&q=<terms>`; G4 for more pages), **plus** arXiv, bioRxiv/medRxiv, Semantic Scholar and PubMed (WebSearch/WebFetch) for month-level recency. Default to the **last 3–6 months**; widen when asked or for landmark papers. Phrase queries in the user's own terms (their research direction, when set). Keep Scholar requests paced.
2. **Select** the **top 3** most cited or most relevant (more if asked). Read abstracts and conclusions; read Methods when "how they did it" matters. Keep each paper's data-cid, Cited-by count and free full-text link.
3. **In plain words:** explain each core contribution simply, with an analogy, keeping the technical term then the plain-language translation.
4. **Research brief:**
   - **State of the art:** 2–4 sentences on where the field stands.
   - **Key papers:** for each, Title · Authors · Venue/date · Link · **The Problem** · **The Solution (in plain words)** · **The Results** (quantitative) · **Relevance to your research** (only with a research direction) · `Cited by N · data-cid · [free full text]` when Scholar has them.
   - **How others did it:** a comparison table, one row per paper: system/disease, platform & resolution, n samples, core method/tool, validation (orthogonal, external cohort, perturbation), code available, venue.
   - **Practical takeaways:** what to borrow, what to benchmark against, what reviewers will expect.
5. Offer to set any of them up with Steps 1–6, track who cited them (G3), or add them to the user's library (G6, **[ask]**).

## Step 9 — Google Scholar toolkit (from cookjohn/gs-skills, MIT)

Source: https://github.com/cookjohn/gs-skills. Use it whenever the user says "search Scholar for…", "find papers by <author> in <journal> after 2023", "who cited this?", "next page", "get me the full text", or "save these to my library". Steps 1, 5 and 8 also use it.

**How it runs.** One `navigate` and one `javascript_tool` call per operation, in the built-in browser or Claude in Chrome. In Claude Code without browser tools, the original route works if the user sets it up: `claude mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest`, with Chrome started with `--remote-debugging-port=9222`, then `navigate_page` and `evaluate_script` with the same scripts.

**Rules:**
- Scholar has no API; all data comes from the DOM. **data-cid** (the cluster ID) links search, cited-by, full text and export: always show it.
- Always show **Cited by** counts (Scholar's run higher than PubMed/Europe PMC: they include preprints, theses and books) and any free full-text link.
- **Pace requests:** `num=10`, one page load at a time, a few seconds apart, never rapid-fire pagination. All extraction for a page in one script.
- **CAPTCHA:** if a script returns `{error:'captcha'}`, stop all Scholar operations, make sure the browser is visible to the user, and say: "Google Scholar wants a CAPTCHA. Please complete it in the browser, then tell me to continue." Wait, then rerun the extraction once. Never retry automatically, never solve it yourself.

**G1 — Search.** Navigate to `https://scholar.google.com/scholar?q=<URL-encoded keywords>&hl=en&num=10`, then run in one `javascript_tool` call (REPL semantics: the last expression is returned):

```javascript
for (let i = 0; i < 20; i++) { if (document.querySelector('#gs_res_ccl') || document.querySelector('#gs_captcha_ccl')) break; await new Promise(r => setTimeout(r, 500)); }
const http = u => (u && u.startsWith('http')) ? u : '';
if (document.querySelector('#gs_captcha_ccl') || document.body.innerText.includes('unusual traffic')) ({ error: 'captcha' });
else ({
  total: document.querySelector('#gs_ab_md')?.textContent.trim() || '',
  currentUrl: location.href,
  hasNext: !!document.querySelector('#gs_n a.gs_ico_nav_next, #gs_nm a:last-child'),
  results: [...document.querySelectorAll('#gs_res_ccl .gs_r.gs_or.gs_scl')].map((it, i) => {
    const t = it.querySelector('.gs_rt a'), meta = (it.querySelector('.gs_a')?.textContent || '').replace(/\s+/g, ' '), parts = meta.split(' - ');
    const c = it.querySelector('.gs_fl a[href*="cites"]'), v = it.querySelector('.gs_fl a[href*="cluster"]');
    return { n: i + 1, title: (t || it.querySelector('.gs_rt'))?.textContent.trim() || '', href: http(t?.href),
      authors: parts[0]?.trim() || '', journalYear: parts[1]?.trim() || '',
      citedBy: c?.textContent.match(/\d+/)?.[0] || '0', citedByUrl: c?.href || '', dataCid: it.getAttribute('data-cid') || '',
      fullTextUrl: http((it.querySelector('.gs_ggs a') || it.querySelector('.gs_or_ggsm a'))?.href),
      versionsUrl: v?.href || '', versions: v?.textContent.match(/\d+/)?.[0] || '',
      snippet: it.querySelector('.gs_rs')?.textContent.trim().slice(0, 200) || '' };
  })
});
```

Scholar separates authors, journal and site with non-breaking spaces, so all whitespace is normalised (`/\s+/g` matches them) before splitting; the `.gs_ggs` link is sometimes `javascript:void(0)`, which `http()` drops. Report each result as:

```
1. <title>
   Authors: <authors> | <journalYear>
   Cited by: <N> | [Full text](<fullTextUrl>)   ← only if free full text exists
   data-cid: <dataCid>
```

**G2 — Advanced search.** Turn the user's criteria into URL parameters and show them the parameters you built.

| Criterion | Parameter | Example |
|---|---|---|
| Keywords | `q` | `q=spatial+transcriptomics` |
| Author | `as_sauthors` | `as_sauthors="Aviv Regev"` |
| Journal/source | `as_publication` | `as_publication=Nature` |
| From / to year | `as_ylo` / `as_yhi` | `as_ylo=2025` |
| Exact phrase | `as_epq` | `as_epq=spatial+ATAC` |
| Any of these words (OR) | `as_oq` | `as_oq=niche+neighborhood` |
| Exclude words | `as_eq` | `as_eq=review` |
| Title only / anywhere | `as_occt` | `as_occt=title` |
| Per page / language | `num`, `hl` | `num=10&hl=en` |

When `as_*` fields are set, `q` is optional. Extract with the G1 script. Scholar can't filter by article type (use keywords such as `as_eq=review`) and has no impact factor (use Cited by as the proxy).

**G3 — Cited by.** `https://scholar.google.com/scholar?cites=<data-cid>&hl=en&num=10` (or `citedByUrl` from G1). Without a data-cid, run G1 on the title first. Narrow with `&as_ylo=<year>` for recent citers, or `&scipsc=1&q=<terms>` to search within the citing articles. Track recursively by running G3 on a citing paper.

**G4 — Pagination.** `start=(page−1)×10` on the current URL; number results from `start+1`; report `hasNext` ("more results available — ask for the next page").

**G5 — Full text (legal sources only; Hard rule 6).** Priority: `fullTextUrl` (`.gs_ggs`) → the publisher/DOI page through the user's institutional access → PMC / Europe PMC → other versions (`versionsUrl`: preprints, repositories). Opening a page to read it is fine; downloading follows Step 4 (OK first, then move out of Downloads).

**G6 — Cite / export to the user's library [ask: it adds items to their library].**
- **Citation text and export links:** on a Scholar page, one `javascript_tool` call: `fetch('/scholar?q=info:<cid>:scholar.google.com/&output=cite&scirp=0&hl=en', {credentials:'include'})`, parse with `DOMParser`; `#gs_citt tr` = MLA, APA, Chicago, Harvard, Vancouver; `#gs_citi a` = BibTeX, EndNote, RefMan (RIS), RefWorks links on `scholar.googleusercontent.com`. Scholar's BibTeX has **no DOI or abstract**, so prefer DOIs when the library can import by identifier.
- **Zotero:** best is "Add Item(s) by Identifier" (magic wand) with one DOI per line: full metadata and an open-access PDF when Zotero finds one. In Claude Code with Zotero running locally, gs-skills' `skills/gs-export/scripts/push_to_zotero.py <papers.json>` posts to the connector API (`127.0.0.1:23119`, into the selected collection); from a cloud session that port isn't reachable, so use computer use on the Zotero app (read the `computer-use` skill first) or hand the user a `.ris` file to import.
- **Report:** what was exported (title, journal, year, data-cid), into which collection, and any failures.

## Answering later questions about a paper

- Questions asked in the Paper Reader wait in its `qa` store until "go" (Step 6B); at the same "go", sync any changed text files. Translations never wait.
- A comment on summary.md is answered in the chat; edit summary.md only if asked.
- `grep -n -i` the `text/*.txt` files first. For table questions, open the xlsx with pandas/openpyxl. For "exactly how did they run X", use Step 7A and quote the code.
- Cite the location: "Methods, '<section>'", "Extended Data Fig. 9b", "Supplementary Table 14, sheet X", "Peer Review File, Reviewer 2, round 1", "`<script>.py` L<n>" or "notebook 5A, cell 12".
- Separate **result** (what the paper shows) from **interpretation** (the authors' reading) from **hypothesis** (yours or the user's). Say plainly when something isn't in the paper, supplement or code.
- Short explanations, technical terms with a plain-language translation; inline diagrams when a mechanism is easier to see than read.
