<?php
// Glucose server: a small Nightscout-compatible API (v1) for Loop's
// "Monitor Glucose" service and for the Monitor Glucose app.
// Data is kept in MySQL; each record's full JSON is stored as text.

declare(strict_types=1);

require_once __DIR__ . '/eventlog.php';
// Optional parts: if one is missing or empty (a hosting virus scanner can
// empty a file by mistake), only that feature stops; readings keep working.
foreach (['loopremote.php', 'webapp.php'] as $optional) {
    if (is_file(__DIR__ . '/' . $optional)) require_once __DIR__ . '/' . $optional;
}

final class HttpError extends Exception
{
    public int $status;
    public function __construct(int $status, string $message)
    {
        parent::__construct($message);
        $this->status = $status;
    }
}

final class Server
{
    private PDO $db;
    private array $cfg;
    private int $level = 0; // 0 none, 1 read, 2 careportal, 3 full (api secret)

    public const READ = 1;
    public const CARE = 2;
    public const ADMIN = 3;

    public function __construct(array $cfg)
    {
        $this->cfg = $cfg;
        $this->db = new PDO($cfg['db_dsn'], $cfg['db_user'] ?? null, $cfg['db_pass'] ?? null, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
        $this->level = $this->authLevel();
    }

    // ------------------------------------------------------------ helpers

    public static function header(string $name): string
    {
        $key = 'HTTP_' . strtoupper(str_replace('-', '_', $name));
        if (!empty($_SERVER[$key])) return (string)$_SERVER[$key];
        if (!empty($_SERVER['REDIRECT_' . $key])) return (string)$_SERVER['REDIRECT_' . $key];
        if (function_exists('getallheaders')) {
            foreach (getallheaders() as $k => $v) {
                if (strcasecmp($k, $name) === 0) return (string)$v;
            }
        }
        return '';
    }

    private function authLevel(): int
    {
        $secret = (string)($this->cfg['api_secret'] ?? '');
        $hash = sha1($secret);
        $given = trim(self::header('api-secret'));
        if ($secret !== '' && $given !== '' && (hash_equals($hash, strtolower($given)) || hash_equals($secret, $given))) {
            return self::ADMIN;
        }
        $token = (string)($_GET['token'] ?? '');
        if ($token === '') {
            $auth = self::header('Authorization');
            if (stripos($auth, 'Bearer ') === 0) $token = trim(substr($auth, 7));
        }
        if ($token !== '') {
            if ($secret !== '' && (hash_equals($secret, $token) || hash_equals($hash, strtolower($token)))) return self::ADMIN;
            foreach (($this->cfg['care_tokens'] ?? []) as $t) {
                if ($t !== '' && hash_equals((string)$t, $token)) return self::CARE;
            }
            foreach (($this->cfg['read_tokens'] ?? []) as $t) {
                if ($t !== '' && hash_equals((string)$t, $token)) return self::READ;
            }
        }
        return 0;
    }

    private function need(int $level): void
    {
        if ($this->level < $level) throw new HttpError(401, 'Unauthorized');
    }

    /** New id in the same 24-hex-character shape as Nightscout's. */
    private static function newId(): string
    {
        return sprintf('%08x', time()) . bin2hex(random_bytes(8));
    }

    /** Milliseconds since 1970 from a number (ms or seconds) or a date text. */
    public static function toMs($v): ?int
    {
        if ($v === null || $v === '') return null;
        if (is_int($v) || is_float($v) || (is_string($v) && is_numeric($v))) {
            $n = (float)$v;
            if ($n < 100000000000) $n *= 1000; // given in seconds
            return (int)round($n);
        }
        if (is_string($v)) {
            try {
                $d = new DateTimeImmutable($v);
                return (int)$d->format('U') * 1000 + (int)$d->format('v');
            } catch (Exception $e) {
                return null;
            }
        }
        return null;
    }

    private static function iso(int $ms): string
    {
        return gmdate('Y-m-d\TH:i:s', intdiv($ms, 1000)) . sprintf('.%03dZ', $ms % 1000);
    }

    private static function body(): array
    {
        $raw = file_get_contents('php://input');
        if ($raw === false || $raw === '') return [];
        if (substr($raw, 0, 2) === "\x1f\x8b") $raw = (string)gzdecode($raw);
        $j = json_decode($raw, false);
        if ($j === null && trim($raw) !== 'null') throw new HttpError(400, 'Body is not valid JSON');
        if (is_object($j)) return [$j];
        if (is_array($j)) return array_values(array_filter($j, 'is_object'));
        return [];
    }

    private static function out($data, int $status = 200): void
    {
        http_response_code($status);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION);
    }

    private function count(int $default, int $max = 50000): int
    {
        $c = isset($_GET['count']) ? (int)$_GET['count'] : $default;
        return max(1, min($max, $c));
    }

    /** Adds "column op ?" conditions from find[field][$gte]=... style filters. */
    private function rangeFilter(array &$where, array &$args, string $column, $spec, bool $isDate = true): void
    {
        $ops = ['$gte' => '>=', '$gt' => '>', '$lte' => '<=', '$lt' => '<', '$eq' => '=', '$ne' => '<>'];
        if (!is_array($spec)) $spec = ['$eq' => $spec];
        foreach ($spec as $op => $val) {
            if (!isset($ops[$op])) continue;
            $v = $isDate ? self::toMs($val) : $val;
            if ($v === null) continue;
            $where[] = "$column {$ops[$op]} ?";
            $args[] = $v;
        }
    }

    private function fetchDocs(string $sql, array $args): array
    {
        $st = $this->db->prepare($sql);
        $st->execute($args);
        $out = [];
        foreach ($st->fetchAll() as $row) {
            $d = json_decode($row['doc'], false);
            if (is_object($d)) $out[] = $d;
        }
        return $out;
    }

    private function exists(string $table, string $id): bool
    {
        $st = $this->db->prepare("SELECT 1 FROM $table WHERE id = ?");
        $st->execute([$id]);
        return (bool)$st->fetchColumn();
    }

    private function save(string $table, string $id, array $cols): void
    {
        $names = array_keys($cols);
        if ($this->exists($table, $id)) {
            $set = implode(', ', array_map(fn($n) => "$n = ?", $names));
            $st = $this->db->prepare("UPDATE $table SET $set WHERE id = ?");
            $st->execute([...array_values($cols), $id]);
        } else {
            $ph = implode(', ', array_fill(0, count($names) + 1, '?'));
            $st = $this->db->prepare("INSERT INTO $table (id, " . implode(', ', $names) . ") VALUES ($ph)");
            $st->execute([$id, ...array_values($cols)]);
        }
    }

    private static function enc(object $doc): string
    {
        return json_encode($doc, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION);
    }

    private function cleanup(): void
    {
        $days = (int)($this->cfg['keep_days'] ?? 0);
        if ($days <= 0 || random_int(1, 200) !== 1) return;
        $cut = (time() - $days * 86400) * 1000;
        $this->db->prepare('DELETE FROM entries WHERE date_ms < ?')->execute([$cut]);
        $this->db->prepare('DELETE FROM treatments WHERE created_ms < ?')->execute([$cut]);
        $this->db->prepare('DELETE FROM devicestatus WHERE created_ms < ?')->execute([$cut]);
    }

    // ------------------------------------------------------------ routing

    public function handle(string $method, string $path): void
    {
        $path = '/' . trim($path, '/');
        $path = preg_replace('/\.json$/', '', $path);
        $parts = explode('/', trim($path, '/'));

        if ($method === 'OPTIONS') {
            self::out(['ok' => true]);
            return;
        }
        if ($path === '/') {
            header('Content-Type: text/html; charset=utf-8');
            echo '<!doctype html><meta charset="utf-8"><title>' . htmlspecialchars((string)$this->cfg['site_name']) .
                '</title><body style="font-family:system-ui;background:#0D1117;color:#E6EDF3;padding:40px">' .
                '<h1>' . htmlspecialchars((string)$this->cfg['site_name']) . '</h1><p>The glucose server is running.</p>';
            return;
        }
        // Loop remote commands, the same way as Nightscout (needs the API secret).
        if ($path === '/api/v2/notifications/loop') {
            if ($method !== 'POST') throw new HttpError(405, 'Method not allowed');
            $this->need(self::ADMIN);
            if (!class_exists('LoopRemote')) throw new HttpError(503, 'Remote commands are not installed on this server (lib/loopremote.php)');
            LoopRemote::http($this->db, $this->cfg);
            return;
        }
        if (($parts[0] ?? '') !== 'api' || ($parts[1] ?? '') !== 'v1') {
            throw new HttpError(404, 'Not found');
        }
        $res = $parts[2] ?? '';
        $sub = $parts[3] ?? '';

        switch ($res) {
            case 'status':
                $this->need(self::READ);
                self::out($this->status());
                return;
            case 'health':
                $this->need(self::READ);
                self::out($this->health());
                return;
            case 'verifyauth':
                self::out(['message' => [
                    'canRead' => $this->level >= self::READ,
                    'canWrite' => $this->level >= self::CARE,
                    'isAdmin' => $this->level >= self::ADMIN,
                    'message' => $this->level > 0 ? 'OK' : 'UNAUTHORIZED',
                ]]);
                return;
            case 'experiments':
                if ($sub === 'test') {
                    $this->need(self::ADMIN);
                    self::out(['status' => 'ok']);
                    return;
                }
                break;
            case 'entries':
                $this->entries($method, $sub);
                return;
            case 'treatments':
                $this->treatments($method, $sub);
                return;
            case 'devicestatus':
                $this->devicestatus($method, $sub);
                return;
            case 'logs':
                $this->logs($method, $sub);
                return;
            case 'profile':
            case 'profiles':
                $this->profile($method, $res === 'profiles' ? 'list' : $sub);
                return;
            case 'food':
                $this->food($method, $sub);
                return;
        }
        throw new HttpError(404, 'Not found');
    }

    /**
     * A problem with the job that brings in the readings (LibreLinkUp or the
     * Nightscout copy), in words for the apps; null when all is well.
     */
    private function feedProblem(): ?string
    {
        if (trim((string)($this->cfg['libre_email'] ?? '')) !== '') {
            [$name, $file] = ['LibreLinkUp', __DIR__ . '/.libre-status.json'];
        } elseif (trim((string)($this->cfg['nightscout_url'] ?? '')) !== '') {
            [$name, $file] = ['Nightscout copy', __DIR__ . '/.copy-status.json'];
        } else {
            return null;
        }
        if (!is_file($file)) return "$name: the job has not run yet. Check the cron job in cPanel";
        $s = json_decode((string)file_get_contents($file), true) ?: [];
        $idle = intdiv(time() - (int)($s['at'] ?? 0), 60);
        if ($idle >= 10) return "$name: the job has not run for $idle min. Check the cron job in cPanel";
        // One failed minute is normal (network); two in a row is a problem.
        if (empty($s['ok']) && (int)($s['fails'] ?? 0) >= 2) {
            $mins = intdiv(time() - (int)($s['since'] ?? time()), 60);
            $err = (string)($s['error'] ?? 'error');
            if (strncmp($err, $name, strlen($name)) !== 0) $err = "$name: $err";
            return $err . ($mins >= 2 ? " (for $mins min)" : '');
        }
        return null;
    }

    // ------------------------------------------------------------ health

    private function noteLoopCgmFetch(): void
    {
        $file = __DIR__ . '/.loop-cgm.json';
        $last = is_file($file) ? (int)(json_decode((string)file_get_contents($file), true)['at'] ?? 0) : 0;
        if (time() - $last < 30) return;
        @file_put_contents($file, json_encode(['at' => time()]), LOCK_EX);
        if (time() - $last > 900) {
            EventLog::add($this->db, 'job', 'Loop is reading its glucose from this server (backup CGM source)');
        }
    }

    /** GET a small JSON from the main Nightscout; null when it does not answer. */
    private static function mainGet(string $base, string $token, string $path): array
    {
        $url = rtrim($base, '/') . $path . ($token !== '' ? (strpos($path, '?') === false ? '?' : '&') . 'token=' . rawurlencode($token) : '');
        if (!function_exists('curl_init')) return [null, 'PHP curl is missing'];
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => 6,
            CURLOPT_CONNECTTIMEOUT => 4,
            CURLOPT_HTTPHEADER => ['Accept: application/json'],
        ]);
        $body = curl_exec($ch);
        $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $err = curl_error($ch);
        curl_close($ch);
        if ($body === false || $code === 0) return [null, $err !== '' ? $err : 'no answer'];
        if ($code !== 200) return [null, "error $code"];
        $j = json_decode((string)$body, true);
        return [is_array($j) ? $j : null, is_array($j) ? null : 'not JSON'];
    }

    /** The main Nightscout seen from here (checked at most once a minute). */
    private function mainStatus(): ?array
    {
        $base = trim((string)($this->cfg['main_nightscout_url'] ?? ''));
        if ($base === '') return null;
        if (!preg_match('#^https?://#i', $base)) $base = 'https://' . $base;
        $file = __DIR__ . '/.main-status.json';
        $old = is_file($file) ? (json_decode((string)file_get_contents($file), true) ?: []) : [];
        if (time() - (int)($old['checked'] ?? 0) < 60) return $old;
        $token = trim((string)($this->cfg['main_nightscout_token'] ?? ''));
        [$e, $err] = self::mainGet($base, $token, '/api/v1/entries/sgv.json?count=1');
        $s = ['checked' => time(), 'host' => (string)parse_url($base, PHP_URL_HOST), 'reachable' => $e !== null,
              'error' => $err, 'cgmLast' => null, 'loopLast' => null];
        if ($e !== null) {
            $s['cgmLast'] = isset($e[0]['date']) && is_numeric($e[0]['date']) ? (int)$e[0]['date'] : null;
            [$d] = self::mainGet($base, $token, '/api/v1/devicestatus.json?count=1');
            $t = $d[0]['loop']['timestamp'] ?? $d[0]['created_at'] ?? null;
            $s['loopLast'] = self::toMs($t);
        }
        @file_put_contents($file, json_encode($s), LOCK_EX);
        return $s;
    }

    /**
     * What the apps need to say WHY readings or loops are late: the LibreLinkUp
     * job here, the newest reading and loop here, the main Nightscout, and
     * whether Loop is reading its glucose from this server (backup).
     */
    private function health(): array
    {
        $libre = null;
        if (trim((string)($this->cfg['libre_email'] ?? '')) !== '') {
            $f = __DIR__ . '/.libre-status.json';
            $st = is_file($f) ? (json_decode((string)file_get_contents($f), true) ?: []) : [];
            $libre = ['lastRun' => isset($st['at']) ? (int)$st['at'] : null, 'ok' => !empty($st['ok']),
                      'fails' => (int)($st['fails'] ?? 0), 'error' => $st['error'] ?? null];
        }
        $cgm = $this->db->query("SELECT MAX(date_ms) FROM entries WHERE type = 'sgv'")->fetchColumn();
        $loop = $this->db->query('SELECT MAX(created_ms) FROM devicestatus')->fetchColumn();
        $lf = __DIR__ . '/.loop-cgm.json';
        $fetch = is_file($lf) ? (int)(json_decode((string)file_get_contents($lf), true)['at'] ?? 0) : 0;
        return [
            'serverTime' => (int)round(microtime(true) * 1000),
            'feedProblem' => $this->feedProblem(),
            'libre' => $libre,
            'cgmLast' => $cgm !== false && $cgm !== null ? (int)$cgm : null,
            'loopLast' => $loop !== false && $loop !== null ? (int)$loop : null,
            // Loop asked this server for glucose in the last 10 minutes.
            'loopCgmFromHere' => $fetch > 0 && time() - $fetch < 600,
            'loopCgmFetch' => $fetch > 0 ? $fetch * 1000 : null,
            'main' => $this->mainStatus(),
            'foodWaiting' => $this->foodHealth(),
        ];
    }

    /** Sends food changes still waiting for Nightscout; how many are still waiting. */
    private function foodHealth(): int
    {
        try {
            $this->foodTable();
            if ($this->foodQueued() === 0) return 0;
            $this->flushFood();
            return $this->foodQueued();
        } catch (Throwable $e) {
            return 0;
        }
    }

    private function status(): array
    {
        $units = ($this->cfg['units'] ?? 'mmol') === 'mmol' ? 'mmol' : 'mg/dl';
        return [
            'status' => 'ok',
            'feedProblem' => $this->feedProblem(),
            'name' => 'nightscout',
            'version' => '15.0.0-monitorglucose',
            'serverTime' => self::iso((int)round(microtime(true) * 1000)),
            'serverTimeEpoch' => (int)round(microtime(true) * 1000),
            'apiEnabled' => true,
            'careportalEnabled' => true,
            'settings' => [
                'units' => $units,
                'customTitle' => $this->cfg['site_name'] ?? 'Glucose',
                'enable' => ['careportal', 'iob', 'cob', 'basal', 'loop', 'pump', 'cage', 'sage', 'iage'],
            ],
            'authorized' => ['canRead' => $this->level >= self::READ, 'canWrite' => $this->level >= self::CARE],
        ];
    }

    // ------------------------------------------------------------ entries

    private function entries(string $method, string $sub): void
    {
        if ($method === 'GET') {
            $this->need(self::READ);
            $where = [];
            $args = [];
            $type = null;
            if (in_array($sub, ['sgv', 'mbg', 'cal'], true)) $type = $sub;
            $count = $this->count(10);
            if ($sub === 'current') {
                $type = 'sgv';
                $count = 1;
            }
            $find = $_GET['find'] ?? [];
            if ($sub === '' && $this->level >= self::ADMIN && is_array($find)
                && is_array($find['dateString'] ?? null)
                && isset($find['dateString']['$gte'], $find['dateString']['$lte'])) {
                // The exact request Loop's "Nightscout Remote CGM" makes: Loop is
                // reading its glucose from this server (the backup source).
                $this->noteLoopCgmFetch();
            }
            if (is_array($find)) {
                if (isset($find['date'])) $this->rangeFilter($where, $args, 'date_ms', $find['date']);
                if (isset($find['dateString'])) $this->rangeFilter($where, $args, 'date_ms', $find['dateString']);
                if (isset($find['type']) && is_string($find['type'])) $type = $find['type'];
            }
            if ($type !== null) {
                $where[] = 'type = ?';
                $args[] = $type;
            }
            $sql = 'SELECT doc FROM entries' . ($where ? ' WHERE ' . implode(' AND ', $where) : '') .
                ' ORDER BY date_ms DESC LIMIT ' . $count;
            $docs = $this->fetchDocs($sql, $args);
            self::out($sub === 'current' ? $docs : $docs);
            return;
        }
        if ($method === 'POST') {
            $this->need(self::ADMIN);
            $saved = [];
            foreach (self::body() as $doc) {
                $date = self::toMs($doc->date ?? null) ?? self::toMs($doc->dateString ?? null) ?? (int)round(microtime(true) * 1000);
                $type = (string)($doc->type ?? 'sgv');
                $doc->date = $date;
                if (empty($doc->dateString)) $doc->dateString = self::iso($date);
                $id = isset($doc->_id) && is_string($doc->_id) && $doc->_id !== '' ? $doc->_id : null;
                $isNew = true;
                if ($id === null) {
                    // Same reading sent twice: keep one.
                    $st = $this->db->prepare('SELECT id FROM entries WHERE type = ? AND date_ms = ?');
                    $st->execute([$type, $date]);
                    $found = $st->fetchColumn();
                    $isNew = !$found;
                    $id = $found ?: self::newId();
                } else {
                    $st = $this->db->prepare('SELECT 1 FROM entries WHERE id = ?');
                    $st->execute([$id]);
                    $isNew = !$st->fetchColumn();
                }
                $doc->_id = $id;
                $this->save('entries', $id, ['date_ms' => $date, 'type' => $type, 'doc' => self::enc($doc)]);
                if ($isNew && $type === 'sgv' && isset($doc->sgv) && is_numeric($doc->sgv)) {
                    $delay = (int)round((microtime(true) * 1000 - $date) / 1000);
                    EventLog::add($this->db, 'cgm', 'Reading ' . EventLog::bg((float)$doc->sgv, $this->units())
                        . ' from ' . (string)($doc->device ?? 'an uploader')
                        . ', measured ' . date('H:i:s', intdiv($date, 1000)) . ', arrived ' . EventLog::span($delay) . ' later');
                }
                $saved[] = $doc;
            }
            $this->cleanup();
            self::out($saved);
            return;
        }
        if ($method === 'DELETE' && $sub !== '') {
            $this->need(self::ADMIN);
            $this->db->prepare('DELETE FROM entries WHERE id = ?')->execute([$sub]);
            self::out(['n' => 1, 'ok' => 1]);
            return;
        }
        throw new HttpError(405, 'Method not allowed');
    }

    // ------------------------------------------------------------ treatments

    private function saveTreatment(object $doc, bool $dedupe): object
    {
        $created = self::toMs($doc->created_at ?? null) ?? self::toMs($doc->timestamp ?? null)
            ?? self::toMs($doc->mills ?? null) ?? (int)round(microtime(true) * 1000);
        if (empty($doc->created_at)) $doc->created_at = self::iso($created);
        $type = (string)($doc->eventType ?? '');
        $sync = null;
        foreach (['syncIdentifier', 'identifier', 'pumpId'] as $k) {
            if (isset($doc->$k) && is_scalar($doc->$k) && (string)$doc->$k !== '') {
                $sync = substr($k . ':' . (string)$doc->$k, 0, 128);
                break;
            }
        }
        $id = isset($doc->_id) && is_string($doc->_id) && $doc->_id !== '' ? $doc->_id : null;
        if ($id === null && $dedupe) {
            if ($sync !== null) {
                $st = $this->db->prepare('SELECT id FROM treatments WHERE sync_id = ?');
                $st->execute([$sync]);
                $id = $st->fetchColumn() ?: null;
            }
            if ($id === null) {
                // Nightscout's rule: same time and same event type = same treatment.
                $st = $this->db->prepare('SELECT id FROM treatments WHERE created_ms = ? AND event_type = ?');
                $st->execute([$created, $type]);
                $id = $st->fetchColumn() ?: null;
            }
        }
        $isNew = $id === null;
        $id = $id ?? self::newId();
        $doc->_id = $id;
        if ($isNew && $dedupe) $this->logTreatment($doc, $type, $created);
        $this->save('treatments', $id, [
            'created_ms' => $created,
            'event_type' => $type,
            'sync_id' => $sync,
            'doc' => self::enc($doc),
        ]);
        return $doc;
    }

    private function units(): string
    {
        return ($this->cfg['units'] ?? 'mmol') === 'mmol' ? 'mmol' : 'mg/dl';
    }

    /** One log line for a new bolus, carbs, override... (temp basals are in the loop lines). */
    private function logTreatment(object $doc, string $type, int $created): void
    {
        if ($type === 'Temp Basal' || $type === '') return;
        $parts = [];
        $ins = isset($doc->insulin) && is_numeric($doc->insulin) ? (float)$doc->insulin : 0;
        $carbs = isset($doc->carbs) && is_numeric($doc->carbs) ? (float)$doc->carbs : 0;
        $auto = !empty($doc->automatic) || !empty($doc->isSMB) || (($doc->type ?? '') === 'SMB');
        if ($ins > 0) $parts[] = 'Bolus ' . rtrim(rtrim(number_format($ins, 2), '0'), '.') . ' U' . ($auto ? ' (automatic)' : '');
        if ($carbs > 0) $parts[] = 'Carbs ' . round($carbs) . ' g';
        if (!$parts) {
            $name = trim((string)($doc->reason ?? $doc->notes ?? $doc->profile ?? ''));
            $dur = isset($doc->duration) && is_numeric($doc->duration) ? ' for ' . round((float)$doc->duration) . ' min' : '';
            $parts[] = $type . ($name !== '' ? " \"$name\"" : '') . $dur;
        }
        $by = trim((string)($doc->enteredBy ?? ''));
        EventLog::add($this->db, 'treatment', implode(' + ', $parts) . ' at ' . date('H:i', intdiv($created, 1000)) . ($by !== '' ? " (from $by)" : ''));
    }

    /** One log line for each loop run in a device status upload. */
    private function logLoop(object $doc, int $created): void
    {
        $l = $doc->loop ?? null;
        $o = $doc->openaps ?? null;
        if (!is_object($l) && !is_object($o)) return;
        $u = $this->units();
        $parts = [];
        $failed = '';
        if (is_object($l)) {
            $t = self::toMs($l->timestamp ?? null) ?? $created;
            $failed = trim((string)($l->failureReason ?? ''));
            $bg = $l->predicted->values[0] ?? null;
            if (is_numeric($bg)) $parts[] = 'BG ' . EventLog::bg((float)$bg, $u);
            if (isset($l->iob->iob) && is_numeric($l->iob->iob)) $parts[] = 'IOB ' . number_format((float)$l->iob->iob, 2) . ' U';
            if (isset($l->cob->cob) && is_numeric($l->cob->cob)) $parts[] = 'COB ' . round((float)$l->cob->cob) . ' g';
            $en = $l->enacted ?? null;
            if (is_object($en) && isset($en->rate)) {
                $parts[] = 'temp basal ' . number_format((float)$en->rate, 2) . ' U/h' . (isset($en->duration) ? ' for ' . round((float)$en->duration) . ' min' : '');
            }
            $rec = $l->automaticDoseRecommendation->bolusUnits ?? null;
            if (is_numeric($rec) && (float)$rec > 0) $parts[] = 'auto bolus ' . number_format((float)$rec, 2) . ' U';
        } else {
            $sug = $o->suggested ?? null;
            $en = $o->enacted ?? null;
            $t = self::toMs($en->timestamp ?? null) ?? self::toMs($sug->timestamp ?? null) ?? $created;
            if (isset($sug->bg) && is_numeric($sug->bg)) $parts[] = 'BG ' . EventLog::bg((float)$sug->bg, $u);
            $iob = is_object($o->iob ?? null) ? ($o->iob->iob ?? null) : null;
            if (is_numeric($iob)) $parts[] = 'IOB ' . number_format((float)$iob, 2) . ' U';
            if (isset($sug->COB) && is_numeric($sug->COB)) $parts[] = 'COB ' . round((float)$sug->COB) . ' g';
            if (is_object($en) && isset($en->rate)) $parts[] = 'temp basal ' . number_format((float)$en->rate, 2) . ' U/h';
            if (is_object($en) && isset($en->smb) && is_numeric($en->smb) && (float)$en->smb > 0) $parts[] = 'SMB ' . $en->smb . ' U';
        }
        // Time since the previous loop run.
        $file = __DIR__ . '/.last-loop.json';
        $prev = is_file($file) ? (int)((json_decode((string)file_get_contents($file), true) ?: [])['at'] ?? 0) : 0;
        if ($t <= $prev) return; // the same run uploaded again
        @file_put_contents($file, json_encode(['at' => $t]), LOCK_EX);
        $gap = $prev > 0 ? ' ' . EventLog::span(intdiv($t - $prev, 1000)) . ' after the last' : '';
        $device = (string)($doc->device ?? '');
        $head = $failed !== '' ? "Loop FAILED$gap: $failed" : "Loop ran$gap";
        EventLog::add($this->db, 'loop', $head . ($parts ? ' · ' . implode(' · ', $parts) : '') . ($device !== '' ? " ($device)" : ''), $t);
    }

    // ------------------------------------------------------------ logs

    private function logs(string $method, string $sub): void
    {
        if ($sub === 'settings') {
            if ($method === 'GET') {
                $this->need(self::READ);
                self::out(EventLog::settings());
                return;
            }
            if ($method === 'PUT' || $method === 'POST') {
                $this->need(self::ADMIN);
                $raw = json_decode((string)file_get_contents('php://input'), true);
                self::out(EventLog::saveSettings(is_array($raw) ? $raw : []));
                return;
            }
            throw new HttpError(405, 'Method not allowed');
        }
        $kinds = array_values(array_filter(explode(',', (string)($_GET['kind'] ?? ''))));
        if ($method === 'GET') {
            $this->need(self::READ);
            $before = isset($_GET['before']) && is_numeric($_GET['before']) ? (int)$_GET['before'] : null;
            self::out(EventLog::list($this->db, $kinds, $this->count(500, 5000), $before));
            return;
        }
        if ($method === 'DELETE') {
            $this->need(self::ADMIN);
            self::out(['n' => EventLog::clear($this->db, $kinds), 'ok' => 1]);
            return;
        }
        throw new HttpError(405, 'Method not allowed');
    }

    private function treatments(string $method, string $sub): void
    {
        if ($method === 'GET') {
            $this->need(self::READ);
            $where = [];
            $args = [];
            $find = $_GET['find'] ?? [];
            if (is_array($find)) {
                if (isset($find['created_at'])) $this->rangeFilter($where, $args, 'created_ms', $find['created_at']);
                if (isset($find['mills'])) $this->rangeFilter($where, $args, 'created_ms', $find['mills']);
                if (isset($find['eventType'])) {
                    $et = $find['eventType'];
                    if (is_array($et)) $et = $et['$eq'] ?? null;
                    if (is_string($et)) {
                        $where[] = 'event_type = ?';
                        $args[] = $et;
                    }
                }
                if (isset($find['_id']) && is_string($find['_id'])) {
                    $where[] = 'id = ?';
                    $args[] = $find['_id'];
                }
            }
            if ($sub !== '') {
                $where[] = 'id = ?';
                $args[] = $sub;
            }
            $sql = 'SELECT doc FROM treatments' . ($where ? ' WHERE ' . implode(' AND ', $where) : '') .
                ' ORDER BY created_ms DESC LIMIT ' . $this->count(100);
            self::out($this->fetchDocs($sql, $args));
            return;
        }
        if ($method === 'POST') {
            $this->need(self::CARE);
            $saved = [];
            foreach (self::body() as $doc) {
                $saved[] = $this->saveTreatment($doc, true);
            }
            $this->cleanup();
            self::out($saved);
            return;
        }
        if ($method === 'PUT') {
            $this->need(self::ADMIN);
            $saved = [];
            foreach (self::body() as $doc) {
                $saved[] = $this->saveTreatment($doc, true);
            }
            self::out(count($saved) === 1 ? $saved[0] : $saved);
            return;
        }
        if ($method === 'DELETE') {
            $this->need(self::ADMIN);
            if ($sub === '') throw new HttpError(400, 'Give the id to delete');
            $st = $this->db->prepare('DELETE FROM treatments WHERE id = ?');
            $st->execute([$sub]);
            self::out(['n' => $st->rowCount(), 'ok' => 1]);
            return;
        }
        throw new HttpError(405, 'Method not allowed');
    }

    // ------------------------------------------------------------ device status

    private function devicestatus(string $method, string $sub): void
    {
        if ($method === 'GET') {
            $this->need(self::READ);
            $where = [];
            $args = [];
            $find = $_GET['find'] ?? [];
            if (is_array($find) && isset($find['created_at'])) {
                $this->rangeFilter($where, $args, 'created_ms', $find['created_at']);
            }
            $sql = 'SELECT doc FROM devicestatus' . ($where ? ' WHERE ' . implode(' AND ', $where) : '') .
                ' ORDER BY created_ms DESC LIMIT ' . $this->count(10);
            self::out($this->fetchDocs($sql, $args));
            return;
        }
        if ($method === 'POST') {
            $this->need(self::ADMIN);
            $saved = [];
            foreach (self::body() as $doc) {
                $created = self::toMs($doc->created_at ?? null) ?? (int)round(microtime(true) * 1000);
                if (empty($doc->created_at)) $doc->created_at = self::iso($created);
                $id = isset($doc->_id) && is_string($doc->_id) && $doc->_id !== '' ? $doc->_id : self::newId();
                $doc->_id = $id;
                $this->save('devicestatus', $id, ['created_ms' => $created, 'doc' => self::enc($doc)]);
                $this->logLoop($doc, $created);
                $saved[] = $doc;
            }
            $this->cleanup();
            self::out($saved);
            return;
        }
        if ($method === 'DELETE' && $sub !== '') {
            $this->need(self::ADMIN);
            $this->db->prepare('DELETE FROM devicestatus WHERE id = ?')->execute([$sub]);
            self::out(['n' => 1, 'ok' => 1]);
            return;
        }
        throw new HttpError(405, 'Method not allowed');
    }

    // ------------------------------------------------------------ profile

    private function saveProfile(object $doc): object
    {
        $created = self::toMs($doc->created_at ?? null) ?? (int)round(microtime(true) * 1000);
        if (empty($doc->created_at)) $doc->created_at = self::iso($created);
        $start = self::toMs($doc->startDate ?? null) ?? $created;
        $id = isset($doc->_id) && is_string($doc->_id) && $doc->_id !== '' ? $doc->_id : self::newId();
        $doc->_id = $id;
        $this->save('profile', $id, ['created_ms' => $created, 'start_ms' => $start, 'doc' => self::enc($doc)]);
        return $doc;
    }

    private function profile(string $method, string $sub): void
    {
        if ($method === 'GET') {
            $this->need(self::READ);
            if ($sub === 'current') {
                $docs = $this->fetchDocs('SELECT doc FROM profile ORDER BY start_ms DESC LIMIT 1', []);
                if (!$docs) throw new HttpError(404, 'No profile yet');
                self::out($docs[0]);
                return;
            }
            $where = [];
            $args = [];
            $find = $_GET['find'] ?? [];
            if (is_array($find) && isset($find['startDate'])) {
                $this->rangeFilter($where, $args, 'start_ms', $find['startDate']);
            }
            $sql = 'SELECT doc FROM profile' . ($where ? ' WHERE ' . implode(' AND ', $where) : '') .
                ' ORDER BY start_ms DESC LIMIT ' . $this->count(10);
            self::out($this->fetchDocs($sql, $args));
            return;
        }
        if ($method === 'POST' || $method === 'PUT') {
            $this->need(self::ADMIN);
            $saved = array_map(fn($d) => $this->saveProfile($d), self::body());
            self::out($method === 'PUT' && count($saved) === 1 ? $saved[0] : $saved);
            return;
        }
        if ($method === 'DELETE' && $sub !== '') {
            $this->need(self::ADMIN);
            $this->db->prepare('DELETE FROM profile WHERE id = ?')->execute([$sub]);
            self::out(['n' => 1, 'ok' => 1]);
            return;
        }
        throw new HttpError(405, 'Method not allowed');
    }

    // ------------------------------------------------------------ food

    /*
     * Food list, like Nightscout's api/v1/food (the apps' Food screen).
     *
     * With 'main_nightscout_url' set (and 'food_from_main' not false), the
     * main Nightscout keeps the real list and this server passes reads and
     * changes through to it, so both addresses show the same foods. Every read
     * refreshes a local copy, served while Nightscout is down. Changes made
     * while it is down are kept here and queued, then sent to Nightscout as
     * soon as it answers again (on the next food request or health check).
     */
    private function foodTable(): void
    {
        static $done = false;
        if ($done) return;
        $sqlite = $this->db->getAttribute(PDO::ATTR_DRIVER_NAME) === 'sqlite';
        $this->db->exec($sqlite
            ? 'CREATE TABLE IF NOT EXISTS food (id VARCHAR(64) PRIMARY KEY, name VARCHAR(255) NOT NULL DEFAULT \'\', updated_ms BIGINT NOT NULL, doc TEXT NOT NULL)'
            : 'CREATE TABLE IF NOT EXISTS food (id VARCHAR(64) NOT NULL PRIMARY KEY, name VARCHAR(255) NOT NULL DEFAULT \'\', '
              . 'updated_ms BIGINT NOT NULL, doc LONGTEXT NOT NULL, KEY idx_food_name (name)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4');
        $this->db->exec($sqlite
            ? 'CREATE TABLE IF NOT EXISTS food_queue (seq INTEGER PRIMARY KEY AUTOINCREMENT, op VARCHAR(8) NOT NULL, id VARCHAR(64) NOT NULL, at_ms BIGINT NOT NULL)'
            : 'CREATE TABLE IF NOT EXISTS food_queue (seq BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, op VARCHAR(8) NOT NULL, id VARCHAR(64) NOT NULL, '
              . 'at_ms BIGINT NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4');
        $done = true;
    }

    /** Main Nightscout for the food list, or null (this server keeps its own list). */
    private function foodMain(): ?string
    {
        if (($this->cfg['food_from_main'] ?? true) === false) return null;
        $base = trim((string)($this->cfg['main_nightscout_url'] ?? ''));
        if ($base === '') return null;
        if (!preg_match('#^https?://#i', $base)) $base = 'https://' . $base;
        return rtrim($base, '/');
    }

    /**
     * A request to the main Nightscout's food list. Returns [HTTP code, JSON or
     * null]; code 0 when it cannot be reached. Uses 'main_nightscout_secret'
     * (its API secret, needed to change the list) or 'main_nightscout_token'.
     */
    private function nsFood(string $method, string $path, $body = null): array
    {
        $base = $this->foodMain();
        if ($base === null || !function_exists('curl_init')) return [0, null];
        $secret = (string)($this->cfg['main_nightscout_secret'] ?? '');
        $token = trim((string)($this->cfg['main_nightscout_token'] ?? ''));
        $url = $base . $path;
        if ($secret === '' && $token !== '') $url .= (strpos($path, '?') === false ? '?' : '&') . 'token=' . rawurlencode($token);
        $h = ['Accept: application/json', 'Content-Type: application/json'];
        if ($secret !== '') $h[] = 'api-secret: ' . sha1($secret);
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_TIMEOUT => 8,
            CURLOPT_CONNECTTIMEOUT => 4,
            CURLOPT_HTTPHEADER => $h,
        ]);
        if ($body !== null) curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
        $res = curl_exec($ch);
        $code = $res === false ? 0 : (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        // A server error or a timeout counts as "down": the change is queued.
        if ($code >= 500) $code = 0;
        $j = is_string($res) ? json_decode($res, false) : null;
        return [$code, $j];
    }

    private function saveFood(object $doc): object
    {
        $id = isset($doc->_id) && is_string($doc->_id) && preg_match('/^[A-Za-z0-9_-]{1,64}$/', $doc->_id) ? $doc->_id : self::newId();
        $doc->_id = $id;
        if (empty($doc->type)) $doc->type = 'food';
        $now = (int)round(microtime(true) * 1000);
        if (empty($doc->created_at)) $doc->created_at = self::iso($now);
        $this->save('food', $id, ['name' => substr((string)($doc->name ?? ''), 0, 250), 'updated_ms' => $now, 'doc' => self::enc($doc)]);
        return $doc;
    }

    private function queueFood(string $op, string $id): void
    {
        // One entry per food: the latest change is what gets sent.
        $this->db->prepare('DELETE FROM food_queue WHERE id = ?')->execute([$id]);
        $st = $this->db->prepare('INSERT INTO food_queue (op, id, at_ms) VALUES (?, ?, ?)');
        $st->execute([$op, $id, (int)round(microtime(true) * 1000)]);
    }

    private function foodQueued(): int
    {
        return (int)$this->db->query('SELECT COUNT(*) FROM food_queue')->fetchColumn();
    }

    /** Sends the queued changes to Nightscout; false when it is still down. */
    private function flushFood(): bool
    {
        if ($this->foodMain() === null) return true;
        $rows = $this->db->query('SELECT seq, op, id FROM food_queue ORDER BY seq')->fetchAll();
        if (!$rows) return true;
        $sent = 0;
        foreach ($rows as $r) {
            $id = (string)$r['id'];
            $ok = false;
            if ($r['op'] === 'delete') {
                [$code] = $this->nsFood('DELETE', '/api/v1/food/' . rawurlencode($id));
                if ($code === 0) break;
                $ok = true; // gone there too, or never there (404)
            } else {
                $docs = $this->fetchDocs('SELECT doc FROM food WHERE id = ?', [$id]);
                if (!$docs) {
                    $ok = true;
                } elseif (strncmp($id, 'local-', 6) === 0) {
                    // Made here while Nightscout was down: create it there; it gets Nightscout's id.
                    $d = $docs[0];
                    unset($d->_id);
                    [$code, $j] = $this->nsFood('POST', '/api/v1/food', $d);
                    if ($code === 0) break;
                    $new = is_array($j) ? ($j[0]->_id ?? null) : ($j->_id ?? null);
                    if ($code >= 200 && $code < 300 && is_string($new) && $new !== '') {
                        $d->_id = $new;
                        $this->db->prepare('DELETE FROM food WHERE id = ?')->execute([$id]);
                        $this->saveFood($d);
                        $ok = true;
                    }
                } else {
                    [$code] = $this->nsFood('PUT', '/api/v1/food', $docs[0]);
                    if ($code === 0) break;
                    $ok = $code >= 200 && $code < 300;
                }
            }
            if (!$ok) break; // refused (permission): keep it queued, try again later
            $this->db->prepare('DELETE FROM food_queue WHERE seq = ?')->execute([$r['seq']]);
            $sent++;
        }
        if ($sent > 0) {
            EventLog::add($this->db, 'job', "Food list: $sent change" . ($sent > 1 ? 's' : '') . ' made while Nightscout was down sent to it');
        }
        return $this->foodQueued() === 0;
    }

    /** The food list: from Nightscout (refreshing the local copy), else the local copy. */
    private function foodList(): array
    {
        if ($this->foodMain() !== null) {
            $flushed = $this->flushFood();
            [$code, $j] = $this->nsFood('GET', '/api/v1/food.json?count=20000');
            if ($code === 200 && is_array($j)) {
                // Keep foods still waiting to be sent (when the queue could not be emptied).
                $keep = [];
                if (!$flushed) {
                    foreach ($this->db->query('SELECT id FROM food_queue')->fetchAll() as $q) $keep[(string)$q['id']] = true;
                }
                $this->db->beginTransaction();
                try {
                    $all = $this->db->query('SELECT id FROM food')->fetchAll();
                    $del = $this->db->prepare('DELETE FROM food WHERE id = ?');
                    foreach ($all as $row) if (!isset($keep[(string)$row['id']])) $del->execute([$row['id']]);
                    foreach ($j as $d) {
                        if (is_object($d) && isset($d->_id) && !isset($keep[(string)$d->_id])) $this->saveFood($d);
                    }
                    $this->db->commit();
                } catch (Throwable $e) {
                    $this->db->rollBack();
                    throw $e;
                }
            }
        }
        return $this->fetchDocs('SELECT doc FROM food ORDER BY name LIMIT ' . $this->count(5000, 20000), []);
    }

    private function food(string $method, string $sub): void
    {
        $this->foodTable();
        $main = $this->foodMain() !== null;
        if ($method === 'GET') {
            $this->need(self::READ);
            if ($sub !== '' && $sub !== 'quickpicks' && $sub !== 'regular') {
                $docs = $this->fetchDocs('SELECT doc FROM food WHERE id = ?', [$sub]);
                if (!$docs) throw new HttpError(404, 'Not found');
                self::out($docs[0]);
                return;
            }
            $docs = $this->foodList();
            if ($sub === 'quickpicks') $docs = array_values(array_filter($docs, fn($d) => ($d->type ?? '') === 'quickpick'));
            if ($sub === 'regular') $docs = array_values(array_filter($docs, fn($d) => ($d->type ?? 'food') === 'food'));
            self::out($docs);
            return;
        }
        if ($method === 'POST' || $method === 'PUT') {
            $this->need(self::CARE);
            $out = [];
            foreach (self::body() as $d) {
                $isNew = $method === 'POST' && empty($d->_id);
                if ($main) {
                    if ($isNew) {
                        [$code, $j] = $this->nsFood('POST', '/api/v1/food', $d);
                        $new = is_array($j) ? ($j[0]->_id ?? null) : ($j->_id ?? null);
                        if ($code >= 200 && $code < 300 && is_string($new)) {
                            $d->_id = $new;
                            $out[] = $this->saveFood($d);
                            continue;
                        }
                        if ($code !== 0) throw new HttpError(502, "Nightscout refused the food (HTTP $code): check main_nightscout_secret in config.php");
                        // Nightscout down: keep it here with a temporary id and send it later.
                        $d->_id = 'local-' . self::newId();
                        $out[] = $this->saveFood($d);
                        $this->queueFood('save', $d->_id);
                        continue;
                    }
                    $id = (string)($d->_id ?? '');
                    if (strncmp($id, 'local-', 6) !== 0) {
                        [$code] = $this->nsFood('PUT', '/api/v1/food', $d);
                        if ($code >= 200 && $code < 300) {
                            $out[] = $this->saveFood($d);
                            continue;
                        }
                        if ($code !== 0) throw new HttpError(502, "Nightscout refused the change (HTTP $code): check main_nightscout_secret in config.php");
                    }
                    $out[] = $this->saveFood($d);
                    $this->queueFood('save', (string)$d->_id);
                    continue;
                }
                $out[] = $this->saveFood($d);
            }
            self::out($method === 'PUT' && count($out) === 1 ? $out[0] : $out);
            return;
        }
        if ($method === 'DELETE' && $sub !== '') {
            $this->need(self::CARE);
            if ($main) {
                if (strncmp($sub, 'local-', 6) === 0) {
                    // Never reached Nightscout: just forget it.
                    $this->db->prepare('DELETE FROM food_queue WHERE id = ?')->execute([$sub]);
                } else {
                    [$code] = $this->nsFood('DELETE', '/api/v1/food/' . rawurlencode($sub));
                    if ($code === 0) {
                        $this->queueFood('delete', $sub);
                    } elseif ($code >= 400 && $code !== 404) {
                        throw new HttpError(502, "Nightscout refused to delete it (HTTP $code): check main_nightscout_secret in config.php");
                    }
                }
            }
            $st = $this->db->prepare('DELETE FROM food WHERE id = ?');
            $st->execute([$sub]);
            self::out(['n' => $st->rowCount(), 'ok' => 1]);
            return;
        }
        throw new HttpError(405, 'Method not allowed');
    }

    // ------------------------------------------------------------ entry point

    public static function run(array $cfg): void
    {
        EventLog::timezone($cfg);
        header('Access-Control-Allow-Origin: *');
        header('Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS');
        header('Access-Control-Allow-Headers: Content-Type, Accept, api-secret, Authorization');
        $method = strtoupper($_SERVER['REQUEST_METHOD'] ?? 'GET');
        $path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
        // Everything outside /api is the web app (same as the phone app), so this
        // address shows it. No database needed for that.
        $isApi = $path === '/api' || strncmp($path, '/api/', 5) === 0;
        if (!$isApi && ($method === 'GET' || $method === 'HEAD') && class_exists('WebApp') && WebApp::serve($cfg, rawurldecode($path), $method)) {
            return;
        }
        try {
            (new Server($cfg))->handle($method, rawurldecode($path));
        } catch (HttpError $e) {
            self::out(['status' => $e->status, 'message' => $e->getMessage()], $e->status);
        } catch (Throwable $e) {
            error_log('glucose server: ' . $e->getMessage());
            self::out(['status' => 500, 'message' => 'Server error'], 500);
        }
    }
}
