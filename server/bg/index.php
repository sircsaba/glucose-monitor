<?php
// Glucose server entry point. All requests come here (see .htaccess).
declare(strict_types=1);

require __DIR__ . '/lib/server.php';

$configFile = __DIR__ . '/config.php';
if (!is_file($configFile)) {
    http_response_code(500);
    header('Content-Type: text/plain; charset=utf-8');
    echo "config.php is missing: copy config.sample.php to config.php and fill it in.";
    exit;
}

Server::run(require $configFile);
