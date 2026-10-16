<?php
// Copies new CGM readings from your Nightscout into this server.
//
// Why: when Loop's CGM is "Nightscout", Loop never uploads those readings to any
// service (they came from Nightscout), so this server would have treatments and
// loop status but no glucose. This script fetches them from Nightscout instead.
//
// Run it every minute with a cPanel cron job (see README.md):
//   /usr/local/bin/php /home/CPANELUSER/bg.inforap.com/lib/copy.php
// It only runs from the command line (cron), never from a browser.
declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit;
}

$cfg = require __DIR__ . '/../config.php';

// The last result, shown by the apps when something is wrong (see server.php).
function saveStatus(?string $error, int $added = 0): void
{
    $file = __DIR__ . '/.copy-status.json';
    $old = is_file($file) ? (json_decode((string)file_get_contents($file), true) ?: []) : [];
    $s = $error === null
        ? ['ok' => true, 'at' => time(), 'added' => $added, 'fails' => 0]
        : ['ok' => false, 'at' => time(), 'error' => $error, 'fails' => (int)($old['fails'] ?? 0) + 1,
           'since' => (int)(($old['ok'] ?? true) ? time() : ($old['since'] ?? time()))];
    @file_put_contents($file, json_encode($s), LOCK_EX);
}
$ns = rtrim(trim((string)($cfg['nightscout_url'] ?? '')), '/');
if ($ns === '') {
    exit(0); // copying is turned off
}
if (!preg_match('#^https?://#', $ns)) $ns = 'https://' . $ns;
$secret = trim((string)($cfg['nightscout_secret'] ?? ''));
$firstHours = (int)($cfg['copy_first_hours'] ?? 30);

// One copy at a time, even if a run takes longer than a minute.
$lock = fopen(sys_get_temp_dir() . '/glucose-copy-' . md5(__DIR__) . '.lock', 'c');
if ($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) exit(0);

$db = new PDO($cfg['db_dsn'], $cfg['db_user'] ?? null, $cfg['db_pass'] ?? null, [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
]);

// From the newest reading already here (10 minutes back, to catch late ones),
// or the last [copy_first_hours] hours the first time.
$last = (int)$db->query("SELECT COALESCE(MAX(date_ms), 0) FROM entries WHERE type = 'sgv'")->fetchColumn();
$nowMs = (int)round(microtime(true) * 1000);
$from = $last > 0 ? $last - 10 * 60000 : $nowMs - $firstHours * 3600000;

$url = $ns . '/api/v1/entries/sgv.json?' . http_build_query(['count' => 3000, 'find' => ['date' => ['$gt' => $from]]]);
$headers = ['Accept: application/json'];
if ($secret !== '') $headers[] = 'api-secret: ' . sha1($secret);

$ch = curl_init($url);
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HTTPHEADER => $headers,
    CURLOPT_TIMEOUT => 40,
    CURLOPT_CONNECTTIMEOUT => 10,
    CURLOPT_FOLLOWLOCATION => true,
    CURLOPT_MAXREDIRS => 3,
]);
$body = curl_exec($ch);
$code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
$err = curl_error($ch);
curl_close($ch);

if ($body === false || $code !== 200) {
    fwrite(STDERR, date('Y-m-d H:i:s ') . "Nightscout did not answer: HTTP $code $err\n");
    saveStatus($code === 401 || $code === 403 ? 'Nightscout refused access: check nightscout_secret' : "Nightscout did not answer (HTTP $code)");
    exit(1);
}
$docs = json_decode($body);
if (!is_array($docs)) {
    fwrite(STDERR, date('Y-m-d H:i:s ') . "Nightscout sent something that is not a list of readings\n");
    saveStatus('Nightscout sent something that is not a list of readings');
    exit(1);
}

// Within 30 seconds counts as the same reading (another source may stamp it slightly differently).
$find = $db->prepare('SELECT id FROM entries WHERE type = ? AND date_ms BETWEEN ? AND ?');
$byId = $db->prepare('SELECT 1 FROM entries WHERE id = ?');
$insert = $db->prepare('INSERT INTO entries (id, date_ms, type, doc) VALUES (?, ?, ?, ?)');
$update = $db->prepare('UPDATE entries SET doc = ? WHERE id = ?');

$added = 0;
$db->beginTransaction();
foreach ($docs as $doc) {
    if (!is_object($doc) || !isset($doc->date) || !is_numeric($doc->date) || !isset($doc->sgv)) continue;
    $date = (int)$doc->date;
    $type = (string)($doc->type ?? 'sgv');
    // Same reading already here (same type and time): keep one, with the newest content.
    $find->execute([$type, $date - 30000, $date + 30000]);
    $id = $find->fetchColumn();
    $json = json_encode($doc, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION);
    if ($id) {
        $update->execute([$json, $id]);
        continue;
    }
    $id = isset($doc->_id) && is_string($doc->_id) && $doc->_id !== '' ? $doc->_id : bin2hex(random_bytes(12));
    $byId->execute([$id]);
    if ($byId->fetchColumn()) $id = bin2hex(random_bytes(12));
    $doc->_id = $id;
    $insert->execute([$id, $date, $type, json_encode($doc, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION)]);
    $added++;
}
$db->commit();
saveStatus(null, $added);
echo date('Y-m-d H:i:s ') . "Copied $added new reading(s) from Nightscout\n";
