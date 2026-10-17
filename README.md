# Glucose Monitor (iPhone and Android)

> **Free server for Loop and Trio users:** see [`cloudflare/README.md`](cloudflare/README.md),
> a one-click, free Nightscout-compatible server (copy, relay or standalone) on Cloudflare.
> For a PHP/MySQL host (cPanel), see [`server/README.md`](server/README.md).

A night-time glucose monitor that reads your Nightscout site: big readings, red / yellow / green zones per time range, soft-music alarms with volume that rises or falls, your own snooze buttons, a fully adjustable night view, a before-sleep checklist and reports.

You do not need a Mac. GitHub builds both apps in the cloud, the same way as an AAPS browser build:

| Workflow | What it makes | Where it goes |
|---|---|---|
| **Build Android app** | `app-release.apk` | Download from the GitHub run, install on the phone |
| **Build iPhone app (TestFlight)** | signed iPhone app | Uploaded to App Store Connect › TestFlight |

---

## What is in this folder

| Path | What it is |
|---|---|
| `lib/` | The app (Flutter / Dart) |
| `lib/state/settings.dart` | Every setting and its default value |
| `lib/state/app_state.dart` | Reading Nightscout, zone and alarm logic, snooze |
| `lib/ui/` | Screens: Live, Treat, Reports, Alarms, alarm screen, night view, checklist |
| `lib/ui/settings/` | Settings screens: zones, sounds & snooze, night layout, and the rest |
| `assets/sounds/` | 10 alarm sounds (6 soft, 4 alarm), made by `tools/make_sounds.py`, free to use |
| `assets/icon/` | App icon |
| `.github/workflows/` | The two cloud builds |
| `fastlane/` | iPhone signing and TestFlight upload |
| `scripts/patch_platforms.py` | Sets the app name, app ID and permissions during the build |

The `android/` and `ios/` folders are not stored here: each build creates them fresh.

---

## Step 1 — Put the code on GitHub

1. On github.com, create a new repository named `glucose-monitor` (private is fine).
2. Create a second **private**, **empty** repository named exactly `Match-Secrets`. It will hold your iPhone signing certificate, encrypted.
3. Upload this folder to `glucose-monitor`. Either:
   - **In the browser:** open the repository › *Add file* › *Upload files*, and drag in **everything inside** the unzipped `glucose_monitor` folder, including the `.github` folder. Commit to `main`.
   - **Or with git:**
     ```bash
     cd glucose_monitor
     git init -b main
     git add .
     git commit -m "Glucose Monitor app"
     git remote add origin https://github.com/sircsaba/glucose-monitor.git
     git push -u origin main
     ```

Uploading to `main` starts the Android build by itself.

## Step 2 — Get the Android app

1. Repository › **Actions** › **Build Android app** › the latest run (green tick, about 8–10 minutes).
2. Under **Artifacts**, download `glucose-monitor-android` (a zip), unzip it: `app-release.apk`.
3. Copy the APK to the phone and open it. Allow "install unknown apps" for your file manager when Android asks.

## Step 3 — Set up the iPhone build (once)

**Apple Developer site** (developer.apple.com › Account):

1. **Team ID:** *Membership details* › Team ID (10 characters).
2. **App ID:** *Certificates, IDs & Profiles* › *Identifiers* › **+** › *App IDs* › *App* › Bundle ID **Explicit**: `com.monitorglucose.app` › Continue › Register.

**App Store Connect** (appstoreconnect.apple.com):

3. **API key:** *Users and Access* › *Integrations* › *App Store Connect API* › *Team Keys* › **+**. Name it `GitHub`, access **Admin**. Download the `.p8` file (only possible once) and note the **Key ID** and the **Issuer ID** shown above the list.
4. **App record:** *Apps* › **+** › *New App* › iOS, a name (it must be unique on the App Store, for example "Glucose Night Monitor"), language English, Bundle ID `com.monitorglucose.app`, SKU `glucosemonitor`, Full access.

**GitHub:**

5. **Token for Match-Secrets:** your picture › *Settings* › *Developer settings* › *Personal access tokens* › *Tokens (classic)* › *Generate new token (classic)*. Tick **repo** and **workflow**, expiration "No expiration", generate and copy it.
6. In `glucose-monitor` › *Settings* › *Secrets and variables* › *Actions* › **New repository secret**, add these six:

| Secret name | Value |
|---|---|
| `TEAMID` | Team ID from 1 |
| `FASTLANE_KEY_ID` | Key ID from 3 |
| `FASTLANE_ISSUER_ID` | Issuer ID from 3 |
| `FASTLANE_KEY` | The whole text of the `.p8` file, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |
| `GH_PAT` | The token from 5 |
| `MATCH_PASSWORD` | A password you make up (it encrypts Match-Secrets; keep it) |

Optional, same page, **Variables** tab: `APP_NAME` (name under the icon, default "Glucose Monitor") and `BUNDLE_ID` (only if you registered a different one).

## Step 4 — Build the iPhone app

1. Repository › **Actions** › **Build iPhone app (TestFlight)** › **Run workflow** › Run. About 20–30 minutes.
   The first run creates your distribution certificate and stores it in `Match-Secrets`.
2. App Store Connect › your app › **TestFlight**. The build appears after Apple processes it (10–30 minutes). Answer the export-compliance question if asked (the app uses no special encryption).
3. TestFlight › *Internal Testing* › **+** › add yourself (and your wife) as testers.
4. On the iPhone, install **TestFlight** from the App Store, accept the invite, install the app.

Run the workflow again whenever you change the code; each run gets a higher build number.

---

## Using the app

1. First screen: your Nightscout address, an access token (Nightscout › Admin tools › Subjects: `readable`, or `careportal` to log treatments) or the API secret, and the units.
2. **Settings › BG zones & time ranges:** your red / yellow / green limits for Night, Day, School… with days of the week.
3. **Settings › Alarm sounds & snooze:** a sound for each alarm (red low, yellow low, yellow high, red high, other), volume that stays the same / gets louder / gets softer, your snooze buttons, custom snooze, red-zone snooze limit.
4. **Settings › Night view layout:** size, colour (by zone or fixed), alignment, order and spacing of each line.
5. At bedtime: **Before-sleep checklist**, then **Start night view**, phone on the charger.

### Important limits of this first version

- **Alarms sound only while the app is open.** Leave it open in night view with the phone charging (the screen stays awake). iPhones stop apps that are in the background; making alarms work with the app closed needs a push-notification server, which is a next step.
- **iPhone silent switch:** the app plays its alarms even with the ringer switch on silent, but the iPhone volume buttons still set the loudness. Before the store version, ask Apple for the *Critical Alerts* permission so alarms can override Do Not Disturb.
- Watch app, widgets, lock-screen glucose, choosing your own sound file, and checking the other carer's phone are not in this version.
- English only for now.
- For information only. Always check with a meter before treating.

## Glucose Monitor Plus (Loop remote control, build it yourself)

Glucose Monitor Plus is the same app with **Loop remote commands**: start or
cancel an override, send carbs, send a bolus. It is not in the stores: you
build it on GitHub with your own accounts, and it installs next to the regular
app (its own name and app ID, `<your bundle ID>.plus`).

**No Apple keys in the app.** Commands go through the site the app shows:

- **Nightscout** uses its own `LOOP_APNS_KEY`, `LOOP_APNS_KEY_ID` and
  `LOOP_DEVELOPER_TEAM_ID` settings (the same as for Loop Caregiver / Careportal).
- **Your own Glucose Monitor server (WHC)** uses `loop_apns_key_file`,
  `loop_apns_key_id`, `loop_team_id` in `config.php`, or finds the key of the
  Loop heartbeat installed next to it.

Loop's device token and bundle ID come from the profile Loop uploads, its
override presets too. Carbs and boluses need Loop's one-time password: in the
Plus app, Treat › Loop remote control › One-time password › take a photo (or a
screenshot) of the QR code in Loop › Settings › Services › Nightscout ›
One-Time Password. It is kept in the phone's secure storage. Sending needs the
site's API secret (asked once, can be remembered on the phone).

**Build it:**

- Android: Actions › **Build Glucose Monitor Plus (Android)** › Run workflow,
  then install the APK from the run's Artifacts.
- iPhone: first create the app record once: App Store Connect › Apps › + ›
  New App, name e.g. "Glucose Monitor Plus <your name>", Bundle ID
  `<your bundle ID>.plus` (the first Plus build creates this ID; run it once,
  let it fail at the upload, then create the app record and run it again).
  Then Actions › **Build Glucose Monitor Plus (iPhone, TestFlight)** › Run
  workflow. Same secrets as the regular iPhone build.
- Optional repository variables: `PLUS_APP_NAME`, `PLUS_BUNDLE_ID`.

In Loop, remote commands must be on: Settings › Services › Nightscout ›
Remote Commands. Loop checks every command against its own limits.

## Publishing on the stores later

- **App Store:** in App Store Connect add screenshots, a description, a privacy-policy web page (it can live on monitorglucose.ca), category Medical, and submit a TestFlight build for review.
- **Google Play:** needs a Google Play developer account and a signing key (the APK here is signed with a test key, fine for your own phones). Ask and I will add a Play Store build.

## Changing the sounds

Edit `tools/make_sounds.py` and run `python3 tools/make_sounds.py` (needs Python with numpy and scipy), or put your own `.wav` files in `assets/sounds/` with the same file names.
