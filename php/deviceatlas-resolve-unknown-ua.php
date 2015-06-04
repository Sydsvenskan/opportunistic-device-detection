#!/usr/bin/env php
<?php
/**
 * VCL functionality on the Varnish servers logs unknown User-Agent:
 * headers to memcached.  This downloads the data logged in memcached,
 * resolves the User-Agent strings using DeviceAtlas and stores the
 * result in memcached.
 *
 *  -- noah, feb 2014
 *
 *
 * The memcached key "ua-idx" is an integer that is incremented each time the
 * lookup of a User-Agent: header failed in memcached.  The User-Agent:
 * header which failed the lookup is then logged to the key "ua-N",
 * where N is the current value of the "ua-idx" key.
 *
 * This scripts fetches the current value of the "ua" key in order to
 * figoure out the name of the key where the last missed User-Agent:
 * header is logged.
 *
 * If the key "ua-next" is also set, its value used as a starting point
 * for retrieving missed User-Agent: headers.  This key is updated with
 * the current value of "ua-idx" at the end of this script.
 *
 *
 * DEPENDENCIES:
 * $ sudo apt-get install php5-cli php5-curl php5-memcache ca-certificates
 *
 * RUNNING (crontab):
 * * * * * * php deviceatlas-resolve-unknown-ua.php license-key-here 127.0.0.1 >/dev/null
 *
 */

require_once(dirname(__FILE__) .'/DeviceAtlas.class.php');


/* Max number of entries to download in one batch */
$maxEntries = 1000;


/**
 * Map DeviceAtlas data to {mobile,touch,tablet,desktop}
 */
function mapPropertiesToDeviceType($props, $ua) {
	/* Assume desktop by default */
	$deviceType = 'desktop';

	if(isset($props->mobileDevice) && $props->mobileDevice) {
		/* Assume feature phone */
		$deviceType = 'mobile';

		/* Could be smartphone or tablet */
		if(isset($props->touchScreen) && $props->touchScreen)
			$deviceType = 'touch';

		/* Definitively tablet */
		if(isset($props->isTablet) && $props->isTablet)
			$deviceType = 'tablet';

		if($deviceType === 'mobile') {
			/**
			 * DeviceAtlas doesn't set isTablet or touchScreen for all devices
			 * despite the fact they're rather well-known and equiped with
			 * capacitive touch screens.
			 * Fix this here.
			 */

			if(isset($props->isRobot) && $props->isRobot) {
				/* Service up touch version for Googlebot etc */
				$deviceType = 'touch';
			}

			if(strstr($ua, 'Tablet')) {
				/**
				 * Assume all tables have touch screens
				 * Example User-Agent string unknown to DeviceAtlas:
				 *   Opera/9.80 (Android 4.2.1; Linux; Opera Tablet/ADR-1301080958) Presto/2.11.355 Version/12.10
				 */
				$deviceType = 'tablet';
			}
			else if(strstr($ua, 'Windows Phone 7') || strstr($ua, 'Windows Phone 8') || strstr($ua, 'Windows Phone 9')) {
				/* Microsoft mandates that capacitive touchscreen is required for WP7 and later */
				$deviceType = 'touch';
			}
		}
	}

	return $deviceType;
}


if($argc < 3) {
	die("Usage: ${argv[0]} <license key> <memcached host 1> [<memcached host 2>, ..]\n");
}

$licenseKey = $argv[1];

$memcachedServers = array();
for($i = 2; $i < $argc; $i++)
	$memcachedServers[] = $argv[$i];


/* Connect to memcached */
$memcachedHandles = array();
foreach($memcachedServers as $server) {
	$mc = new Memcache();
	if(@$mc->connect($server) === FALSE) {
		echo "WARN: Failed to connect to memcached server '$server'\n";
		continue;
	}

	$memcachedHandles[$server] = $mc;
}

/* Memcached keys to delete */
$keysToDeletePerHost = array();
$uaNextPerHost = array();


/* Fetch UA strings that Varnish failed to lookup from memcached */
$arr = array();
foreach($memcachedHandles as $hostname => $mc) {
	if(!isset($keysToDeletePerHost[$hostname]))
		$keysToDeletePerHost[$hostname] = array();

	$lastEntry = $mc->get('ua-idx');
	if(!$lastEntry) {
		/* No missed User-Agents yet */
		continue;
	}

	/* Attempt to get previously processed entry */
	$firstEntry = $mc->get('ua-next');
	if(!$firstEntry)
		$firstEntry = 1;

	/* Prevent infinite loop in case of invalid data */
	if($firstEntry > $lastEntry)
		$firstEntry = $lastEntry;

	/* Never consider more than $maxEntries entries */
	if($lastEntry > $maxEntries && $lastEntry - $firstEntry > $maxEntries) {
		$n = $lastEntry - $firstEntry;
		echo "WARN: $hostname: Only considering the last $maxEntries entries: range of $firstEntry and $lastEntry is too high ($n)\n";
		$firstEntry = $lastEntry - $maxEntries;
	}

	echo "* $hostname: Downloading entries from $firstEntry to $lastEntry\n";
	for($i = $firstEntry; $i <= $lastEntry; $i++) {
		$key = 'ua-'. $i;
		$userAgent = $mc->get($key);
		if($userAgent === FALSE) {
			/* Key not found */
			continue;
		}

		if(!empty($userAgent)) {
			$uaKey = 'ua-'. md5($userAgent);
			$arr[$uaKey] = $userAgent;
		}

		$keysToDeletePerHost[$hostname][] = $key;
	}

	/* Note first entry to be checked during next run */
	$uaNextPerHost[$hostname] = $lastEntry + 1;
}


$deviceatlas = new DeviceAtlas($licenseKey);


/* Lookup User-Agent: strings with DeviceAtlas */
echo "* Resolving ". count($arr) ." previously unknown User-Agent: strings\n";
$resolved = array();
foreach($arr as $uaKey => $userAgent) {
	$obj = $deviceatlas->lookup($userAgent);
	if($obj === NULL) {
		/* API call failed */
		echo "$hostname: Failed to resolve key $uaKey with string: $userAgent\n";
		continue;
	}

	$props = $obj->properties;
	echo "[$uaKey] Trying to resolve: $userAgent\n";
	$deviceType = mapPropertiesToDeviceType($props, $userAgent);
	echo "-- DEVICE TYPE: $deviceType\n";

	$resolved[$uaKey] = $deviceType;
}


/* Populate memcached with ua-<hash> keys */
foreach($memcachedHandles as $hostname => $mc) {
	foreach($resolved as $uaKey => $data) {
		$mc->set($uaKey, $data);
	}

	if(isset($uaNextPerHost[$hostname])) {
		$uaNext = $uaNextPerHost[$hostname];
		echo "* $hostname: Updating key ua-next to: $uaNext\n";
		$mc->set('ua-next', $uaNext);
	}

	echo "* $hostname: Deleting ". count($keysToDeletePerHost[$hostname]) ." keys\n";
	foreach($keysToDeletePerHost[$hostname] as $key) {
		$mc->delete($key);
	}
}
