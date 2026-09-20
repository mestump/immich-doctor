# Setting up Tailscale so you can see your photos from anywhere

Two things to set up: your **server** (the black box under the TV / in the office)
and your **phone**. About 10 minutes.

Tailscale is a free app that connects your own devices together over the internet.
Nothing gets opened on your router, nothing is visible to strangers, and there is
no monthly fee.

---

## Step 1 — Make your free account (do this on your computer)

1. Go to **https://login.tailscale.com/start**
2. Sign in with whatever is easiest — a Google account, Apple ID, or email.
   Use the same one you'll use on your phone later.
3. It will say something about creating a "network". That's fine — this network is
   just yours. Only devices you sign in on can see it.

---

## Step 2 — Get a one-time key

Still on your computer:

1. Go to **https://login.tailscale.com/admin/settings/keys**
2. Click **Generate auth key** (top right).
3. Change nothing — the defaults are fine.
4. Click **Generate key** and copy the long string. It starts with:

   ```
   tskey-auth-
   ```

The key only works once. If you close the page too soon, just make another one.

---

## Step 3 — Put Tailscale on the server

1. Open the Unraid web page for the server, using the address you normally use
   (it's the one in your browser bookmark — it looks like `http://192.168.1.x`).
2. Click **Docker** across the top.
3. Look at the top right of the page for the little **`>_`** terminal icon and
   click it. A black window opens.
4. Paste this, **replacing the part after the two dashes with your key**:

   ```
   curl -fsSL https://mestump.github.io/immich-doctor/tailscale.sh | bash -s -- tskey-auth-PASTE-YOUR-KEY-HERE
   ```

5. Press Enter. Wait about 30 seconds.

You should get a green line that says the box is on the network, plus a URL that
looks like:

```
http://100.xx.yy.zz:2283/api
```

**Write that address down** — you'll need it on your phone. It always starts with
`100.`

If it fails, it prints a reason and a link you can read. Photograph the screen and
send it to me.

---

## Step 4 — Put Tailscale on your phone

1. Open the App Store (iPhone) or Play Store (Android) and get **Tailscale**.
2. Open it and sign in with the **same account** as Step 1.
3. Flip the **Use Tailscale** switch **ON**. It will ask permission to add a VPN
   configuration — tap Allow/Connect. That's normal, even though it says VPN.

You should see your server listed by name with a green dot. If you do, this part
worked.

---

## Step 5 — Point the Immich app at your server

1. Open the **Immich** app on your phone.
2. It asks for a **server endpoint**. Type the address from Step 3, including
   the `/api` ending:

   ```
   http://100.xx.yy.zz:2283/api
   ```

   The `/api` is not optional — without it Immich reports a connection error.
3. Tap **Connect** / **Next**, then create your account (your name, an email, a
   password). You're the owner of this photo library; nothing goes to anyone else.
4. Turn on photo backup when it offers — Settings → Backup.

---

## What to expect afterwards

- **At home** the app works whether Tailscale is on or off.
- **Away from home** (cell data, a hotel, wherever) the Tailscale switch on your
  phone must be **ON**. If photos suddenly stop loading, that switch is almost
  always the reason — it is the first thing to check.
- The `100.` address stays the same in practice. If it ever does change, the
  Tailscale app on your phone shows the server's current address — tap the server
  name in the app and it's listed there.
- If the server is unplugged or rebooted, Tailscale comes back by itself. You
  don't have to do anything.

---

## Two housekeeping things

1. **Delete the auth key** after Step 3 works — back on the keys page, click the
   red X next to it. It's already been used, but this is tidier and safer.
2. **Turn on auto-update for the Immich app** on your phone so you don't have to
   think about it.

---

## If something is wrong

| What you see | What it means |
|---|---|
| "no auth key was given" | You pasted the line without your key at the end. Redo Step 3 with the key. |
| Nothing appears after a minute | The server can't reach the internet. Check it's on Wi-Fi/Ethernet, then run Step 3 again. |
| Green "on the network" line, but the phone app can't connect | The Tailscale switch on your phone is off. Turn it on. |
| Phone app says "server unreachable", Tailscale is on | The server is probably off or restarting. Check it has power. |
| Android only: Tailscale is on and the server shows a green dot, but Immich alone can't connect | In the Tailscale app, open the menu and check **Select apps** / per-app mode is not excluding Immich. Set it to route all apps. |
| `/api` mistake — "Immich server is not responding" | You left off `/api` at the end of the address. |

Anything else: photograph the whole screen (all of it, including any red text) and
send it to me. That's more useful than describing it.
