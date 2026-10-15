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
  3. a **job assigned to them** and not yet accepted — **Accept**. A team lead who can
     hand work out is also rung for a job given to their team with nobody's name on it,
     shown as *WO-1042 · Civil team* until it is assigned on the website or they accept it.

  Every nudge on the stream re-asks the host for all three (`/api/alerts/emergency`,
  `/api/me/rings`, `/api/me/outstanding`), so a reconnect settles everything at once.
- Rings on the **alarm audio stream**, so it is heard through a phone set to silent, and
  vibrates.
- Shows a heads-up notification whose button works from the lock screen; emergencies and
  rings wake the screen.
- Keeps ringing until the job is accepted, reassigned or cancelled — or until the host's
  `ring_until` passes: a full response time from when the job was handed to this person,
  never earlier than its response deadline. A job assigned late, reassigned, or sent back
  for rework still rings; past the window the host has escalated to a human and the phone
  goes quiet.
- Reports its connection to the host continuously, so a supervisor can see a phone that
  has stopped listening.
- Shows the person's other **notices** — the bell on the website: an escalation, mains
  failure, a job taken away or sent back — as ordinary notifications, as loud as the host
  says each one is (`urgent`, normal, `quiet`). It only reads them (`GET
  /api/notifications`); marking them read stays on the website. A newly paired phone
  starts after the newest notice rather than replaying the bell. Needs a host that lets
  phones read notices; an older one refuses and the phone simply doesn't ask again.

Accepting from the notification calls the same endpoint the website calls. The host emits
on its event bus, and the ringing stops on every device at once — this phone, the duty
tablet, the supervisor's browser. One source of truth.

## Building it

**Without installing anything:** every push to `main` and every pull request is built on
GitHub by `.github/workflows/build-apk.yml`. Open the run on the repository's **Actions**
tab, download the `facilityflow-alerts-<version>-<build>` artifact under **Artifacts**, and
unzip it to get `app-release.apk`. The **Run workflow** button builds `main` on demand. Each
build is numbered from the run that made it, so every APK is newer than the last, and the
app reports that version to the host when it pairs.

### Signing — do this once, before handing out the first APK

Android installs an update only if it is signed with the same key as the app already on the
phone. Without a key of its own the workflow signs with a throwaway one that changes on
every run, so every new APK means uninstalling first — which throws away the pairing — and
the run says so with a **Not release-signed** warning.

Make the key once, on any machine with a JDK, and keep it:

```bash
keytool -genkeypair -v -keystore facilityflow-release.jks -keyalg RSA -keysize 4096 \
  -validity 10000 -alias facilityflow
base64 -w0 facilityflow-release.jks > facilityflow-release.jks.b64   # macOS: base64 -i … -o …
```

Then add four secrets under the repository's **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the contents of `facilityflow-release.jks.b64` |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password you chose |
| `ANDROID_KEY_ALIAS` | `facilityflow` |
| `ANDROID_KEY_PASSWORD` | the key password (the same as the keystore's unless you set another) |

**Keep `facilityflow-release.jks` and its passwords somewhere safe and off this repository**
— a password manager, and a copy on a drive in the office. Lose them and the next APK cannot
update any phone: every one has to uninstall and pair again.

Phones that already have a build signed with a throwaway key need that one uninstall, once,
to move to the real key. Unpair the old phone on the website afterwards so it stops showing
as "not running".

**On your own machine** (Flutter 3.44 or newer):

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
> checked against live responses. It is built, analysed and tested on GitHub on every push,
> but it has **not yet been run on a handset** — the checklist under *Checking it works* is
> the first real test.

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
| `FOREGROUND_SERVICE`, `..._SPECIAL_USE` | The service cannot start on Android 14+. Not `dataSync`: Android 15 stops that type after six hours a day and will not start it at boot |
| `WAKE_LOCK` | CPU sleeps before the alarm is raised |
| `RECEIVE_BOOT_COMPLETED` | Silently stops listening after a restart |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Doze kills it within hours |
| `USE_FULL_SCREEN_INTENT` | A P1 waits to be pulled down rather than waking the screen |
| `SCHEDULE_EXACT_ALARM` | After the system kills the service, the restart can be pushed out by minutes. Off by default on Android 14+; the app opens the setting once |
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
