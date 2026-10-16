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
// App identities LibreLinkUp accepts, tried in turn until one logs in; the one
// that works is remembered. 'libre_version' in config.php adds your own first.
$identities = [
    ['product' => 'llu.ios', 'version' => '4.16.0',
     'ua' => 'Mozilla/5.0 (iPhone; CPU OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/10A5355d Safari/8536.25'],
    ['product' => 'llu.android', 'version' => '5.0.1', 'ua' => 'LibreLinkUp/5.0.1'],
    ['product' => 'llu.android', 'version' => '4.16.0', 'ua' => 'Mozilla/5.0 (Linux; Android 14) GlucoseMonitor'],
];
$custom = trim((string)($cfg['libre_version'] ?? ''));
if ($custom !== '' && $custom !== '4.16.0') {
    array_unshift($identities, ['product' => 'llu.ios', 'version' => $custom, 'ua' => $identities[0]['ua']]);
}
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
    $what = parse_url($url, PHP_URL_PATH) ?: $url;
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
    if ($raw === false) throw new LibreError("LibreLinkUp not reachable ($what): $err");
    $j = json_decode($raw, true);
    if ($code === 401 || $code === 403) throw new LibreError("LibreLinkUp refused the login or the session (HTTP $code at $what)", $code);
    if ($code === 429) throw new LibreError('LibreLinkUp: too many requests, will try again later', 429);
    if ($code !== 200 || !is_array($j)) throw new LibreError("LibreLinkUp answered HTTP $code at $what: " . substr((string)$raw, 0, 200), $code);
    return $j;
}

function baseHeaders(array $id): array
{
    return [
        'Accept' => 'application/json',
        'Content-Type' => 'application/json',
        'product' => $id['product'],
        'version' => $id['version'],
        'User-Agent' => $id['ua'],
        'Cache-Control' => 'no-cache',
        'Connection' => 'Keep-Alive',
    ];
}

/** Logs in (following the regional redirect) and returns [api base, token, account id hash, expires]. */
function login(string $base, string $email, string $password, array $id): array
{
    $accepted = 0;
    for ($i = 0; $i < 5; $i++) {
        $j = llu('POST', "$base/llu/auth/login", baseHeaders($id), ['email' => $email, 'password' => $password]);
        $data = $j['data'] ?? [];
        if (!empty($data['redirect']) && !empty($data['region'])) {
            $base = 'https://api-' . preg_replace('/[^a-z0-9-]/', '', strtolower((string)$data['region'])) . '.libreview.io';
            continue;
        }
        $status = (int)($j['status'] ?? 0);
        if ($status === 4) {
            // A step after login, usually new terms of use ('tou'): accept it the
            // way the app does, then log in again.
            $step = preg_replace('/[^a-z0-9_-]/i', '', (string)($data['step']['type'] ?? ''));
            $ticket = $data['authTicket']['token'] ?? null;
            if ($step === '' || !$ticket || $accepted >= 2) {
                throw new LibreError('LibreLinkUp asks to accept new terms: open the LibreLinkUp app with this account and accept them');
            }
            llu('POST', "$base/auth/continue/$step", baseHeaders($id) + ['Authorization' => "Bearer $ticket"], []);
            $accepted++;
            continue;
        }
        $token = $data['authTicket']['token'] ?? null;
        $userId = $data['user']['id'] ?? null;
        if (!$token || !$userId) throw new LibreError('LibreLinkUp login failed: check libre_email / libre_password');
        $expires = (int)($data['authTicket']['expires'] ?? (time() + 3600));
        return [$base, $token, hash('sha256', (string)$userId), $expires];
    }
    throw new LibreError('LibreLinkUp kept redirecting the login');
}

/** Logs in with the first identity LibreLinkUp accepts (the remembered one first). */
function loginAny(string $base, string $email, string $password, array $identities, ?array $prefer, array $skip = []): array
{
    if ($prefer) array_unshift($identities, $prefer);
    $last = null;
    $tried = array_fill_keys($skip, true);
    foreach ($identities as $id) {
        $key = $id['product'] . ' ' . $id['version'];
        if (isset($tried[$key])) continue;
        $tried[$key] = true;
        try {
            return array_merge(login($base, $email, $password, $id), [$id]);
        } catch (LibreError $e) {
            $last = $e;
            // Wrong password or new terms: another identity will not help.
            if (in_array($e->getCode(), [401, 429], true) || str_contains($e->getMessage(), 'terms') || str_contains($e->getMessage(), 'check libre_email')) throw $e;
        }
    }
    throw $last ?? new LibreError('LibreLinkUp login failed');
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
    $prefer = is_array($s) && is_array($s['id'] ?? null) ? $s['id'] : null;
    $skip = [];
    $doLogin = function () use ($base, $email, $password, $identities, &$prefer, &$skip, $cacheFile) {
        [$api, $token, $acct, $exp, $id] = loginAny($base, $email, $password, $identities, $prefer, $skip);
        $prefer = $id;
        $s = ['email' => $email, 'api' => $api, 'token' => $token, 'account' => $acct, 'expires' => $exp, 'id' => $id];
        file_put_contents($cacheFile, json_encode($s), LOCK_EX);
        @chmod($cacheFile, 0600);
        return $s;
    };
    if (!is_array($s) || ($s['email'] ?? '') !== $email || !is_array($s['id'] ?? null) || (int)($s['expires'] ?? 0) < time() + 300) {
        $s = $doLogin();
        $fresh = true;
    }
    $headers = baseHeaders($s['id']) + ['Authorization' => 'Bearer ' . $s['token'], 'Account-Id' => $s['account']];

    for ($attempt = 0; ; $attempt++) {
        try {
            $conn = llu('GET', $s['api'] . '/llu/connections', $headers);
            break;
        } catch (LibreError $e) {
            $code = $e->getCode();
            if (!in_array($code, [401, 403, 405], true) || $attempt >= count($identities)) throw $e;
            if ($code !== 405 && $fresh) throw $e;
            // 405: this app identity is refused now, try the next one.
            // 401/403: the saved login expired, log in again.
            if ($code === 405) $skip[] = $s['id']['product'] . ' ' . $s['id']['version'];
            $prefer = $code === 405 ? null : $s['id'];
            $s = $doLogin();
            $fresh = true;
            $headers = baseHeaders($s['id']) + ['Authorization' => 'Bearer ' . $s['token'], 'Account-Id' => $s['account']];
        }
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
    echo date('Y-m-d H:i:s ') . "LibreLinkUp: $added new reading(s)\n";
} catch (Throwable $e) {
    fwrite(STDERR, date('Y-m-d H:i:s ') . $e->getMessage() . "\n");
    saveStatus($e instanceof LibreError ? $e->getMessage() : 'Error: ' . $e->getMessage());
    if ($e instanceof LibreError && in_array($e->getCode(), [401, 403, 405], true)) @unlink($cacheFile);
    exit(1);
}
