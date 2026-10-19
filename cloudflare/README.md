# Free glucose server for Loop and Trio

Your own copy of your diabetes data, on a free Cloudflare account, in about 15 minutes.
It works **with** Nightscout (or without it) and speaks the same language, so Loop, Trio,
follower apps and the Monitor Glucose app can use it.

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/sircsaba/glucose-monitor/tree/main/cloudflare)

> **For information only.** This is not a medical device. Do not make treatment
> decisions from it without checking your meter or sensor. You run it in your own
> account, at your own risk.

---

## What you get

- **Your own database** of glucose readings, boluses, carbs, temp basals, loop status and
  profile, in *your* Cloudflare account. Nobody else can see it.
- **Free:** the Cloudflare free plan allows 100,000 requests a day and a database of up to
  500 MB (about a year or more of Loop / Trio data). One Loop or Trio plus a few followers use
  a few thousand requests a day.
- **Read-only keys** for family and school, and **careportal keys** that can also log treatments.
- **No server to run:** nothing to restart or patch. Updates are one click (see *Good to know*).

## Step 1 — Choose how to use it

| Mode | What changes in Loop / Trio | What you get | Best for |
|---|---|---|---|
| **Copy** *(easiest)* | Nothing | Every minute the server copies everything new from your Nightscout | Anyone with Nightscout who wants a second, independent copy and reports |
| **Relay** | Loop / Trio use the server's address instead of Nightscout's | Every request is passed **unchanged** to your Nightscout, and Nightscout's answer goes back. The server keeps a copy, **even while Nightscout is down** | People who want their data saved even when Nightscout is down |
| **Standalone** | Loop uses the server **as** its Nightscout | Your own Nightscout-compatible site, no Nightscout needed | Loop users without Nightscout |

Copy and Relay can run together: in Relay mode the server also copies every minute, which
picks up data that reaches Nightscout from somewhere else (for example xDrip or a CGM bridge).

**Trio users:** use **Copy** or **Relay**. In both, Trio keeps getting its carbs, temp targets
and settings **from Nightscout itself**, exactly as today. In Standalone, Trio would read carbs and
temp targets from this server, and those answers feed insulin dosing. It answers Trio's queries the
way Nightscout does, but it has only been checked with automated tests, not with real use:
don't use Standalone with Trio unless you accept that risk.

**AndroidAPS users:** use **Copy**. AAPS talks to Nightscout in a newer way (API v3 and live
updates) that Relay does not handle.

## Step 2 — Create the server

You need: a free Cloudflare account (cloudflare.com › Sign up, email only, no card) and a
GitHub account (Cloudflare puts a copy of the code in it so it can update the server).

1. Click **Deploy to Cloudflare** at the top of this page and sign in.
2. Connect your GitHub account when asked, and keep the proposed repository name.
3. Cloudflare creates the database (**glucose-db**) by itself. Keep its name.
4. Fill in the settings it shows. **API_SECRET, READ_TOKENS and CARE_TOKENS come pre-filled with
   hidden example values (the dots): erase each one and type your own.** The server refuses to
   run with the example values, because everyone who reads this guide knows them.

| Setting | What to type |
|---|---|
| **API_SECRET** | A secret of 12 characters or more. You type it in Loop / Trio (Relay, Standalone) or in follower apps. Write it down. |
| **READ_TOKENS** | Read-only keys for followers, separated by commas, e.g. `readable-mom,readable-school` |
| **CARE_TOKENS** | Keys that can read **and** log treatments, e.g. `careportal-dad`. Type `none` if you don't want any. **Carbs logged with these keys reach Loop / Trio** (see *Good to know*). |
| **NIGHTSCOUT_URL** | Copy / Relay: your Nightscout address, e.g. `https://mysite.herokuapp.com`. Standalone: `none`. |
| **NIGHTSCOUT_SECRET** | Copy / Relay: your **Nightscout** API secret. Type `none` if it is the same as API_SECRET, or for Standalone. |
| **SITE_NAME** | A name, e.g. `Emma's glucose` |
| **UNITS** | `mmol` or `mg/dl` |
| **KEEP_DAYS** | How many days to keep. `365` is a safe choice: the free database stops accepting data at 500 MB. `0` keeps everything. |

5. Click **Deploy**. After a minute or two you get your address, like
   `https://glucose-server.yourname.workers.dev`. Write it down.
6. Open that address in a browser: you should see the **Monitor Glucose web app** asking to connect
   (or a page saying **The glucose server is running**). See *Step 5 — See your data in a browser*.

> **Changing a setting later:** Cloudflare dashboard › Workers & Pages › **glucose-server** ›
> Settings › *Variables and Secrets* › edit › **Deploy**.

## Step 3 — Connect Loop or Trio

### Copy mode
Nothing to change. Within a minute the server holds your last 30 hours of readings and treatments, plus your latest sensor, site and insulin changes; from then on
everything new. Check: open
`https://YOUR-ADDRESS/api/v1/entries/sgv.json?token=YOUR-READ-TOKEN` and you should see readings.

### Relay mode
Your Nightscout keeps working exactly as before; only the address Loop / Trio upload to changes.

- **Loop:** Settings › Services › **Nightscout** › *Log out*. Then add Nightscout again:
  Site URL = your server's address, API Secret = your **API_SECRET**.
- **Trio:** Settings › Services › **Nightscout** › change the URL to your server's address and
  the API secret to your **API_SECRET** › Connect.
- Only requests made with your **API_SECRET** are relayed. Loop and Trio send it with every request,
  so they read and write Nightscout itself; nothing they read comes from the server's copy.
- Remote commands (Loop Caregiver, LoopFollow, Trio remote control) keep working through Nightscout.

To go back, put your Nightscout address and secret back in Loop / Trio. Nothing else changes.

### Standalone (Loop)
Loop › Settings › Services › **Nightscout** › Site URL = your server's address,
API Secret = your **API_SECRET**. Loop starts uploading from that moment (it does not send old history).

## Step 4 — Followers

Any app that reads Nightscout can read the server with a **read token**:

- Address: your server's address
- Token: one of your `READ_TOKENS` (or `CARE_TOKENS` to log carbs and notes)
- In apps that only take an address, add it to the address: `https://YOUR-ADDRESS?token=readable-mom`

The **Monitor Glucose** app (night view, red/yellow/green zones per time of day, soft-music
alarms) connects the same way: Settings › Data & general › site address + access token.

## Step 5 — See your data in a browser

Open your server's address (`https://glucose-server.yourname.workers.dev`) in any browser, on a
computer, tablet or phone. It shows the **Monitor Glucose app**, the same as on the phone: graph,
big glucose number and arrow, night view, zones per time of day, IOB / COB, sensor and site ages.

1. The address is already filled in. Choose **Access token** and type one of your `READ_TOKENS`
   (or `CARE_TOKENS` to log carbs and notes). Pick your units › **Test and connect**.
2. Click once anywhere on the page: browsers only allow sound after a click, so alarms can sound.
3. Settings are kept in that browser (each computer has its own).

Alarms only sound **while the page is open**. A phone's browser stops when the screen locks, so for
overnight alarms use the phone app. On a computer or a tablet left on the night view, it works.

The web app is published once by this project (on GitHub Pages) and your server shows it at its own
address, so it gets updates by itself. To turn it off, add a variable `WEB_APP_URL` = `none`.

## Good to know

- **If the server is down in Relay mode,** Loop / Trio can't upload until it is back, the same as when
  Nightscout is down; they catch up afterwards. In Copy mode Loop / Trio never depend on it.
- **If Nightscout is down in Relay mode,** Loop / Trio get an error and retry later, as usual, but the
  server already keeps what they sent. Followers reading the server still see new readings.
- **Careportal keys log real treatments.** In Copy and Relay mode, carbs or boluses logged with a
  `CARE_TOKENS` key are also sent to Nightscout, where Loop or Trio can pick them up and **dose for
  them** (Standalone: Trio reads them directly). Give these keys only to people who may enter carbs.
  If sending to Nightscout fails, the app logging it gets an error: don't simply log it again elsewhere
  without checking, or it may count twice.
- **Copy mode only catches records that reach Nightscout within 10 minutes of their own time.** A
  reading or treatment uploaded later (phone offline for a while, carbs entered for an earlier time) can
  be missing from the copy. Relay mode doesn't have this gap for Loop / Trio uploads.
- **Duplicates** are merged much like Nightscout does (same reading time; same treatment id, or same
  time and type).
- **Queries:** unknown query operators are refused rather than ignored, and, like Nightscout, a query
  without a date only looks at the last 4 days.
- **Your data stays in your Cloudflare account.** Only people with your secret or one of your keys can
  read it through the server. To delete everything: Workers & Pages ›
  glucose-server › Settings › Delete, then Storage & Databases › D1 › glucose-db › Delete.
- **Updates:** the web app updates by itself. For the server, the Deploy button made a copy of this
  code in your GitHub account (repository **glucose-server**), with your settings in `wrangler.jsonc`.
  When this project's `cloudflare/src/index.js` changes, open the same file in your copy › pencil
  (*Edit*) › replace everything with the new file › *Commit changes*. Cloudflare rebuilds the server
  by itself within a minute. Don't click Deploy again: it would make a second server and database.

## Troubleshooting

| Problem | What to check |
|---|---|
| Loop / Trio says "unauthorized" | The secret typed in Loop / Trio must be your **API_SECRET** (12+ characters), not a token. |
| Copy mode stays empty | NIGHTSCOUT_URL must start with `https://`; NIGHTSCOUT_SECRET must be your Nightscout API secret. Dashboard › glucose-server › *Logs* shows "copy from Nightscout failed" with the reason. The first copy covers the last 30 hours; older history is not copied. |
| Loop / Trio errors in Relay mode with a 301 / 302 status | NIGHTSCOUT_URL must be the exact address Nightscout answers on (usually `https://...`, with or without `www`). The server does not follow redirects, so an upload can never be lost on the way. |
| Follower app shows nothing | Use a READ_TOKEN, and check the address has no extra folder at the end. |
| Home page says "Not ready: Replace the example values…" | Settings › Variables and Secrets: give API_SECRET, READ_TOKENS and CARE_TOKENS your own values, then Deploy. |
| "API_SECRET must be at least 12 characters" | Make the secret longer in Variables and Secrets, then Deploy. |

## Without the button (for developers)

```bash
npm install
npx wrangler d1 create glucose-db          # put the id it prints in wrangler.jsonc
npx wrangler secret put API_SECRET
npx wrangler secret put READ_TOKENS
npx wrangler secret put CARE_TOKENS
npx wrangler secret put NIGHTSCOUT_SECRET  # or "none"
npm run deploy                              # creates the tables, then deploys
npm test                                    # runs the tests with plain Node (no account needed)
```

What the server answers: the Nightscout API v1 used by Loop and Trio — `entries`,
`treatments`, `devicestatus`, `profile` (GET, POST, PUT, DELETE, with `find[...]` filters
`$eq $ne $gt $gte $lt $lte $exists $in $nin $and $or`), `status`, `verifyauth` and
`experiments/test`.
