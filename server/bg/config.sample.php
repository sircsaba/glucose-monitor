<?php
// Copy this file to config.php (same folder) and fill in your values.
// config.php is never shown to visitors (blocked in .htaccess).

return [
    // MySQL database created in cPanel › MySQL Databases.
    // WHC names look like: cpaneluser_glucose
    'db_dsn'  => 'mysql:host=localhost;dbname=CPANELUSER_glucose;charset=utf8mb4',
    'db_user' => 'CPANELUSER_glucose',
    'db_pass' => 'DATABASE-PASSWORD',

    // The secret you type in Loop (Settings › Services › Inforap) and in the
    // glucose app ("API secret"). At least 12 characters. Full access.
    'api_secret' => 'CHANGE-ME-LONG-SECRET',

    // Read-only access keys, for followers. Used as ?token=... or in the
    // glucose app as "Access token". Add as many as you like.
    'read_tokens' => [
        'readable-CHANGE-ME',
    ],

    // Keys that can read AND log treatments (careportal), e.g. for a parent.
    'care_tokens' => [
        'careportal-CHANGE-ME',
    ],

    // Name shown by the glucose app after connecting.
    'site_name' => 'Inforap Glucose',

    // Units reported to apps: 'mmol' or 'mg/dl' (data is always stored in mg/dL).
    'units' => 'mmol',

    // Delete data older than this many days (0 = keep forever).
    'keep_days' => 0,

    // Read the Libre 3 / Libre 3 Plus readings straight from LibreLinkUp (no
    // Nightscout needed). Use a LibreLinkUp FOLLOWER account that the sensor
    // user has invited, opened once in the LibreLinkUp app (terms accepted).
    // Runs from a cron job: see README.md. Leave '' to turn it off.
    'libre_email' => '',
    'libre_password' => '',
    'libre_patient' => '',             // first name, only if the account follows several people
    'libre_version' => '4.16.0',       // raise it if LibreLinkUp starts refusing ("version" errors)

    // Copy CGM readings from Nightscout (needed when Loop's CGM is "Nightscout":
    // Loop never uploads those readings to a service). Runs from a cron job:
    // see README.md. Leave '' to turn it off.
    'nightscout_url' => '',            // e.g. 'https://mysite.herokuapp.com'
    'nightscout_secret' => '',         // your Nightscout API secret
    'copy_first_hours' => 30,          // the first copy fetches this many hours

    // The web app at this site's address (https://your-site/). '' = the
    // published Glucose Monitor app; 'none' = only the API, no web app.
    'web_app_url' => '',
];
