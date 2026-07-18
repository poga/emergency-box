# Emergency Chat — print this page

*Print in large type and post it near the router.*

---

# WIFI: ______________________

## 1. Join wifi `___________________`

## 2. A welcome screen appears — follow it

## 3. Chat at http://chat.lan

---

Optional: generate a scannable QR code for the wifi network (needs
`qrencode`, `brew install qrencode`):

```bash
qrencode -o sign-qr.png 'WIFI:T:WPA;S:<ssid>;P:<password>;;'
```

Print `sign-qr.png` alongside this page so phones can join by camera
instead of typing the password.
