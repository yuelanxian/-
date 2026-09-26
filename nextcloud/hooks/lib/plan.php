<?php
/**
 * HomeVault hardening planner (no Nextcloud bootstrap, pure PHP).
 *
 * Compares the desired HomeVault settings (from HV_* env vars) with the current
 * configuration dumped by `occ config:list --private` and prints a plan, one step per line:
 *   INFO <text>
 *   ENABLE <app> [<app>...]
 *   SYS <n> <key,...>            (the system values to import were written to <import.json>)
 *   APPSET <critical 0|1> <app> <key> <value>
 *   DISABLE <app> [<app>...]
 *   ENFORCE2FA
 * Nothing is printed for settings that are already correct, so a warm restart is a no-op.
 *
 * Usage: php plan.php <current.json> <import.json>
 */

declare(strict_types=1);

if ($argc < 3) {
	fwrite(STDERR, "usage: php plan.php <current.json> <import.json>\n");
	exit(2);
}

// occ may print notices before/after the JSON document: keep only the outermost {...}
$raw = (string)file_get_contents($argv[1]);
$start = strpos($raw, '{');
$end = strrpos($raw, '}');
$current = ($start === false || $end === false) ? null : json_decode(substr($raw, $start, $end - $start + 1), true);
if (!is_array($current) || !isset($current['system']) || !is_array($current['system'])) {
	fwrite(STDERR, "config:list output is not valid JSON\n");
	exit(2);
}
$sys = $current['system'];
$apps = (isset($current['apps']) && is_array($current['apps'])) ? $current['apps'] : [];

function envs(string $name, string $default = ''): string {
	$v = getenv($name);
	return ($v === false || trim($v) === '') ? $default : trim($v);
}

function truthy(string $v): bool {
	return in_array(strtolower(trim($v)), ['1', 'true', 'yes', 'on'], true);
}

function out(string $line): void {
	echo $line, "\n";
}

// ---------------------------------------------------------------- desired system values
$desired = [
	'overwriteprotocol' => 'https',
	'default_phone_region' => 'CN',
	'token_auth_enforced' => true,
	'auth.bruteforce.protection.enabled' => true,
	'files_external_allow_create_new_local' => false,
	'trashbin_retention_obligation' => '30, auto',
	'versions_retention_obligation' => '30, auto',
	'simpleSignUpLink.shown' => false,
	'debug' => false,
	// Nextcloud defaults + HEIC/HEIF (imagick in the official image supports it)
	'enabledPreviewProviders' => [
		'OC\\Preview\\PNG',
		'OC\\Preview\\JPEG',
		'OC\\Preview\\GIF',
		'OC\\Preview\\BMP',
		'OC\\Preview\\XBitmap',
		'OC\\Preview\\Krita',
		'OC\\Preview\\WebP',
		'OC\\Preview\\MarkDown',
		'OC\\Preview\\TXT',
		'OC\\Preview\\OpenDocument',
		'OC\\Preview\\HEIC',
	],
];

// trusted_domains: index 0 stays "localhost" (container healthcheck / CLI), then HV_TRUSTED_DOMAINS.
$domains = preg_split('/[\s,]+/', envs('HV_TRUSTED_DOMAINS'), -1, PREG_SPLIT_NO_EMPTY) ?: [];
if ($domains === []) {
	out('INFO 警告: HV_TRUSTED_DOMAINS 为空，保持现有 trusted_domains 不变');
} else {
	$list = ['localhost'];
	foreach ($domains as $d) {
		if (!in_array($d, $list, true)) {
			$list[] = $d;
		}
	}
	$desired['trusted_domains'] = $list;
}

$cliUrl = envs('HV_OVERWRITE_CLI_URL');
if ($cliUrl !== '') {
	$desired['overwrite.cli.url'] = $cliUrl;
}

$subnet = envs('HV_FRONTEND_SUBNET');
if ($subnet !== '') {
	$desired['trusted_proxies'] = [$subnet];
}

$tz = envs('HV_TZ', 'Asia/Shanghai');
if (in_array($tz, timezone_identifiers_list(), true)) {
	$desired['default_timezone'] = $tz;
} else {
	out('INFO 警告: HV_TZ=' . $tz . ' 不是有效时区，已跳过 default_timezone');
}

$lang = envs('HV_DEFAULT_LANGUAGE', 'zh_CN');
if (preg_match('/^[a-z]{2,3}(_[A-Za-z]{2,4})?$/', $lang)) {
	$desired['default_language'] = $lang;
} else {
	out('INFO 警告: HV_DEFAULT_LANGUAGE=' . $lang . ' 无效，已跳过');
}

$mw = envs('HV_MAINTENANCE_WINDOW_UTC', '18');
if (ctype_digit($mw) && (int)$mw >= 0 && (int)$mw <= 23) {
	$desired['maintenance_window_start'] = (int)$mw;
} else {
	out('INFO 警告: HV_MAINTENANCE_WINDOW_UTC=' . $mw . ' 应为 0-23 的整数，已跳过');
}

$changed = [];
$import = [];
foreach ($desired as $key => $value) {
	if (!array_key_exists($key, $sys) || $sys[$key] !== $value) {
		$import[$key] = $value;
		$changed[] = $key;
	}
}

// ---------------------------------------------------------------- apps
function appEnabled(array $apps, string $app): bool {
	if (!isset($apps[$app]['enabled'])) {
		return false;
	}
	$v = $apps[$app]['enabled'];
	if (is_bool($v)) {
		return $v;
	}
	$v = (string)$v;
	return $v === 'yes' || str_starts_with($v, '[');
}

$enable = [];
foreach (['twofactor_totp', 'admin_audit', 'password_policy', 'files_external'] as $app) {
	if (!appEnabled($apps, $app)) {
		$enable[] = $app;
	}
}
// Phone-home / unneeded default apps (only those currently enabled are touched).
$disable = [];
foreach (['survey_client', 'firstrunwizard', 'recommendations', 'weather_status', 'nextcloud_announcements', 'support', 'related_resources', 'app_api'] as $app) {
	if (appEnabled($apps, $app)) {
		$disable[] = $app;
	}
}

// ---------------------------------------------------------------- app values [critical, app, key, value]
$publicLinks = truthy(envs('HV_ALLOW_PUBLIC_LINKS', 'false'));
$minLen = envs('HV_PASSWORD_MIN_LENGTH', '12');
if (!ctype_digit($minLen) || (int)$minLen < 8 || (int)$minLen > 128) {
	out('INFO 警告: HV_PASSWORD_MIN_LENGTH=' . $minLen . ' 无效（8-128），改用 12');
	$minLen = '12';
}
$appValues = [
	[1, 'core', 'shareapi_allow_links', $publicLinks ? 'yes' : 'no'],
	[0, 'core', 'backgroundjobs_mode', 'cron'],
	[1, 'files_sharing', 'outgoing_server2server_share_enabled', 'no'],
	[1, 'files_sharing', 'incoming_server2server_share_enabled', 'no'],
	[0, 'files_sharing', 'outgoing_server2server_group_share_enabled', 'no'],
	[0, 'files_sharing', 'incoming_server2server_group_share_enabled', 'no'],
	[0, 'files_sharing', 'lookupServerEnabled', 'no'],
	[0, 'files_sharing', 'lookupServerUploadEnabled', 'no'],
	[0, 'password_policy', 'minLength', (string)(int)$minLen],
];
if ($publicLinks) {
	$appValues[] = [0, 'core', 'shareapi_enforce_links_password', 'yes'];
}

function sameAppValue($current, string $want): bool {
	if ($current === null) {
		return false;
	}
	if (is_bool($current)) {
		return $current === truthy($want);
	}
	return (string)$current === $want;
}

// ---------------------------------------------------------------- output
if ($enable !== []) {
	out('ENABLE ' . implode(' ', $enable));
}
if ($import !== []) {
	$json = json_encode(['system' => $import], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT);
	if ($json === false || file_put_contents($argv[2], $json) === false) {
		fwrite(STDERR, "cannot write import file\n");
		exit(2);
	}
	out('SYS ' . count($changed) . ' ' . implode(',', $changed));
}
foreach ($appValues as [$crit, $app, $key, $value]) {
	if (!sameAppValue($apps[$app][$key] ?? null, $value)) {
		out("APPSET $crit $app $key $value");
	}
}
if ($disable !== []) {
	out('DISABLE ' . implode(' ', $disable));
}
$enforced = ($sys['twofactor_enforced'] ?? 'false') === 'true'
	&& ($sys['twofactor_enforced_groups'] ?? []) === []
	&& ($sys['twofactor_enforced_excluded_groups'] ?? []) === [];
if (!$enforced) {
	out('ENFORCE2FA');
}
exit(0);
