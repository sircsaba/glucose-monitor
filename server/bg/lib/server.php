<?php
// Glucose server: a small Nightscout-compatible API (v1) for Loop's
// "Monitor Glucose" service and for the Glucose Monitor app.
// Data is kept in MySQL; each record's full JSON is stored as text.

declare(strict_types=1);

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
            case 'profile':
            case 'profiles':
                $this->profile($method, $res === 'profiles' ? 'list' : $sub);
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
                if ($id === null) {
                    // Same reading sent twice: keep one.
                    $st = $this->db->prepare('SELECT id FROM entries WHERE type = ? AND date_ms = ?');
                    $st->execute([$type, $date]);
                    $id = $st->fetchColumn() ?: self::newId();
                }
                $doc->_id = $id;
                $this->save('entries', $id, ['date_ms' => $date, 'type' => $type, 'doc' => self::enc($doc)]);
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
        $id = $id ?? self::newId();
        $doc->_id = $id;
        $this->save('treatments', $id, [
            'created_ms' => $created,
            'event_type' => $type,
            'sync_id' => $sync,
            'doc' => self::enc($doc),
        ]);
        return $doc;
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

    // ------------------------------------------------------------ web app

    /**
     * Shows the browser version of the Glucose Monitor app at this server's own
     * address. The app is published once on GitHub Pages; this fetches its files,
     * keeps a copy for one minute in lib/.webcache/, and serves them from here.
     * 'web_app_url' => 'none' in config.php turns it off. Returns false when the
     * file can't be served (then '/' shows the plain status page).
     */
    private static function serveWebApp(array $cfg, string $path, string $method): bool
    {
        $base = trim((string)($cfg['web_app_url'] ?? 'https://sircsaba.github.io/glucose-monitor'));
        if ($base === '' || strtolower($base) === 'none') return false;
        $base = rtrim($base, '/');
        if ($path === '/flutter_service_worker.js') {
            // Removes an old offline copy of the app from browsers that kept one.
            header('Content-Type: text/javascript; charset=utf-8');
            header('Cache-Control: no-store');
            if ($method !== 'HEAD') {
                echo "self.addEventListener('install', () => self.skipWaiting());\n"
                    . "self.addEventListener('activate', (e) => e.waitUntil((async () => {\n"
                    . "  for (const k of await caches.keys()) await caches.delete(k);\n"
                    . "  await self.registration.unregister();\n"
                    . "})()));\n";
            }
            return true;
        }
        $file = $path === '/' ? '/index.html' : $path;
        if (strpos($file, '..') !== false || !preg_match('#^/[A-Za-z0-9._/-]+$#', $file)) return false;

        $dir = __DIR__ . '/.webcache';
        if (!is_dir($dir)) @mkdir($dir, 0700, true);
        $key = $dir . '/' . sha1($base . $file);
        $fresh = is_file($key . '.bin') && is_file($key . '.type') && filemtime($key . '.bin') > time() - 60;

        if (!$fresh && function_exists('curl_init')) {
            $ch = curl_init($base . $file);
            curl_setopt_array($ch, [
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_FOLLOWLOCATION => true,
                CURLOPT_MAXREDIRS => 3,
                CURLOPT_TIMEOUT => 30,
                CURLOPT_CONNECTTIMEOUT => 10,
                CURLOPT_HEADER => false,
            ]);
            $body = curl_exec($ch);
            $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
            $type = (string)curl_getinfo($ch, CURLINFO_CONTENT_TYPE);
            curl_close($ch);
            if ($body !== false && $code === 200) {
                @file_put_contents($key . '.bin', $body, LOCK_EX);
                @file_put_contents($key . '.type', $type ?: 'application/octet-stream', LOCK_EX);
                $fresh = true;
            } elseif ($code === 404) {
                @unlink($key . '.bin');
                return false;
            }
            // GitHub not reachable: an older copy is served if there is one.
        }
        if (!is_file($key . '.bin') || !is_file($key . '.type')) return false;

        $etag = '"' . md5_file($key . '.bin') . '"';
        header('Content-Type: ' . trim((string)file_get_contents($key . '.type')));
        header('Cache-Control: no-cache');
        header('ETag: ' . $etag);
        header('X-Content-Type-Options: nosniff');
        if (trim((string)($_SERVER['HTTP_IF_NONE_MATCH'] ?? '')) === $etag) {
            http_response_code(304);
            return true;
        }
        header('Content-Length: ' . filesize($key . '.bin'));
        if ($method !== 'HEAD') readfile($key . '.bin');
        return true;
    }

    // ------------------------------------------------------------ entry point

    public static function run(array $cfg): void
    {
        header('Access-Control-Allow-Origin: *');
        header('Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS');
        header('Access-Control-Allow-Headers: Content-Type, Accept, api-secret, Authorization');
        $method = strtoupper($_SERVER['REQUEST_METHOD'] ?? 'GET');
        $path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
        // Everything outside /api is the web app (same as the phone app), so this
        // address shows it. No database needed for that.
        $isApi = $path === '/api' || strncmp($path, '/api/', 5) === 0;
        if (!$isApi && ($method === 'GET' || $method === 'HEAD') && self::serveWebApp($cfg, rawurldecode($path), $method)) {
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
