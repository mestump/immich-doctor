# Pop's Migrator (the windowed importer)

A point-and-click terminal app that imports your Google Photos Takeout into
Immich, shows progress, lets you **ask an AI helper questions at any time**
(it can read the logs, check the server, and retry things that failed), and
finishes with a written report.

Nothing is deleted without asking you. If the import stops halfway, just run
it again — finished parts are skipped automatically.

---

## Run it (Unraid web terminal, as root)

```
curl -fsSL https://mestump.github.io/immich-doctor/migrate.sh | bash
```

The first run installs its own tools into `/mnt/user/appdata/immich-doctor/`
(about 60 MB). After that you can also start it with:

```
/mnt/user/appdata/immich-doctor/bin/migrate.sh
```

## What you will see

1. **Connect** — the Immich address (leave blank to auto-find it on this box),
   your API key (*Immich → your picture, top right → My Account → API Keys →
   New Key*), and the folder the Takeout zips are in (blank = the usual
   download places). The AI helper's key is already built in; **Settings**
   (`s`) changes it.
2. **Review** — every takeout part it found, with sizes and photo counts.
   Press **Start import** (or *Back* / *Cancel* — nothing has happened yet).
3. **Import** — live progress, the importer's log, and the chat panel at the
   bottom. Ask things like:
   - `what is it doing right now?`
   - `album "Photos from 2019" looks wrong — check it`
   - `something failed, what do I do?`

   If a part fails and **Let AI fix failures** is on, the helper investigates
   by itself, may retry that part once, and explains what happened in the
   chat panel.
4. **Report** — a full summary (per-part results, asset counts, albums, anything
   to look at), also saved to `~/immich-migration-<date>.md`.

## Good to know

- **Re-running is safe.** Already-imported parts are recognised by checksum
  and skipped; *Retry finished parts* forces them again.
- **Cancel** stops after the current file; the rest waits for the next run.
- **Delete downloads** is a separate, double-confirmed step at the very end.
- The helper only ever *reads* things or retries the import; it asks before
  anything destructive and never touches your originals on its own.
- If the AI helper is unreachable, everything else still works; it just stays
  quiet.

## Headless / support

`.../migrate.sh scan /path/to/dir` prints what would be imported (JSON) —
useful when asking for help. Logs live in `<download dir>/.migrate-work/logs/`.

## If the one-liner fails

- `curl: (7) ...` — the box has no internet; download `migrate.sh` and
  `migrate.py` from the repo and run `bash migrate.sh` locally.
- Python/uv trouble — the app only needs *any* Python 3.11+ with the
  `textual` package: `python3 -m pip install textual` then `python3 migrate.py`.
