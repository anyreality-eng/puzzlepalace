# Puzzle Palace community gallery

Hosts the pictures in the **COMMUNITY** tab of the Puzzle Palace VRChat world.
GitHub Pages is on VRChat's image and string allowlists, so every player can
load these without turning on "Allow Untrusted URLs".

Site: https://anyreality-eng.github.io/puzzlepalace/

## Add a puzzle

1. On github.com open this repo, go into the `incoming` folder, then
   **Add file → Upload files**, and drop in one or more pictures (JPG/PNG).
2. Name each file like `Sunset Harbor - by Hayzl.jpg`. That becomes the
   title "Sunset Harbor" and the credit "by Hayzl". The " - by ..." part is optional.
3. Commit. The **Publish puzzle gallery** action (Actions tab) resizes the picture to
   fit 2048×2048, gives it the next slot number, rebuilds the thumbnails and
   `catalog.json`, and republishes the site. It takes about 2 minutes. After that,
   GitHub's cache can take up to 10 more minutes before the world sees it.

Pictures must be at least 400×300 and safe for all ages. This is a public VRChat world.

## Remove a puzzle

Actions → **Publish puzzle gallery** → Run workflow → enter the slot number.
The slot is replaced with a blank card and marked "(removed)". Slots are never
reused because the world has a fixed URL for each slot.

## Layout

| Path | What |
| --- | --- |
| `images/0001.jpg` … | puzzle pictures, one per slot (the world knows slots 1–1024) |
| `thumbs/page_000.jpg` … | 4×2 thumbnail sheets, 8 slots each (384×256 cells), so the world loads one image per page (VRChat allows one image load every 5 seconds) |
| `catalog.json` | `{"v":1,"count":N,"items":[{"t":"title","a":"author"}, …]}` in slot order |
| `incoming/` | drop zone; emptied by the action |
| `tools/process_incoming.ps1` | the processor (runs on Windows PowerShell locally too) |

## One-time setup

Settings → Pages → **Build and deployment → Source: GitHub Actions**.
