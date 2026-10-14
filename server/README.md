# Glucose server (on WHC)

Your own Nightscout-compatible server. Loop's **Monitor Glucose** service sends its data here,
while the normal Nightscout service keeps sending to Nightscout. The Glucose Monitor
app can read from either.

It must live at the **root of its own address**, for example `https://bg.example.com`
(Loop ignores folders in the address).

## What goes where

| File in this folder | Where it goes on WHC |
|---|---|
| `bg/.htaccess` | `bg.example.com` document root, e.g. `/home/CPANELUSER/bg.example.com/.htaccess` |
| `bg/index.php` | same folder |
| `bg/config.sample.php` | same folder, then copied to `config.php` and filled in |
| `bg/lib/server.php` and `bg/lib/.htaccess` | `lib/` sub-folder of that folder |
| `install.sql` | not uploaded: pasted once into phpMyAdmin |

## Steps (cPanel at WHC)

1. **Subdomain:** cPanel › *Domains* › *Create a New Domain* (or *Subdomains*): `bg.example.com`.
   Leave the document root it proposes (e.g. `bg.example.com` in your home folder). Note it.
2. **HTTPS:** cPanel › *SSL/TLS Status* › tick `bg.example.com` › *Run AutoSSL*. Wait until it shows a green lock (a few minutes).
3. **PHP version:** cPanel › *MultiPHP Manager* › tick `bg.example.com` › PHP **8.1 or newer** › *Apply*.
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
8. **Test:** open `https://bg.example.com` in a browser: it should say *The glucose server is running*.
   Then `https://bg.example.com/api/v1/status.json?token=YOUR-READ-TOKEN` should show text starting with `{"status":"ok"`.

## Loop

1. GitHub › `sircsaba/LoopWorkspace` › *Actions* › **4. Build Loop Manual** › *Run workflow* ›
   in **Use workflow from** choose **monitor-glucose** › *Run workflow*.
2. Install the new Loop build from TestFlight.
3. Loop › Settings › Services › **Add Service** › **Monitor Glucose** › Site URL `https://bg.example.com`, API Secret = your `api_secret` › Login.
   Keep the Nightscout service as it is: both upload at the same time.

## Glucose Monitor app

Settings › Data & general › tap the site address › `https://bg.example.com`, then either
**API secret** (full access) or **Access token** with one of your `read_tokens` / `care_tokens`.
