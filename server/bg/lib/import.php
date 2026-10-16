<?php
// One-time import of the whole history from a Nightscout site into this server:
// glucose readings, treatments (boluses, carbs, temp basals, notes…), profiles,
// and the recent loop status. Records already here are not copied twice.
//
// It works in small portions so the host never stops it half-way: each run
// imports for about 40 seconds, remembers where it stopped (lib/.import-state.json)
// and the next run continues. Run it every minute with a cPanel cron job until
// the log says "Import finished", then delete the cron job:
//   /usr/local/bin/php /home/CPANELUSER/bg.example.com/lib/import.php >> /home/CPANELUSER/import.log 2>&1
//
// Settings in config.php:
//   'import_url'    => 'https://your-nightscout.example.com',
//   'import_secret' => 'your Nightscout API secret (or a token with read access)',
//   'import_devicestatus_days' => 30,   // loop status is big: only the last N days (0 = none)
// To start over from the beginning, delete lib/.import-state.json.
declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit;
}

$cfg = require __DIR__ . '/../config.php';
$ns = rtrim(trim((string)($cfg['import_url'] ?? '')), '/');
if ($ns === '') {
    fwrite(STDERR, "Set 'import_url' in config.php first\n");
    exit(1);
}
if (!preg_match('#^https?://#', $ns)) $ns = 'https://' . $ns;
$secret = trim((string)($cfg['import_secret'] ?? ''));
$dsDays = (int)($cfg['import_devicestatus_days'] ?? 30);
$stateFile = __DIR__ . '/.import-state.json';
$budget = time() + 40;

$lock = fopen(sys_get_temp_dir() . '/glucose-import-' . md5(__DIR__) . '.lock', 'c');
if ($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) exit(0);

$state = is_file($stateFile) ? (json_decode((string)file_get_contents($stateFile), true) ?: []) : [];
if (!empty($state['done'])) exit(0);
$saveState = function () use (&$state, $stateFile) {
    file_put_contents($stateFile, json_encode($state, JSON_PRETTY_PRINT), LOCK_EX);
};

$db = new PDO($cfg['db_dsn'], $cfg['db_user'] ?? null, $cfg['db_pass'] ?? null, [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
]);

function nsGet(string $ns, string $secret, string $path, array $query): array
{
    $headers = ['Accept: application/json'];
    // A token looks like "name-0123456789abcdef"; anything else is the API secret.
    if (preg_match('/^[A-Za-z0-9_]+-[0-9a-f]{16}$/', $secret)) {
        $query['token'] = $secret;
    } elseif ($secret !== '') {
        $headers[] = 'api-secret: ' . sha1($secret);
    }
    $url = $ns . $path . '?' . http_build_query($query);
    for ($try = 1; $try <= 3; $try++) {
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_TIMEOUT => 60,
            CURLOPT_CONNECTTIMEOUT => 15,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_MAXREDIRS => 3,
            CURLOPT_ENCODING => '',
        ]);
        $body = curl_exec($ch);
        $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $err = curl_error($ch);
        curl_close($ch);
        if ($code === 401 || $code === 403) throw new RuntimeException("Nightscout refused access (HTTP $code): check import_secret");
        if ($body !== false && $code === 200) {
            $j = json_decode($body);
            if (is_array($j)) return $j;
            throw new RuntimeException('Nightscout sent something that is not a list');
        }
        sleep(2 * $try);
    }
    throw new RuntimeException("Nightscout did not answer: HTTP $code $err");
}

function toMs($v): ?int
{
    if (is_int($v) || is_float($v) || (is_string($v) && ctype_digit($v))) {
        $n = (int)$v;
        return $n < 100000000000 ? $n * 1000 : $n;
    }
    if (!is_string($v) || $v === '') return null;
    $t = strtotime($v);
    return $t === false ? null : $t * 1000 + (preg_match('/\.(\d{3})/', $v, $m) ? (int)$m[1] : 0);
}

function enc(object $doc): string
{
    return json_encode($doc, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION);
}

function newId(): string
{
    return bin2hex(random_bytes(12));
}

function log_line(string $s): void
{
    echo date('Y-m-d H:i:s') . ' ' . $s . "\n";
}

$entryNear = $db->prepare('SELECT 1 FROM entries WHERE type = ? AND date_ms BETWEEN ? AND ?');
$entryById = $db->prepare('SELECT 1 FROM entries WHERE id = ?');
$entryIns = $db->prepare('INSERT INTO entries (id, date_ms, type, doc) VALUES (?, ?, ?, ?)');
$treatById = $db->prepare('SELECT 1 FROM treatments WHERE id = ?');
$treatBySync = $db->prepare('SELECT 1 FROM treatments WHERE sync_id = ?');
$treatBySame = $db->prepare('SELECT 1 FROM treatments WHERE created_ms = ? AND event_type = ?');
$treatIns = $db->prepare('INSERT INTO treatments (id, created_ms, event_type, sync_id, doc) VALUES (?, ?, ?, ?, ?)');
$dsById = $db->prepare('SELECT 1 FROM devicestatus WHERE id = ?');
$dsNear = $db->prepare('SELECT 1 FROM devicestatus WHERE created_ms BETWEEN ? AND ?');
$dsIns = $db->prepare('INSERT INTO devicestatus (id, created_ms, doc) VALUES (?, ?, ?)');
$profById = $db->prepare('SELECT 1 FROM profile WHERE id = ?');
$profByStart = $db->prepare('SELECT 1 FROM profile WHERE start_ms = ?');
$profIns = $db->prepare('INSERT INTO profile (id, created_ms, start_ms, doc) VALUES (?, ?, ?, ?)');

$has = function (PDOStatement $st, array $args): bool {
    $st->execute($args);
    $r = $st->fetchColumn();
    $st->closeCursor();
    return $r !== false;
};

$nowMs = (int)round(microtime(true) * 1000);
$page = 1000;

try {
    // ---------- profiles (once) ----------
    if (empty($state['profile_done'])) {
        $added = 0;
        foreach (nsGet($ns, $secret, '/api/v1/profile.json', ['count' => 1000]) as $doc) {
            if (!is_object($doc)) continue;
            $created = toMs($doc->created_at ?? null) ?? toMs($doc->mills ?? null) ?? $nowMs;
            $start = toMs($doc->startDate ?? null) ?? $created;
            $id = isset($doc->_id) && is_string($doc->_id) ? $doc->_id : newId();
            if ($has($profById, [$id]) || $has($profByStart, [$start])) continue;
            $doc->_id = $id;
            $profIns->execute([$id, $created, $start, enc($doc)]);
            $added++;
        }
        $state['profile_done'] = true;
        $saveState();
        log_line("Profiles: $added imported");
    }

    // ---------- glucose readings, newest to oldest ----------
    while (empty($state['entries_done']) && time() < $budget) {
        $before = (int)($state['entries_before'] ?? $nowMs + 60000);
        $docs = nsGet($ns, $secret, '/api/v1/entries.json', ['count' => $page, 'find' => ['date' => ['$lt' => $before]]]);
        $added = 0;
        $oldest = $before;
        $db->beginTransaction();
        foreach ($docs as $doc) {
            if (!is_object($doc) || !isset($doc->date) || !is_numeric($doc->date)) continue;
            $date = (int)$doc->date;
            $oldest = min($oldest, $date);
            $type = (string)($doc->type ?? 'sgv');
            $id = isset($doc->_id) && is_string($doc->_id) && $doc->_id !== '' ? $doc->_id : newId();
            // Same reading from another source (e.g. LibreLinkUp) within 30 seconds: keep one.
            if ($has($entryById, [$id]) || $has($entryNear, [$type, $date - 30000, $date + 30000])) continue;
            $doc->_id = $id;
            $entryIns->execute([$id, $date, $type, enc($doc)]);
            $added++;
        }
        $db->commit();
        $state['entries_added'] = (int)($state['entries_added'] ?? 0) + $added;
        if (count($docs) === 0 || $oldest >= $before) {
            $state['entries_done'] = true;
            log_line('Glucose readings: finished, ' . $state['entries_added'] . ' imported in total');
        } else {
            $state['entries_before'] = $oldest;
            log_line("Glucose readings: +$added, now at " . gmdate('Y-m-d', intdiv($oldest, 1000)));
        }
        $saveState();
    }

    // ---------- treatments, newest to oldest ----------
    while (!empty($state['entries_done']) && empty($state['treat_done']) && time() < $budget) {
        $before = (int)($state['treat_before'] ?? $nowMs + 60000);
        $iso = gmdate('Y-m-d\TH:i:s', intdiv($before, 1000)) . sprintf('.%03dZ', $before % 1000);
        $docs = nsGet($ns, $secret, '/api/v1/treatments.json', ['count' => $page, 'find' => ['created_at' => ['$lt' => $iso]]]);
        $added = 0;
        $oldest = $before;
        $db->beginTransaction();
        foreach ($docs as $doc) {
            if (!is_object($doc)) continue;
            $created = toMs($doc->created_at ?? null) ?? toMs($doc->mills ?? null);
            if ($created === null) continue;
            $oldest = min($oldest, $created);
            $type = substr((string)($doc->eventType ?? ''), 0, 64);
            $sync = null;
            foreach (['syncIdentifier', 'identifier', 'pumpId'] as $k) {
                if (isset($doc->$k) && is_scalar($doc->$k) && (string)$doc->$k !== '') {
                    $sync = substr($k . ':' . (string)$doc->$k, 0, 128);
                    break;
                }
            }
            $id = isset($doc->_id) && is_string($doc->_id) && $doc->_id !== '' ? $doc->_id : newId();
            if ($has($treatById, [$id])) continue;
            if ($sync !== null && $has($treatBySync, [$sync])) continue;
            if ($has($treatBySame, [$created, $type])) continue;
            $doc->_id = $id;
            $treatIns->execute([$id, $created, $type, $sync, enc($doc)]);
            $added++;
        }
        $db->commit();
        $state['treat_added'] = (int)($state['treat_added'] ?? 0) + $added;
        if (count($docs) === 0 || $oldest >= $before) {
            $state['treat_done'] = true;
            log_line('Treatments: finished, ' . $state['treat_added'] . ' imported in total');
        } else {
            $state['treat_before'] = $oldest;
            log_line("Treatments: +$added, now at " . gmdate('Y-m-d', intdiv($oldest, 1000)));
        }
        $saveState();
    }

    // ---------- loop status, the last N days only ----------
    $dsFrom = $dsDays > 0 ? $nowMs - $dsDays * 86400000 : PHP_INT_MAX;
    while (!empty($state['treat_done']) && empty($state['ds_done']) && time() < $budget) {
        $before = (int)($state['ds_before'] ?? $nowMs + 60000);
        if ($before <= $dsFrom) {
            $state['ds_done'] = true;
            log_line('Loop status: finished, ' . (int)($state['ds_added'] ?? 0) . ' imported in total');
            $saveState();
            break;
        }
        $iso = gmdate('Y-m-d\TH:i:s', intdiv($before, 1000)) . sprintf('.%03dZ', $before % 1000);
        $docs = nsGet($ns, $secret, '/api/v1/devicestatus.json', ['count' => 500, 'find' => ['created_at' => ['$lt' => $iso]]]);
        $added = 0;
        $oldest = $before;
        $db->beginTransaction();
        foreach ($docs as $doc) {
            if (!is_object($doc)) continue;
            $created = toMs($doc->created_at ?? null) ?? toMs($doc->mills ?? null);
            if ($created === null) continue;
            $oldest = min($oldest, $created);
            if ($created < $dsFrom) continue;
            $id = isset($doc->_id) && is_string($doc->_id) && $doc->_id !== '' ? $doc->_id : newId();
            // Loop uploads the same status to both servers: same moment = already here.
            if ($has($dsById, [$id]) || $has($dsNear, [$created - 5000, $created + 5000])) continue;
            $doc->_id = $id;
            $dsIns->execute([$id, $created, enc($doc)]);
            $added++;
        }
        $db->commit();
        $state['ds_added'] = (int)($state['ds_added'] ?? 0) + $added;
        if (count($docs) === 0 || $oldest >= $before) {
            $state['ds_done'] = true;
            log_line('Loop status: finished, ' . $state['ds_added'] . ' imported in total');
        } else {
            $state['ds_before'] = $oldest;
            log_line("Loop status: +$added, now at " . gmdate('Y-m-d', intdiv($oldest, 1000)));
        }
        $saveState();
    }

    if (!empty($state['ds_done'])) {
        $state['done'] = true;
        $saveState();
        log_line('Import finished: ' . (int)($state['entries_added'] ?? 0) . ' readings, '
            . (int)($state['treat_added'] ?? 0) . ' treatments, ' . (int)($state['ds_added'] ?? 0)
            . ' loop status records. You can delete the import cron job now.');
    }
} catch (Throwable $e) {
    if ($db->inTransaction()) $db->rollBack();
    fwrite(STDERR, date('Y-m-d H:i:s') . ' ' . $e->getMessage() . "\n");
    exit(1);
}
