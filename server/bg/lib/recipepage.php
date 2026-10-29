<?php
// Monitor Glucose server: fetches a recipe web page for the web app's
// "recipe from a web address" (browsers cannot read other sites). Optional:
// delete this file to turn it off. Only public web pages: addresses inside
// a private network are refused.

declare(strict_types=1);

final class RecipePage
{
    private const MAX = 4000000;

    /** Returns ['url' => final address, 'html' => the page]. */
    public static function fetch(string $url): array
    {
        $url = trim($url);
        if (!preg_match('#^https?://#i', $url)) $url = 'https://' . $url;
        if (!function_exists('curl_init')) throw new HttpError(503, 'This server has no curl');
        for ($hop = 0; $hop < 6; $hop++) {
            $pin = self::checkPublic($url);
            $ch = curl_init($url);
            // Connect to the address that was checked (not a second DNS answer).
            curl_setopt($ch, CURLOPT_RESOLVE, [$pin]);
            $html = '';
            curl_setopt_array($ch, [
                CURLOPT_RETURNTRANSFER => false,
                CURLOPT_FOLLOWLOCATION => false,
                CURLOPT_TIMEOUT => 15,
                CURLOPT_CONNECTTIMEOUT => 6,
                CURLOPT_PROTOCOLS => CURLPROTO_HTTP | CURLPROTO_HTTPS,
                CURLOPT_ENCODING => '',
                CURLOPT_USERAGENT => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
                CURLOPT_HTTPHEADER => ['Accept: text/html,application/xhtml+xml', 'Accept-Language: en-CA,en;q=0.9,fr-CA;q=0.8'],
                CURLOPT_WRITEFUNCTION => function ($c, $chunk) use (&$html) {
                    $html .= $chunk;
                    return strlen($html) > self::MAX ? 0 : strlen($chunk);
                },
            ]);
            $ok = curl_exec($ch);
            $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
            $next = (string)curl_getinfo($ch, CURLINFO_REDIRECT_URL);
            $err = curl_error($ch);
            curl_close($ch);
            if ($code >= 300 && $code < 400 && $next !== '') {
                $url = $next;
                continue;
            }
            if ($ok === false && strlen($html) <= self::MAX) throw new HttpError(502, 'Cannot reach that page: ' . $err);
            if ($code !== 200) throw new HttpError(502, "That site answered with error $code");
            if (!mb_check_encoding($html, 'UTF-8')) $html = mb_convert_encoding($html, 'UTF-8', 'ISO-8859-1');
            return ['url' => $url, 'html' => $html];
        }
        throw new HttpError(502, 'Too many redirects');
    }

    /** Refuses addresses of private networks (this server's own network). */
    private static function checkPublic(string $url): string
    {
        $p = parse_url($url);
        $host = (string)($p['host'] ?? '');
        $port = (int)($p['port'] ?? 0);
        if ($host === '' || !in_array(strtolower((string)($p['scheme'] ?? '')), ['http', 'https'], true)) throw new HttpError(400, 'Not a web address');
        if ($port !== 0 && $port !== 80 && $port !== 443) throw new HttpError(400, 'Only normal web addresses');
        $ips = filter_var($host, FILTER_VALIDATE_IP) ? [$host] : (gethostbynamel($host) ?: []);
        if (!$ips) throw new HttpError(502, "Cannot find $host");
        foreach ($ips as $ip) {
            if (!filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE)) {
                throw new HttpError(400, 'That address is not a public web page');
            }
        }
        $port = $port ?: (strtolower((string)$p['scheme']) === 'http' ? 80 : 443);
        return "$host:$port:" . $ips[0];
    }
}
