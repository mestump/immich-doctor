# Setting up Tailscale so you can see your photos from anywhere

Two things to set up: your **server** (the box the photos live on) and your
**phone**. About 10 minutes, and it's all clicking in menus.

Tailscale is a free service that connects your own devices together over the
internet. Nothing gets opened on your router, nothing is visible to strangers,
and there is no monthly fee.

Your server's software (Unraid) has Tailscale built in as an add-on, so there's
nothing to download by hand.

---

## Step 1 — Make your free account (on your computer)

1. Go to **https://login.tailscale.com/start**
2. Sign in with whatever is easiest — a Google account, Apple ID, or email.
   Use the same one you'll use on your phone later.
3. It will talk about creating a "network". That's fine — this network is just
   yours. Only devices where you sign in can see it.

---

## Step 2 — Install the Tailscale add-on on the server

1. Open the Unraid web page for the server, using the address you normally use.
2. Click **Apps** along the top.
3. Type **Tailscale** in the search box and hit search.
4. Click the **Tailscale** result (by Derek Kaser) and confirm.
5. Wait for the progress window to finish, then click **Done**.

You should now have a **Tailscale** entry in the **Settings** menu at the top of
the page. If you don't see it, click **Settings** and look for it there —
sometimes the page needs a refresh (press F5).

---

## Step 3 — Turn it on and sign in

1. Click **Settings**, then **Tailscale**.
2. On the **Settings** tab, change **Enable Tailscale** to **Yes**.
3. Scroll down and press **Apply**.
4. Click the **Status** tab (top of the Tailscale page).

It will say the server still needs to be logged in, with a **Login** button
next to it.

5. Press **Login**. A link appears next to the button.
6. Click that link. A Tailscale page opens in your browser.
7. Sign in with the account from Step 1 and approve/add the device.

Go back and press **Refresh** on the Status tab. After a few seconds the page
fills in with the other devices on your network, and near the top you'll see
your server's Tailscale address — it looks like:

```
100.xx.yy.zz
```

**Write that down.** It always starts with `100.`

---

## Step 4 — Tailscale on your phone

1. Open the App Store (iPhone) or Play Store (Android) and get **Tailscale**.
2. Open it and sign in with the **same account** as Step 1.
3. Flip **Use Tailscale** to **ON**. It asks permission to add a VPN
   configuration — tap Allow/Connect. That's normal, even though it says VPN.

You should see your server listed by name with a green dot. If you do, this part
worked.

---

## Step 5 — Point the Immich app at your server

1. Open the **Immich** app on your phone.
2. It asks for a **server endpoint**. Type the address from Step 3, with the
   port and `/api` on the end:

   ```
   http://100.xx.yy.zz:2283/api
   ```

   The `/api` is not optional — leave it off and Immich reports a connection
   error.
3. Tap **Connect** / **Next**, then create your account (name, an email, a
   password). You own this photo library; nothing goes to anyone else.
4. Turn on photo backup when offered — Settings → Backup.

---

## What to expect afterwards

- **At home** the app works whether Tailscale is on or off.
- **Away from home** (cell data, a hotel, anywhere) the Tailscale switch on your
  phone must be **ON**. If photos suddenly stop loading, that switch is almost
  always why — check it first.
- The `100.` address stays the same in practice. If it ever changes, the
  Tailscale app on your phone shows the server's current address — tap the
  server name and it's listed there.
- If the server reboots or loses power, Tailscale reconnects by itself. You don't
  have to do anything.

---

## If something goes wrong

| What you see | What it means |
|---|---|
| No Tailscale result in **Apps** | Your server can't reach the internet, or the Apps list needs updating. Check the network cable, then retry. |
| Installed, but no Tailscale under **Settings** | Refresh the page (F5), or reboot the server and look again. |
| Status tab still says it needs a login after Step 3 | Press **Refresh** on the Status tab, wait 30 seconds, and try the link again. |
| Green dot on my phone, but Immich can't connect | The Immich app is a separate step — go back to Step 5 and check the `/api` at the end of the address. |
| Immich worked, now it doesn't, I'm out of the house | The Tailscale switch on your phone is off. Turn it on. |
| Immich worked at home, Tailscale is on, still nothing | The server is probably off or restarting. Check it has power. |
| Android only: server shows a green dot but Immich alone can't connect | In the Tailscale app, check **Select apps** / per-app mode isn't excluding Immich. Set it to route all apps. |

Anything else: photograph the whole screen — all of it, including any red text —
and send it to me. That's more use than describing it.

---

## Note for Mike

- The add-on is **`unraid/unraid-tailscale`** (author Derek Kaser, forum topic
  136889), surfaced in Settings by the `Settings → Tailscale` stub page Unraid
  7.3 added. It installs the Tailscale **binary** natively — no container, no
  `--net=host` gymnastics, so Immich's published 2283 is reachable on the host's
  100.x address with nothing else configured.
- Login is the interactive browser flow (`needs_login` → Login button →
  `getAuthURL()`), so **no auth key** is needed. `docs/tailscale.sh` and its
  auth-key dance are only the fallback if Apps can't install the plugin.
- If he ever does run `tailscale.sh` first, **remove the `tailscale` container
  before installing the plugin** — a native install and a container both want the
  tailnet, and two of them will fight.
- Unraid's Immich docs steer people to the CA template + Postgres 14 + Compose
  Manager. That's the path that produced the `pgvecto-rs` dead end; stay on
  `install.sh`.
