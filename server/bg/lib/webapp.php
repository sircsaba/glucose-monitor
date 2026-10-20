<?php
// Monitor Glucose server: shows the browser version of the app at this
// server's own address (kept apart from server.php so the API never depends
// on it). Delete this file, or set 'web_app_url' => 'none', to turn it off.

declare(strict_types=1);

final class WebApp
{
    /**
     * Shows the browser version of the Monitor Glucose app at this server's own
     * address. The app is published once on GitHub Pages; this fetches its files,
     * keeps a copy for one minute in lib/.webcache/, and serves them from here.
     * 'web_app_url' => 'none' in config.php turns it off. Returns false when the
     * file can't be served (then '/' shows the plain status page).
     */
    public static function serve(array $cfg, string $path, string $method): bool
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
}
