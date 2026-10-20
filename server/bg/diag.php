<?php
// Monitor Glucose server check: open https://<your server>/diag.php, read the
// result, then DELETE this file. It shows no passwords or tokens.
ini_set('display_errors', '1');
error_reporting(E_ALL);
header('Content-Type: text/plain; charset=utf-8');
echo "PHP " . PHP_VERSION . "\n\n";

$dir = __DIR__;
echo "Files:\n";
foreach (['index.php', '.htaccess', 'config.php', 'lib/server.php', 'lib/eventlog.php', 'lib/loopremote.php',
          'lib/libre.php', 'lib/copy.php', 'lib/import.php'] as $f) {
    $p = "$dir/$f";
    echo is_file($p)
        ? sprintf("  ok       %-20s %7d bytes  %s\n", $f, filesize($p), date('Y-m-d H:i', filemtime($p)))
        : sprintf("  MISSING  %s\n", $f);
}

echo "\nconfig.php:\n";
try {
    $cfg = require "$dir/config.php";
    if (!is_array($cfg)) echo "  PROBLEM: config.php must end with return [ ... ]; (it returned " . gettype($cfg) . ")\n";
    else {
        echo "  ok, " . count($cfg) . " settings\n";
        foreach (['db_dsn', 'db_user', 'db_pass'] as $k) echo "  $k: " . (isset($cfg[$k]) && $cfg[$k] !== '' ? 'set' : 'EMPTY') . "\n";
    }
} catch (Throwable $e) {
    echo "  ERROR: " . $e->getMessage() . "\n  in " . basename($e->getFile()) . " line " . $e->getLine() . "\n";
    exit;
}

echo "\nLoading the code:\n";
foreach (['lib/eventlog.php', 'lib/loopremote.php', 'lib/server.php'] as $f) {
    if (!is_file("$dir/$f")) {
        echo "  MISSING $f: upload it, this is what breaks the server\n";
        exit;
    }
    try {
        require_once "$dir/$f";
        echo "  ok  $f\n";
    } catch (Throwable $e) {
        echo "  ERROR in $f: " . $e->getMessage() . "\n  (" . basename($e->getFile()) . " line " . $e->getLine() . ")\n";
        exit;
    }
}

echo "\nDatabase:\n";
try {
    $pdo = new PDO($cfg['db_dsn'] ?? '', $cfg['db_user'] ?? '', $cfg['db_pass'] ?? '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $n = $pdo->query('SELECT COUNT(*) FROM entries')->fetchColumn();
    echo "  ok, $n readings\n";
} catch (Throwable $e) {
    echo "  ERROR: " . $e->getMessage() . "\n";
}

echo "\nLast lines of error_log:\n";
foreach (["$dir/error_log", "$dir/lib/error_log"] as $log) {
    if (!is_file($log)) continue;
    $lines = @file($log, FILE_IGNORE_NEW_LINES) ?: [];
    foreach (array_slice($lines, -12) as $l) echo "  " . preg_replace('/(token|secret|pass\w*)=\S+/i', '$1=***', $l) . "\n";
}
echo "\nDone. Delete diag.php now.\n";
