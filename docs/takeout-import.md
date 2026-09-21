# Getting your Google photos into Immich

Your photos came out of Google as one or more big ZIP files. This page is the
whole process: two clicks in Google, one line typed in the server's terminal.

---

## Step 1 — Ask Google for your photos (on your computer, ~5 min + waiting)

1. Open **https://takeout.google.com** and sign in with your Google account.
2. Press **Deselect all**, then tick only **Google Photos**.
3. Press **All photos included** and leave it as is (original formats is
   fine — the importer sorts it out).
4. Press **Next step** → **Send download links via email** → **Create
   download**.
5. When the email arrives (can be minutes or hours for big libraries), open
   the link on this computer and **download the file(s) into the Downloads
   folder**. If Google splits the download into several files, just put them
   all in the same folder — the importer stitches them back together.

## Step 2 — One command (on the server)

Open Unraid's **Web terminal** (the `>_` icon, top right of the Unraid page)
and paste this single line, then press Enter:

```bash
curl -fsSL https://mestump.github.io/immich-doctor/import.sh | bash
```

It looks for the ZIP files itself, finds Immich on the box, and shows a
progress screen while it works. Big libraries take a while — hours for many
tens of thousands of photos. You can close the browser window; re-run the
same line any time and it continues where it stopped.

The one thing it may ask for is an **API key** (a password-like code that
lets the importer add photos to your Immich account). To get it:

1. Open Immich in your browser.
2. Click your picture (top right) → **My Account** → **App Keys**.
3. **New Key** → name it `import` → press **COPY** → paste it into the
   terminal when asked.

It saves the key, so you only ever do that once.

**Your downloads are never deleted without asking**, even if an import stops
with an error.

## "What does 'unzipping the merged download' mean?"

Chrome sometimes packs the several parts of one big download into a single
wrapper ZIP. The importer notices, unpacks it, and cleans the extra copy up
afterwards. That line is just it saying so.

## "I ran it again and it says 'everything was already imported'"

That means success. It only re-scans files it has not imported yet, so after
a new Google download, put the new ZIP in the Downloads folder and run the
line again — it will import just that one.
