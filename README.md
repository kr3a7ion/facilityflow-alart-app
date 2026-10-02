# FacilityFlow Alerts — the Android app

Rings a technician's phone when a job is assigned to them, **with the screen off and the
app closed**, on a property with no internet.

## Why this exists

The website cannot do it, and the reason is worth knowing so nobody tries to make it.

A web page can only raise a notification from a background tab through a **service
worker**, and browsers only register one on a *secure context* — HTTPS. The host serves
`http://192.168.1.50:4700`, because it is an offline LAN with no certificate authority to
get a certificate from. And even on HTTPS, waking a phone whose browser is **closed**
needs a push service on the internet (Google's FCM). There is no internet. That is the
point of the product.

A native app has neither problem. It holds a socket to the host on the property wifi from
a foreground service and raises an alarm when something comes down it. No push service, no
certificate, no internet.

**It only works on the property wifi.** Out of range, the phone is deaf. That is inherent,
not a defect.

## What it does

- Holds `GET /api/events` open — the same stream the website uses.
- Rings for three things, most urgent first:
  1. an **emergency alert** this person has not acknowledged — **I have seen this**;
  2. **somebody ringing them** (the bell / *Ring* on the website) — **I am here**;
  3. a **job assigned to them** and not yet accepted — **Accept**.

  Every nudge on the stream re-asks the host for all three (`/api/alerts/emergency`,
  `/api/me/rings`, `/api/me/outstanding`), so a reconnect settles everything at once.
- Rings on the **alarm audio stream**, so it is heard through a phone set to silent, and
  vibrates.
- Shows a heads-up notification whose button works from the lock screen; emergencies and
  rings wake the screen.
- Keeps ringing until the job is accepted, reassigned or cancelled — or until its response
  deadline passes, at which point the host escalates to a human and the phone goes quiet.
- Reports its connection to the host continuously, so a supervisor can see a phone that
  has stopped listening.

Accepting from the notification calls the same endpoint the website calls. The host emits
on its event bus, and the ringing stops on every device at once — this phone, the duty
tablet, the supervisor's browser. One source of truth.

## Building it

```bash
flutter pub get
flutter build apk --release
```

The result is `build/app/outputs/flutter-apk/app-release.apk`.

Copy it onto the host PC as **`data/app.apk`** — beside `facilityflow.db`. The server then
serves it at `/app.apk`, so a phone on the office wifi can install it by scanning a code
off the notice board. It is backed up with everything else, so restoring the database onto
a new PC restores the installer too.

> This app was written against the running server and every endpoint and field name was
> checked against live responses, but it has **not been compiled or run on a device** —
> that needs a Flutter toolchain and an Android handset. Expect to fix small things on the
> first build; the shape is right.

## Installing on a phone

1. On the phone's browser, open the host address and sign in.
2. **More → Ring my phone** (or the bell beside your name on a computer).
3. Install the APK — the Host PC tab has a QR code for it. Android will ask you to allow
   installing from this source; that is normal for a sideloaded app.
4. Open **FacilityFlow Alerts**, scan the pairing square.
5. Allow notifications when asked.
6. **Turn battery optimisation off for it when asked.** This is not optional — see below.

The pairing code is generated in a browser where the person is already signed in, so the
app never asks for a password and never stores one. Losing a phone costs one **Unpair** on
the website, not a password change.

## The thing that will actually go wrong

**Phone manufacturers kill background apps.** Tecno, Infinix, itel, Xiaomi, Oppo, Vivo and
Huawei all ship their own battery managers that shut down foreground services regardless of
the permissions Android has granted — and on a Nigerian property those are most of the
handsets. Disabling Android's own battery optimisation is necessary and **not sufficient**.

Per manufacturer, after installing:

| Phone | Where to go |
|---|---|
| **Tecno / Infinix / itel** (HiOS, XOS) | Settings → Battery → **Background freeze** / App freeze → set FacilityFlow Alerts to *No freeze*. Also Phone Master → App Manager → **Auto-start** → allow. |
| **Xiaomi / Redmi** (MIUI) | Settings → Apps → FacilityFlow Alerts → **Autostart** on, and **Battery saver** → *No restrictions*. Then lock the app in Recents (pull down on the card). |
| **Oppo / Realme** (ColorOS) | Settings → Battery → **App battery management** → *Allow background running*, and Startup Manager → allow. |
| **Vivo** (FuntouchOS) | Settings → Battery → **High background power consumption** → allow, and Autostart → on. |
| **Samsung** (One UI) | Settings → Battery → Background usage limits → **Never sleeping apps** → add it. |
| **Stock Android / Pixel / Nokia** | Battery optimisation off is enough. |

Because none of this can be guaranteed, the host watches instead: a paired phone that stops
holding its connection shows on **Admin → Users → Who can hear an alert** as *"Phone app not
running"*. That turns a silent failure into one a supervisor sees before an outage does.

## iPhones

Not supported, and cannot be. iOS kills background sockets, and waking a closed app needs
Apple's push service, which needs internet. iPhone users stay on the website — which alerts
them properly while it is open — and the duty tablet covers the shift.

## Permissions, and why each one is needed

| Permission | Without it |
|---|---|
| `INTERNET`, `ACCESS_NETWORK_STATE` | Cannot reach the host at all |
| `POST_NOTIFICATIONS` | No foreground service notification, so no foreground service |
| `FOREGROUND_SERVICE`, `..._DATA_SYNC` | The service cannot start on Android 14+ |
| `WAKE_LOCK` | CPU sleeps before the alarm is raised |
| `RECEIVE_BOOT_COMPLETED` | Silently stops listening after a restart |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Doze kills it within hours |
| `USE_FULL_SCREEN_INTENT` | A P1 waits to be pulled down rather than waking the screen |
| `VIBRATE` | Missed in a pocket next to a running generator |

**`networkSecurityConfig`** is the setting people lose a day to. Android 9+ blocks cleartext
HTTP; without `res/xml/network_security_config.xml` every request fails in a way that looks
exactly like the host being switched off. It permits cleartext generally: Android's
`<domain>` matches host names, not IP ranges, so it cannot be scoped to the private
ranges. The app only ever talks to the address it was paired with.

## Checking it works

1. Pair a phone. **Admin → Users → Who can hear an alert** should show *"Phone will ring"*.
2. Lock the phone, put it in a pocket.
3. Assign that person a P1 from another device. It should ring within a second or two,
   through silent mode.
4. Press **Accept** on the lock screen. The ringing stops, and the job shows as accepted on
   the supervisor's board.
5. Force-stop the app. The supervisor's screen should change to *"Phone app not running"*
   within a minute.
6. Restart the phone without opening the app. It should reappear as connected.

Step 5 is the one worth doing deliberately. The point of this app is not that it never
fails — it is that when it fails, somebody knows.
