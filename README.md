# Puzzle Palace online packs

Hosts the online puzzle packs for the Puzzle Palace VRChat world. They show up in
the world's pack list next to the built-in packs. GitHub Pages is on VRChat's image
and string allowlists, so every player can load them without "Allow Untrusted URLs".

Site: https://anyreality-eng.github.io/puzzlepalace/

## Add pictures to a pack

1. On github.com open `incoming`, then **Add file → Upload files**. To put pictures
   in a pack, put them in a folder named after it. On the upload page, drag in the
   folder itself, or create a file path like `incoming/Nature/My Picture.jpg`.
   Pictures directly in `incoming/` go to the **Extras** pack.
2. File names become titles: `Sunset Harbor - by Hayzl.jpg` gives "Sunset Harbor",
   credited "by Hayzl".
3. Commit. The **Publish puzzle gallery** action resizes each picture (max 2048×2048),
   assigns it the next slot, rebuilds that pack's thumbnail sheets and `catalog.json`,
   and republishes. That takes about 2 minutes, plus up to 10 minutes of caching.

## Add a new pack / set unlocks

Edit `packs.json` and add the pack **at the end**, because the world refers to packs
by position:

```json
{ "name": "Dogs", "unlock": 30 }
```

`unlock` is the number of completed puzzles a player needs (0 = free). Players
who bought the "unlock all" product get every pack.

## Remove a picture

Actions → **Publish puzzle gallery** → Run workflow → slot number. The slot is
blanked and dropped from its pack. Slot numbers are never reused.

## Layout

| Path | What |
| --- | --- |
| `images/0001.jpg` … | one picture per slot (the world knows slots 1–2048) |
| `thumbs/page_000.jpg` … | 4×2 thumbnail sheets (384×256 cells); each pack owns whole sheets |
| `catalog.json` | `{"v":2,"packs":[{"n":name,"u":unlock,"s":[slots],"p":[sheets]}],"items":[{"t":title,"a":author}]}` |
| `packs.json` | pack order and unlock requirements (you edit this) |
| `incoming/` | drop zone; emptied by the action |
| `tools/process_incoming.ps1` | the processor (also runs locally in Windows PowerShell) |
