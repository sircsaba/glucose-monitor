<?php
// Event log: one line per thing that happens, so you can check the whole chain
// works (a reading arrives, the heartbeat push goes out, Loop runs).
//
// Kinds:  cgm (new reading)  push (heartbeat sent to Loop)  loop (Loop ran)
//         treatment (bolus, carbs, override)  remote (remote command sent to Loop)
//         job (LibreLinkUp / Nightscout copy problems)
//
// Used by server.php, libre.php, copy.php and loop-heartbeat.php. The settings
// (logging on/off, which kinds, how many days to keep) are in lib/.eventlog.json
// and are changed from the apps (Settings › Logs).
declare(strict_types=1);

final class EventLog
{
    public const KINDS = ['cgm', 'push', 'loop', 'treatment', 'remote', 'job'];
    private static bool $ready = false;
    private static ?array $settings = null;

    private static function file(): string
    {
        return __DIR__ . '/.eventlog.json';
    }

    /** ['on' => bool, 'kinds' => [kind => bool], 'keep_days' => int] */
    public static function settings(): array
    {
        if (self::$settings !== null) return self::$settings;
        $s = is_file(self::file()) ? (json_decode((string)file_get_contents(self::file()), true) ?: []) : [];
        $kinds = [];
        foreach (self::KINDS as $k) $kinds[$k] = (bool)($s['kinds'][$k] ?? true);
        return self::$settings = [
            'on' => (bool)($s['on'] ?? true),
            'kinds' => $kinds,
            'keep_days' => max(1, min(365, (int)($s['keep_days'] ?? 14))),
        ];
    }

    public static function saveSettings(array $in): array
    {
        $cur = self::settings();
        if (array_key_exists('on', $in)) $cur['on'] = (bool)$in['on'];
        if (isset($in['kinds']) && is_array($in['kinds'])) {
            foreach (self::KINDS as $k) {
                if (array_key_exists($k, $in['kinds'])) $cur['kinds'][$k] = (bool)$in['kinds'][$k];
            }
        }
        if (isset($in['keep_days'])) $cur['keep_days'] = max(1, min(365, (int)$in['keep_days']));
        @file_put_contents(self::file(), json_encode($cur, JSON_PRETTY_PRINT), LOCK_EX);
        self::$settings = $cur;
        return $cur;
    }

    public static function enabled(string $kind): bool
    {
        $s = self::settings();
        return $s['on'] && ($s['kinds'][$kind] ?? false);
    }

    public static function ensure(PDO $db): void
    {
        if (self::$ready) return;
        if ($db->getAttribute(PDO::ATTR_DRIVER_NAME) === 'sqlite') {
            $db->exec('CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, at_ms BIGINT NOT NULL, kind VARCHAR(16) NOT NULL, msg TEXT NOT NULL)');
        } else {
            $db->exec('CREATE TABLE IF NOT EXISTS events (
                id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
                at_ms BIGINT NOT NULL,
                kind VARCHAR(16) NOT NULL,
                msg TEXT NOT NULL,
                KEY idx_events_at (at_ms),
                KEY idx_events_kind (kind, at_ms)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4');
        }
        self::$ready = true;
    }

    /** Adds one line (if logging is on for this kind). Never throws. */
    public static function add(PDO $db, string $kind, string $msg, ?int $atMs = null): void
    {
        if (!self::enabled($kind)) return;
        try {
            self::ensure($db);
            $at = $atMs ?? (int)round(microtime(true) * 1000);
            $db->prepare('INSERT INTO events (at_ms, kind, msg) VALUES (?, ?, ?)')->execute([$at, $kind, mb_substr($msg, 0, 1000)]);
            // Now and then, drop lines older than the days to keep.
            if (random_int(1, 100) === 1) {
                $cut = (time() - self::settings()['keep_days'] * 86400) * 1000;
                $db->prepare('DELETE FROM events WHERE at_ms < ?')->execute([$cut]);
            }
        } catch (Throwable $e) {
            error_log('eventlog: ' . $e->getMessage());
        }
    }

    /** Newest first. */
    public static function list(PDO $db, array $kinds, int $count, ?int $beforeMs = null): array
    {
        self::ensure($db);
        $where = [];
        $args = [];
        $kinds = array_values(array_intersect($kinds, self::KINDS));
        if ($kinds) {
            $where[] = 'kind IN (' . implode(',', array_fill(0, count($kinds), '?')) . ')';
            array_push($args, ...$kinds);
        }
        if ($beforeMs !== null) {
            $where[] = 'at_ms < ?';
            $args[] = $beforeMs;
        }
        $sql = 'SELECT id, at_ms, kind, msg FROM events' . ($where ? ' WHERE ' . implode(' AND ', $where) : '')
            . ' ORDER BY at_ms DESC, id DESC LIMIT ' . max(1, min(5000, $count));
        $st = $db->prepare($sql);
        $st->execute($args);
        $out = [];
        foreach ($st->fetchAll(PDO::FETCH_ASSOC) as $r) {
            $out[] = ['id' => (int)$r['id'], 'at' => (int)$r['at_ms'], 'kind' => $r['kind'], 'msg' => $r['msg']];
        }
        return $out;
    }

    /** Deletes all lines, or only those of [kinds]. Returns how many. */
    public static function clear(PDO $db, array $kinds): int
    {
        self::ensure($db);
        $kinds = array_values(array_intersect($kinds, self::KINDS));
        if (!$kinds) return (int)$db->exec('DELETE FROM events');
        $st = $db->prepare('DELETE FROM events WHERE kind IN (' . implode(',', array_fill(0, count($kinds), '?')) . ')');
        $st->execute($kinds);
        return $st->rowCount();
    }

    /** Uses the time zone from config.php ('timezone'), Montreal / Toronto time by default. */
    public static function timezone(array $cfg): void
    {
        $tz = (string)($cfg['timezone'] ?? 'America/Toronto');
        if ($tz !== '' && in_array($tz, timezone_identifiers_list(), true)) date_default_timezone_set($tz);
    }

    /** Glucose in the server's units, e.g. "5.4 mmol/L" or "98 mg/dL". */
    public static function bg(float $mg, string $units): string
    {
        return $units === 'mmol' ? number_format($mg / 18.0182, 1) . ' mmol/L' : (string)round($mg) . ' mg/dL';
    }

    /** "45 s", "3 min 05 s", "1 h 12 min". */
    public static function span(int $sec): string
    {
        $sec = max(0, $sec);
        if ($sec < 60) return "$sec s";
        if ($sec < 3600) return intdiv($sec, 60) . ' min ' . str_pad((string)($sec % 60), 2, '0', STR_PAD_LEFT) . ' s';
        return intdiv($sec, 3600) . ' h ' . intdiv($sec % 3600, 60) . ' min';
    }
}
