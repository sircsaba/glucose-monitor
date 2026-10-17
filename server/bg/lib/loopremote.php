<?php
// Loop remote commands (override, cancel override, carbs, bolus), sent to the
// Loop phone with an Apple push, exactly like Nightscout's
// POST /api/v2/notifications/loop. Used by Glucose Monitor Plus, Loop Caregiver
// and anything else that talks to Nightscout.
//
// The Apple push key: 'loop_apns_key_file', 'loop_apns_key_id' and
// 'loop_team_id' in config.php, or, when they are not set, the key the Loop
// heartbeat already uses (a folder next to this site with loop-heartbeat.php).
// Loop's device token and bundle id come from the profile Loop uploads.
declare(strict_types=1);

final class LoopRemote
{
    /** [keyPem, keyId, teamId, env or null, where] or null. */
    public static function apnsKey(array $cfg): ?array
    {
        $file = trim((string)($cfg['loop_apns_key_file'] ?? ''));
        $id = trim((string)($cfg['loop_apns_key_id'] ?? ''));
        $team = trim((string)($cfg['loop_team_id'] ?? ''));
        $env = isset($cfg['loop_apns_env']) ? (string)$cfg['loop_apns_env'] : null;
        $where = 'config.php';
        if ($file === '' || $id === '' || $team === '') {
            // The heartbeat's settings (its CONFIG block is read as text, not run).
            foreach (glob(dirname(__DIR__, 2) . '/*/loop-heartbeat.php') ?: [] as $hb) {
                $src = (string)file_get_contents($hb);
                $dir = dirname($hb);
                if ($id === '' && preg_match("/'apns_key_id'\\s*=>\\s*'([A-Z0-9]{10})'/", $src, $m)) $id = $m[1];
                if ($team === '' && preg_match("/'team_id'\\s*=>\\s*'([A-Z0-9]{10})'/", $src, $m)) $team = $m[1];
                if ($env === null && preg_match("/'apns_env'\\s*=>\\s*'(\\w+)'/", $src, $m)) $env = $m[1];
                if ($file === '') {
                    if (preg_match("/'apns_key_file'\\s*=>\\s*__DIR__\\s*\\.\\s*'([^']+)'/", $src, $m)) $file = $dir . $m[1];
                    elseif (preg_match("/'apns_key_file'\\s*=>\\s*'([^']+)'/", $src, $m)) $file = $m[1];
                    if ($file === '' || !is_readable($file)) $file = (glob("$dir/AuthKey_*.p8") ?: [''])[0];
                }
                $where = 'the Loop heartbeat settings';
                break;
            }
        }
        if ($file === '' || $id === '' || $team === '' || !is_readable($file)) return null;
        return [(string)file_get_contents($file), $id, $team, $env, $where];
    }

    private static function b64url(string $s): string
    {
        return rtrim(strtr(base64_encode($s), '+/', '-_'), '=');
    }

    /** OpenSSL DER ECDSA signature to the 64-byte r||s that JWT ES256 needs. */
    private static function derToRaw(string $der): string
    {
        $pos = 2;
        if (ord($der[1]) & 0x80) $pos += ord($der[1]) & 0x7f;
        $parts = [];
        for ($i = 0; $i < 2; $i++) {
            $pos++;
            $len = ord($der[$pos++]);
            $int = ltrim(substr($der, $pos, $len), "\x00");
            $pos += $len;
            $parts[] = str_pad($int, 32, "\x00", STR_PAD_LEFT);
        }
        return $parts[0] . $parts[1];
    }

    private static function jwt(string $pem, string $keyId, string $team): ?string
    {
        $key = openssl_pkey_get_private($pem);
        if (!$key) return null;
        $head = self::b64url(json_encode(['alg' => 'ES256', 'kid' => $keyId]));
        $claims = self::b64url(json_encode(['iss' => $team, 'iat' => time()]));
        if (!openssl_sign("$head.$claims", $der, $key, OPENSSL_ALGO_SHA256)) return null;
        return "$head.$claims." . self::b64url(self::derToRaw($der));
    }

    /**
     * Builds the push like Nightscout does. Returns [alert, payload] or an
     * error string.
     */
    public static function build(array $d, string $remoteAddress)
    {
        $type = (string)($d['eventType'] ?? '');
        $payload = ['remote-address' => $remoteAddress, 'notes' => $d['notes'] ?? null, 'entered-by' => $d['enteredBy'] ?? null];
        if ($type === 'Temporary Override Cancel') {
            $payload['cancel-temporary-override'] = 'true';
            $alert = 'Cancel Temporary Override';
        } elseif ($type === 'Temporary Override') {
            $payload['override-name'] = (string)($d['reason'] ?? '');
            if ($payload['override-name'] === '') return 'Temporary Override: no override name (reason)';
            if (isset($d['duration']) && (int)$d['duration'] > 0) $payload['override-duration-minutes'] = (int)$d['duration'];
            $alert = (string)($d['reasonDisplay'] ?? $d['reason']) . ' Temporary Override';
        } elseif ($type === 'Remote Carbs Entry') {
            $carbs = (float)($d['remoteCarbs'] ?? 0);
            if ($carbs <= 0) return 'Remote carbs failed: incorrect carbs entry';
            $payload['carbs-entry'] = $carbs;
            $payload['absorption-time'] = isset($d['remoteAbsorption']) && (float)$d['remoteAbsorption'] > 0 ? (float)$d['remoteAbsorption'] : 3.0;
            if (!empty($d['otp'])) $payload['otp'] = (string)$d['otp'];
            if (!empty($d['created_at'])) $payload['start-time'] = (string)$d['created_at'];
            $alert = "Remote Carbs Entry: {$carbs} grams\nAbsorption Time: {$payload['absorption-time']} hours";
        } elseif ($type === 'Remote Bolus Entry') {
            $bolus = (float)($d['remoteBolus'] ?? 0);
            if ($bolus <= 0) return 'Remote bolus failed: incorrect bolus entry';
            $payload['bolus-entry'] = $bolus;
            if (!empty($d['otp'])) $payload['otp'] = (string)$d['otp'];
            $alert = "Remote Bolus Entry: {$bolus} U\n";
        } else {
            return "Unhandled event type: $type";
        }
        if (!empty($d['notes'])) $alert .= ' - ' . $d['notes'];
        if (!empty($d['enteredBy'])) $alert .= ' - ' . $d['enteredBy'];
        $now = time();
        $payload['sent-at'] = gmdate('Y-m-d\TH:i:s.000\Z', $now);
        $payload['expiration'] = gmdate('Y-m-d\TH:i:s.000\Z', $now + 300);
        return [$alert, $payload];
    }

    /** Sends a command. Returns null when Apple accepted it, else the reason. */
    public static function send(PDO $db, array $cfg, array $d, string $remoteAddress): ?string
    {
        $key = self::apnsKey($cfg);
        if ($key === null) {
            return 'Loop notification failed: no Apple push key. Set loop_apns_key_file, loop_apns_key_id and loop_team_id in config.php '
                . '(or install the Loop heartbeat next to this site).';
        }
        [$pem, $keyId, $team, $env] = $key;
        $row = $db->query('SELECT doc FROM profile ORDER BY created_ms DESC LIMIT 1')->fetchColumn();
        $profile = $row ? json_decode((string)$row, true) : null;
        $ls = is_array($profile) ? ($profile['loopSettings'] ?? null) : null;
        if (!is_array($ls)) return 'Loop notification failed: could not find loopSettings in the profile (Loop has not uploaded its profile here yet)';
        $token = (string)($ls['deviceToken'] ?? '');
        $bundle = (string)($ls['bundleIdentifier'] ?? '');
        if ($token === '') return 'Loop notification failed: could not find deviceToken in loopSettings';
        if ($bundle === '') return 'Loop notification failed: could not find bundleIdentifier in loopSettings';
        $production = isset($profile['isAPNSProduction']) ? (bool)$profile['isAPNSProduction'] : ($env === null || $env !== 'sandbox' && $env !== 'development');

        $built = self::build($d, $remoteAddress);
        if (is_string($built)) return $built;
        [$alert, $payload] = $built;
        $jwt = self::jwt($pem, $keyId, $team);
        if ($jwt === null) return 'Loop notification failed: the Apple push key could not be read';
        if (!defined('CURL_HTTP_VERSION_2_0')) return 'Loop notification failed: PHP curl has no HTTP/2 (needed by Apple)';

        $body = json_encode(['aps' => ['alert' => $alert, 'content-available' => 1, 'interruption-level' => 'time-sensitive']] + $payload,
            JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION);
        $host = $production ? 'api.push.apple.com' : 'api.sandbox.push.apple.com';
        $ch = curl_init("https://$host/3/device/$token");
        curl_setopt_array($ch, [
            CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_2_0,
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $body,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => 20,
            CURLOPT_HTTPHEADER => [
                "authorization: bearer $jwt",
                "apns-topic: $bundle",
                'apns-push-type: alert',
                'apns-priority: 10',
                'apns-expiration: ' . (time() + 300),
                'content-type: application/json',
            ],
        ]);
        $res = curl_exec($ch);
        $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $err = curl_error($ch);
        curl_close($ch);
        if ($code === 200) return null;
        $reason = is_string($res) ? (json_decode($res, true)['reason'] ?? $res) : $err;
        return "Loop notification failed: Apple answered HTTP $code $reason";
    }
}
