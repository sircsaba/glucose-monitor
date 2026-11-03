<?php
// Monitor Glucose server: sends readings to the main Nightscout when it is
// missing them (for example while Loop reads its glucose from this server, the
// backup source, Loop does not upload them). Called by the LibreLinkUp job
// (libre.php) at most every 5 minutes. Optional: delete this file to turn it
// off, or set 'readings_to_main' => false in config.php.

declare(strict_types=1);

final class MainCopy
{
    public static function run(array $cfg, PDO $db): ?string
    {
        if (($cfg['readings_to_main'] ?? true) === false) return null;
        $base = rtrim(trim((string)($cfg['main_nightscout_url'] ?? '')), '/');
        $secret = trim((string)($cfg['main_nightscout_secret'] ?? ''));
        if ($base === '' || $secret === '' || !function_exists('curl_init')) return null;
        if (!preg_match('#^https?://#i', $base)) $base = 'https://' . $base;
        $state = __DIR__ . '/.main-copy.json';
        $last = is_file($state) ? (int)(json_decode((string)file_get_contents($state), true)['at'] ?? 0) : 0;
        if (time() - $last < 290) return null;
        @file_put_contents($state, json_encode(['at' => time()]), LOCK_EX);

        $now = (int)round(microtime(true) * 1000);
        $since = $now - 3 * 3600 * 1000;
        // Nightscout's own uploader gets 6 minutes to bring a reading itself.
        $until = $now - 6 * 60 * 1000;
        [$code, $ns] = self::call($base, $secret, 'GET', '/api/v1/entries/sgv.json?count=100&find[date][$gte]=' . $since);
        if ($code !== 200 || !is_array($ns)) return null;
        $have = [];
        foreach ($ns as $e) {
            if (isset($e['date']) && is_numeric($e['date'])) $have[] = (int)$e['date'];
        }
        $st = $db->prepare("SELECT doc FROM entries WHERE type = 'sgv' AND date_ms BETWEEN ? AND ? ORDER BY date_ms");
        $st->execute([$since, $until]);
        $send = [];
        foreach ($st->fetchAll(PDO::FETCH_COLUMN) as $raw) {
            $d = json_decode((string)$raw, true);
            if (!is_array($d) || !isset($d['date'], $d['sgv'])) continue;
            $t = (int)$d['date'];
            $near = false;
            foreach ($have as $h) {
                if (abs($h - $t) <= 60000) {
                    $near = true;
                    break;
                }
            }
            if ($near) continue;
            $send[] = [
                'type' => 'sgv',
                'sgv' => (int)$d['sgv'],
                'date' => $t,
                'dateString' => $d['dateString'] ?? gmdate('Y-m-d\TH:i:s.000\Z', intdiv($t, 1000)),
                'direction' => $d['direction'] ?? 'NONE',
                'device' => 'monitor-glucose-copy',
            ];
        }
        if (!$send) return null;
        [$c2] = self::call($base, $secret, 'POST', '/api/v1/entries', $send);
        if ($c2 < 200 || $c2 >= 300) return "Readings to Nightscout: refused (HTTP $c2)";
        return count($send) . ' reading' . (count($send) > 1 ? 's' : '') . ' sent to Nightscout (it did not have them)';
    }

    private static function call(string $base, string $secret, string $method, string $path, $body = null): array
    {
        $ch = curl_init($base . $path);
        $h = ['Accept: application/json', 'api-secret: ' . sha1($secret)];
        if ($body !== null) $h[] = 'Content-Type: application/json';
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_TIMEOUT => 15,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_HTTPHEADER => $h,
        ]);
        if ($body !== null) curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body, JSON_UNESCAPED_SLASHES));
        $res = curl_exec($ch);
        $code = $res === false ? 0 : (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        return [$code, is_string($res) ? json_decode($res, true) : null];
    }
}
