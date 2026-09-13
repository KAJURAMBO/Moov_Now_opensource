# Play Store listing — Moov Now

Copy-paste text for the Google Play Console. Package name: `com.rahma.moovnow`.

---

## App name (30 char max)

```
Moov Now Tracker
```
(16 characters)

> **Trademark note.** "Moov Now" is Moov Inc.'s mark. The device is discontinued and the official
> app was removed from both stores, so an unofficial companion is a normal thing to publish — but
> the listing must not imply you are Moov. Keep the description saying "unofficial" (it does,
> below), and do not use Moov's logo in the store icon. If Play ever flags it, the fallback name
> is "Moov Now Tracker (unofficial)" or "Puck Tracker".

---

## Short description (80 char max)

```
Offline tracker for the discontinued Moov Now. No account, no cloud, no internet.
```
(79 characters)

---

## Full description (4000 char max)

```
Moov Now Tracker is an unofficial, local-only companion app for the Moov Now fitness tracker.

The Moov Now is a 9-axis motion tracker that Moov Inc. discontinued around 2022, and the
official Moov Coach app was pulled from the Play Store and App Store. The hardware still works
perfectly — it just had nothing left to talk to. This app fixes that.

HOW IT WORKS

The app connects to your Moov Now over Bluetooth and reads its motion sensor directly. Your
phone is the whole system: there is no server, no account, and nothing is uploaded anywhere.
The app does not even request internet permission.

FEATURES

• Live motion view — pitch, roll and impact force as you move
• Daily tracking — steps, active minutes, calories and distance
• Workout sessions — run, cycle, swim, box or walk, with a timer and session summary
• History — every session saved with its date and time
• Fully offline — works in a basement, on a plane, anywhere
• No account, no sign-up, no ads, no tracking

PRIVACY

Everything stays on your device. The app collects no personal data, has no analytics, no
advertising and no third-party SDKs, and requests no internet permission — so it physically
cannot send your data anywhere. Deleting the app deletes its data.

REQUIREMENTS

• A Moov Now device (the hardware is required — there is nothing to track without it)
• Android 6.0 or newer
• Bluetooth

NOTES

This is an independent project, not affiliated with or endorsed by Moov Inc. It is built from
reverse-engineered device behaviour because no official API or documentation was ever published.

The Moov Now powers down its sensor stream after a short period to save its coin-cell battery —
that is the hardware's own design, not a fault of the app. Press the button on the device to
wake it; the app reconnects on its own.
```
(approx 1,750 characters)

---

## Categorisation

| Field | Value |
|---|---|
| App category | **Health & Fitness** |
| Tags | Fitness, Tracking, Health |
| Contact email | *(your support email)* |
| Website | *(optional — your GitHub repo URL works)* |
| Privacy policy URL | **required** — see below |

---

## Data safety form

This is the section that usually confuses people. Because the app is fully offline, almost
everything is "No".

**Does your app collect or share any of the required user data types?** → **No**

If the form insists on per-category answers:

| Data type | Collected | Shared |
|---|---|---|
| Location | No | No |
| Personal info | No | No |
| Financial info | No | No |
| Health and fitness | No | No |
| Messages | No | No |
| Photos and videos | No | No |
| Files and docs | No | No |
| Calendar | No | No |
| Contacts | No | No |
| App activity | No | No |
| Web browsing | No | No |
| App info and performance | No | No |
| Device or other IDs | No | No |

**Is all of the user data collected by your app encrypted in transit?** → Not applicable
(no data leaves the device). If the form forces an answer, choose **Yes** — there is no
transmission to intercept.

**Do you provide a way for users to request that their data be deleted?** → The data never
leaves the device; uninstalling removes it. Answer **No** if the form allows, or note that
deletion is by uninstall.

**Data safety justification note** (if a free-text box appears):

```
This app has no internet permission. It connects only to a Bluetooth fitness device and
stores all data in a private local database on the user's own phone. No data is collected,
transmitted, shared, or processed by the developer or any third party.
```

---

## Content rating questionnaire

| Question | Answer |
|---|---|
| Category | Utility / Productivity / Health |
| Violence, sexuality, language, drugs, gambling | No to all |
| Does the app share user location? | No |
| Does the app allow users to interact/exchange content? | No |
| Does the app contain ads? | No |
| Does the app collect personal data? | No |

Expected outcome: **Everyone / PEGI 3**.

---

## Privacy policy

Play requires a **publicly reachable URL**. A hosted HTML page is enough — you already have
`privacy-policy.html` in your other repo for exactly this.

The policy for this app is short, because the app does nothing:

```
Moov Now Tracker — Privacy Policy

Moov Now Tracker does not collect, transmit, or share any personal data.

The app communicates only with a Moov Now fitness device over Bluetooth Low Energy, and stores
activity data (steps, workouts, motion readings) in a private database on your own device. This
data never leaves your phone. The app does not request the internet permission, contains no
analytics, no advertising, and no third-party SDKs, and requires no account.

Because no data is collected by the developer, there is nothing for us to access, retain, or
delete. Uninstalling the app removes all data it stored.

This app is an independent project and is not affiliated with, endorsed by, or connected to
Moov Inc. "Moov" and "Moov Now" are trademarks of their respective owner, used here only to
describe the device this app is compatible with.

Contact: <your email>
```

Host it anywhere static — GitHub Pages on this repo is free and instant (enable Pages for the
repo, drop the file in, use the resulting URL).

---

## Store assets you still need

| Asset | Requirement |
|---|---|
| App icon | 512 × 512 PNG — **already generated** at `android_app/assets/icon/launcher.png` |
| Feature graphic | 1024 × 500 PNG — needs making |
| Phone screenshots | at least 2, from a real device |

Take the screenshots by running the app on your phone and capturing the Today, Live and
Workout screens. Play rejects mock-ups and images with device frames.

---

## Before you upload — checklist

- [ ] App name, short and full description pasted
- [ ] Data safety form completed (all "No")
- [ ] Content rating questionnaire completed
- [ ] Privacy policy hosted and URL added
- [ ] Feature graphic (1024 × 500) created
- [ ] At least 2 real screenshots captured
- [ ] Keystore generated and the 5 repository secrets added to GitHub
- [ ] `git tag v1.0.0 && git push origin v1.0.0` to trigger the first build
