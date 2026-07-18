# Emergency Chat — print this page

*Print in large type and post it near the router.*

---

## 1. Join wifi `___________________`

## 2. Go to **chat.local/join** and pick a name

## 3. Chat at **chat.local** — works even when the internet is down

---

**Can't reach chat.local?** (some older Android phones can't) — use
this instead:

## http://______________/join

Fill in the Mac's IP address (see README section 3).

Optional: generate a scannable QR code for that fallback link (needs
`qrencode`, `brew install qrencode`):

```bash
qrencode -o sign-qr.png 'http://<mac-ip>/join'
```

Print `sign-qr.png` alongside this page so phones can open the join
page by camera instead of typing the address.
