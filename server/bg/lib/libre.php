<?php
// Fetches glucose readings straight from LibreLinkUp (LibreView's follower
// service, the one the LibreLinkUp app and nightscout-librelink-up use) and
// stores them in this server. No Nightscout needed.
//
// Before using it: in the LibreLinkUp phone app, log in once with the follower
// account below and accept the terms; the Libre 3 user must have invited that
// account (LibreView / Libre app › Connected apps › LibreLinkUp).
//
// Run it every minute with a cPanel cron job (see README.md):
//   /usr/local/bin/php /home/CPANELUSER/bg.example.com/lib/libre.php
// It only runs from the command line (cron), never from a browser.
declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit;
}

$cfg = require __DIR__ . '/../config.php';
$email = trim((string)($cfg['libre_email'] ?? ''));
$password = (string)($cfg['libre_password'] ?? '');
if ($email === '' || $password === '') exit(0); // turned off

$base = rtrim((string)($cfg['libre_api'] ?? 'https://api.libreview.io'), '/');
$version = (string)($cfg['libre_version'] ?? '4.16.0');
$patientWanted = trim((string)($cfg['libre_patient'] ?? '')); // first name, if the account follows several people
$cacheFile = __DIR__ . '/.libre-session.json'; // login kept here (lib/ is blocked from the web)

// One run at a time.
$lock = fopen(sys_get_temp_dir() . '/glucose-libre-' . md5(__DIR__) . '.lock', 'c');
if ($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) exit(0);

final class LibreError extends Exception {}

// The last result, shown by the apps when something is wrong (see server.php).
function saveStatus(?string $error, int $added = 0): void
{
    $file = __DIR__ . '/.libre-status.json';
    $old = is_file($file) ? (json_decode((string)file_get_contents($file), true) ?: []) : [];
    $s = $error === null
        ? ['ok' => true, 'at' => time(), 'added' => $added, 'fails' => 0]
        : ['ok' => false, 'at' => time(), 'error' => $error, 'fails' => (int)($old['fails'] ?? 0) + 1,
           'since' => (int)(($old['ok'] ?? true) ? time() : ($old['since'] ?? time()))];
    @file_put_contents($file, json_encode($s), LOCK_EX);
}

function llu(string $method, string $url, array $headers, ?array $body = null): array
{
    $ch = curl_init($url);
    $h = [];
    foreach ($headers as $k => $v) $h[] = "$k: $v";
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_HTTPHEADER => $h,
        CURLOPT_TIMEOUT => 30,
        CURLOPT_CONNECTTIMEOUT => 10,
        CURLOPT_ENCODING => '',
    ]);
    if ($body !== null) curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
    $raw = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err = curl_error($ch);
    curl_close($ch);
    if ($raw === false) throw new LibreError("LibreLinkUp not reachable: $err");
    $j = json_decode($raw, true);
    if ($code === 401 || $code === 403) throw new LibreError("LibreLinkUp refused the login or the session (HTTP $code)", $code);
    if ($code === 429) throw new LibreError('LibreLinkUp: too many requests, will try again later', 429);
    if ($code !== 200 || !is_array($j)) throw new LibreError("LibreLinkUp answered HTTP $code: " . substr((string)$raw, 0, 200), $code);
    return $j;
}

function baseHeaders(string $version): array
{
    return [
        'Accept' => 'application/json',
        'Content-Type' => 'application/json',
        'product' => 'llu.android',
        'version' => $version,
        'User-Agent' => 'Mozilla/5.0 (Linux; Android 14) GlucoseMonitor',
        'Cache-Control' => 'no-cache',
    ];
}

/** Logs in (following the regional redirect) and returns [api base, token, account id hash, expires]. */
function login(string $base, string $email, string $password, string $version): array
{
    for ($i = 0; $i < 3; $i++) {
        $j = llu('POST', "$base/llu/auth/login", baseHeaders($version), ['email' => $email, 'password' => $password]);
        $data = $j['data'] ?? [];
        if (!empty($data['redirect']) && !empty($data['region'])) {
            $base = 'https://api-' . preg_replace('/[^a-z0-9-]/', '', strtolower((string)$data['region'])) . '.libreview.io';
            continue;
        }
        $status = (int)($j['status'] ?? 0);
        if ($status === 4) {
            throw new LibreError('LibreLinkUp asks to accept new terms: open the LibreLinkUp app with this account and accept them');
        }
        $token = $data['authTicket']['token'] ?? null;
        $userId = $data['user']['id'] ?? null;
        if (!$token || !$userId) throw new LibreError('LibreLinkUp login failed: check libre_email / libre_password');
        $expires = (int)($data['authTicket']['expires'] ?? (time() + 3600));
        return [$base, $token, hash('sha256', (string)$userId), $expires];
    }
    throw new LibreError('LibreLinkUp kept redirecting the login');
}

/** "10/15/2026 3:30:00 PM" in UTC (FactoryTimestamp) -> milliseconds. */
function factoryMs(?string $ts): ?int
{
    if (!$ts) return null;
    $d = DateTime::createFromFormat('n/j/Y g:i:s A', $ts, new DateTimeZone('UTC'));
    return $d ? $d->getTimestamp() * 1000 : null;
}

// LibreLinkUp trend (1..5) -> Nightscout direction.
const TREND = [1 => 'SingleDown', 2 => 'FortyFiveDown', 3 => 'Flat', 4 => 'FortyFiveUp', 5 => 'SingleUp'];

function readings(array $graph): array
{
    $out = [];
    $add = function (?array $m) use (&$out) {
        if (!$m) return;
        $ms = factoryMs($m['FactoryTimestamp'] ?? null);
        $mg = $m['ValueInMgPerDl'] ?? null;
        if ($ms === null || !is_numeric($mg) || $mg <= 0) return;
        $out[$ms] = [
            'type' => 'sgv',
            'sgv' => (int)round((float)$mg),
            'date' => $ms,
            'dateString' => gmdate('Y-m-d\TH:i:s.000\Z', intdiv($ms, 1000)),
            'direction' => TREND[(int)($m['TrendArrow'] ?? 0)] ?? 'NONE',
            'device' => 'librelinkup-direct',
        ];
    };
    foreach ($graph['data']['graphData'] ?? [] as $m) $add($m); // last 12 h, every 15 min
    $add($graph['data']['connection']['glucoseMeasurement'] ?? null); // the current reading
    ksort($out);
    return array_values($out);
}

try {
    // Reuse the saved login while it is valid (logging in every minute gets blocked).
    $s = is_file($cacheFile) ? json_decode((string)file_get_contents($cacheFile), true) : null;
    $fresh = false;
    if (!is_array($s) || ($s['email'] ?? '') !== $email || (int)($s['expires'] ?? 0) < time() + 300) {
        [$api, $token, $acct, $exp] = login($base, $email, $password, $version);
        $s = ['email' => $email, 'api' => $api, 'token' => $token, 'account' => $acct, 'expires' => $exp];
        file_put_contents($cacheFile, json_encode($s), LOCK_EX);
        @chmod($cacheFile, 0600);
        $fresh = true;
    }
    $headers = baseHeaders($version) + ['Authorization' => 'Bearer ' . $s['token'], 'Account-Id' => $s['account']];

    try {
        $conn = llu('GET', $s['api'] . '/llu/connections', $headers);
    } catch (LibreError $e) {
        if ($fresh || !in_array($e->getCode(), [401, 403], true)) throw $e;
        // Saved login no longer accepted: log in again once.
        [$api, $token, $acct, $exp] = login($base, $email, $password, $version);
        $s = ['email' => $email, 'api' => $api, 'token' => $token, 'account' => $acct, 'expires' => $exp];
        file_put_contents($cacheFile, json_encode($s), LOCK_EX);
        $headers = baseHeaders($version) + ['Authorization' => 'Bearer ' . $s['token'], 'Account-Id' => $s['account']];
        $conn = llu('GET', $s['api'] . '/llu/connections', $headers);
    }

    $people = $conn['data'] ?? [];
    if (!$people) throw new LibreError('This LibreLinkUp account follows nobody: accept the invitation in the LibreLinkUp app');
    $person = $people[0];
    if ($patientWanted !== '') {
        foreach ($people as $p) {
            if (strcasecmp((string)($p['firstName'] ?? ''), $patientWanted) === 0) $person = $p;
        }
    }
    $pid = rawurlencode((string)$person['patientId']);
    $graph = llu('GET', $s['api'] . "/llu/connections/$pid/graph", $headers);
    $list = readings($graph);

    $db = new PDO($cfg['db_dsn'], $cfg['db_user'] ?? null, $cfg['db_pass'] ?? null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    // A reading at the same minute from another source (e.g. a Nightscout copy)
    // counts as the same reading: never stored twice.
    $near = $db->prepare("SELECT id FROM entries WHERE type = 'sgv' AND date_ms BETWEEN ? AND ?");
    $insert = $db->prepare('INSERT INTO entries (id, date_ms, type, doc) VALUES (?, ?, ?, ?)');
    $added = 0;
    $db->beginTransaction();
    foreach ($list as $doc) {
        $near->execute([$doc['date'] - 30000, $doc['date'] + 30000]);
        if ($near->fetchColumn()) continue;
        $doc['_id'] = bin2hex(random_bytes(12));
        $insert->execute([$doc['_id'], $doc['date'], 'sgv', json_encode($doc, JSON_UNESCAPED_SLASHES)]);
        $added++;
    }
    $db->commit();
    saveStatus(null, $added);
    echo "LibreLinkUp: $added new reading(s)\n";
} catch (Throwable $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    saveStatus($e instanceof LibreError ? $e->getMessage() : 'Error: ' . $e->getMessage());
    if ($e instanceof LibreError && in_array($e->getCode(), [401, 403], true)) @unlink($cacheFile);
    exit(1);
}
