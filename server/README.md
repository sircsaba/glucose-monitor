# Glucose server (on WHC)

Your own Nightscout-compatible server. Loop's **Monitor Glucose Service** sends its data here,
while the normal Nightscout service keeps sending to Nightscout. The Monitor Glucose
app can read from either.

It must live at the **root of its own address**, for example `https://bg.inforap.com`
(Loop ignores folders in the address).

## What goes where

| File in this folder | Where it goes on WHC |
|---|---|
| `bg/.htaccess` | `bg.inforap.com` document root, e.g. `/home/CPANELUSER/bg.inforap.com/.htaccess` |
| `bg/index.php` | same folder |
| `bg/config.sample.php` | same folder, then copied to `config.php` and filled in |
| `bg/lib/server.php`, `bg/lib/libre.php`, `bg/lib/copy.php` and `bg/lib/.htaccess` | `lib/` sub-folder of that folder |
| `install.sql` | not uploaded: pasted once into phpMyAdmin |

## Steps (cPanel at WHC)

1. **Subdomain:** cPanel › *Domains* › *Create a New Domain* (or *Subdomains*): `bg.inforap.com`.
   Leave the document root it proposes (e.g. `bg.inforap.com` in your home folder). Note it.
2. **HTTPS:** cPanel › *SSL/TLS Status* › tick `bg.inforap.com` › *Run AutoSSL*. Wait until it shows a green lock (a few minutes).
3. **PHP version:** cPanel › *MultiPHP Manager* › tick `bg.inforap.com` › PHP **8.1 or newer** › *Apply*.
4. **Database:** cPanel › *MySQL Databases*:
   - *Create New Database*: `glucose` (cPanel names it `CPANELUSER_glucose`).
   - *Add New User*: `glucose`, a strong password (it becomes `CPANELUSER_glucose`).
   - *Add User To Database*: that user, that database, tick **ALL PRIVILEGES**.
5. **Tables:** cPanel › *phpMyAdmin* › click `CPANELUSER_glucose` on the left › *SQL* tab › paste all of `install.sql` › *Go*.
   You should see four tables: `entries`, `treatments`, `devicestatus`, `profile`.
6. **Files:** cPanel › *File Manager* › open the subdomain's document root.
   *Settings* (top right) › tick *Show Hidden Files*. *Upload* `glucose-server.zip`, then right-click it › *Extract*.
   Move the contents of the extracted `bg` folder up into the document root, so `index.php`, `.htaccess` and `lib/` sit directly in it.
7. **Settings:** in File Manager, right-click `config.sample.php` › *Copy* › name it `config.php`. Right-click `config.php` › *Edit*:
   - `db_dsn`, `db_user`, `db_pass`: your database name, user and password from step 4.
   - `api_secret`: a long secret (12+ characters). This is what you type in Loop.
   - `read_tokens`: keys for read-only followers. `care_tokens`: keys that may also log treatments.
   - Save.
8. **Test:** open `https://bg.inforap.com` in a browser: it should say *The glucose server is running*.
   Then `https://bg.inforap.com/api/v1/status.json?token=YOUR-READ-TOKEN` should show text starting with `{"status":"ok"`.

## Loop

1. GitHub › `sircsaba/LoopWorkspace` › *Actions* › **4. Build Loop Manual** › *Run workflow* ›
   in **Use workflow from** choose **inforap-service** › *Run workflow*.
2. Install the new Loop build from TestFlight.
3. Loop › Settings › Services › **Add Service** › **Monitor Glucose Service** › Site URL `https://bg.inforap.com`, API Secret = your `api_secret` › Login.
   Keep the Nightscout service as it is: both upload at the same time.

## Libre 3 readings straight from LibreLinkUp (recommended)

`lib/libre.php` logs in to LibreLinkUp, the same service the LibreLinkUp app and Nightscout's
LibreLinkUp bridge use, and stores every new reading here, each minute. Nightscout is not needed.

1. **Follower account:** the Libre 3 user invites a LibreLinkUp follower (Libre app › *Connected apps* ›
   *LibreLinkUp*). Install **LibreLinkUp** on a phone, log in with that follower account once and accept
   the terms. You can use the same follower account your Nightscout already uses.
2. Upload `lib/libre.php` to the `lib/` folder (next to `server.php`).
3. In `config.php`, add (before the last `];`):
   ```php
   'libre_email' => 'FOLLOWER-EMAIL',
   'libre_password' => 'FOLLOWER-PASSWORD',
   'libre_patient' => '',
   'libre_version' => '4.16.0',
   ```
4. cPanel › *Cron Jobs* › *Add New Cron Job* › *Once Per Minute* › command:
   ```
   /usr/local/bin/php /home/CPANELUSER/bg.inforap.com/lib/libre.php >/dev/null 2>&1
   ```
5. After 2 minutes, `https://bg.inforap.com/api/v1/entries/sgv.json?token=YOUR-READ-TOKEN` shows readings
   with `"device":"librelinkup-direct"`. The first run also brings in the last 12 hours (one every 15 min).
6. **Loop reads from here instead of Nightscout:** Loop › Settings › CGM › *Nightscout Remote CGM* ›
   change the site to `https://bg.inforap.com` and the API secret to your `api_secret`.

The login is kept in `lib/.libre-session.json` (blocked from the web) and renewed when it expires, so
LibreLinkUp sees about one login a day, not one a minute.

## Glucose readings when Loop's CGM is "Nightscout"

Loop never uploads readings that came **from** Nightscout (so they don't go round in a
circle), and that applies to every service. The server then gets treatments and loop
status from Loop, but no glucose. `lib/copy.php` fetches the readings from Nightscout instead:

1. Upload `lib/copy.php` to the `lib/` folder (next to `server.php`).
2. In `config.php`, add (or fill in) these lines before the last `];`:
   ```php
   'nightscout_url' => 'https://YOUR-NIGHTSCOUT-ADDRESS',
   'nightscout_secret' => 'YOUR-NIGHTSCOUT-API-SECRET',
   'copy_first_hours' => 30,
   ```
3. cPanel › *Cron Jobs* › *Add New Cron Job*:
   - *Common Settings*: **Once Per Minute (\* \* \* \* \*)**
   - *Command* (replace CPANELUSER and the folder with your document root from step 1):
     ```
     /usr/local/bin/php /home/CPANELUSER/bg.inforap.com/lib/copy.php >/dev/null 2>&1
     ```
   - *Add New Cron Job*.
4. Check after 2 minutes: `https://bg.inforap.com/api/v1/entries/sgv.json?token=YOUR-READ-TOKEN` shows readings.
   The first run copies the last 30 hours; then each minute only the new ones. A reading
   is never stored twice.

To test the command once by hand: cPanel › *Terminal* (if your plan has it) and run the same
command without `>/dev/null 2>&1`: it prints `Copied N new reading(s) from Nightscout`.

## Importing the history from a Nightscout (one time)

`lib/import.php` copies everything from a Nightscout site: all glucose
readings, all treatments, the profiles, and the loop status of the last 30 days
(loop status is big; change `import_devicestatus_days`). Records already here
are skipped, so it never makes duplicates.

1. In `config.php` add `'import_url' => 'https://your-nightscout'` and
   `'import_secret' => 'its API secret'`.
2. cPanel › Cron Jobs › Once Per Minute, command:
   `/usr/local/bin/php /home/CPANELUSER/your-site/lib/import.php >> /home/CPANELUSER/import.log 2>&1`
3. Each run imports for about 40 seconds and continues where it stopped.
   Watch `import.log`; when it says **Import finished**, delete that cron job.

## Web app at your own address

Opening your site (for example `https://bg.inforap.com`) in a browser shows the
Monitor Glucose web app, the same as on the phone. The first time, enter your
site address and your read token. The data stays under `/api/v1/...`.
The app files come from the published copy on GitHub Pages and are refreshed
every minute (a copy is kept in `lib/.webcache/`, so it still opens if GitHub is
down). To turn it off, put `'web_app_url' => 'none',` in `config.php`.

## Monitor Glucose app

Settings › Data & general › tap the site address › `https://bg.inforap.com`, then either
**API secret** (full access) or **Access token** with one of your `read_tokens` / `care_tokens`.
