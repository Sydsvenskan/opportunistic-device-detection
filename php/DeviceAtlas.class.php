<?php
/**
 * DeviceAtlas Cloud client based on SDK from:
 * https://deviceatlas.com/resources/download-cloud-api
 *
 */

class DeviceAtlas {
	const DEFAULT_SERVER = 'region2.deviceatlascloud.com';
	const USER_AGENT = 'opportunistic-device-detection/1.0 (https://github.com/Sydsvenskan)';

	public $error = NULL;
	public $errno = 0;

	private $c;
	private $server;
	private $license_key;
	
	/**
	 * @param $licence_key DeviceAtlas license key
	 * @param $server Default server (regionX.deviceatlascloud.com)
	 *
	 * @return Instance
	 */
	public function __construct($license_key, $server = NULL) {
		$this->license_key = $license_key;
		if(empty($server))
			$server = DeviceAtlas::DEFAULT_SERVER;
		$this->server = $server;

		$this->c = curl_init();
		curl_setopt($this->c, CURLOPT_TIMEOUT, 2);
		curl_setopt($this->c, CURLOPT_USERAGENT, DeviceAtlas::USER_AGENT);
		curl_setopt($this->c, CURLOPT_FOLLOWLOCATION, true);
		curl_setopt($this->c, CURLOPT_RETURNTRANSFER, true);
	}

	/**
	 * @desc Lookup user-agent string
	 *
	 * @param $userAgent User-Agent string
	 *
	 * @return Object, or NULL on error
	 *
	 */
	public function lookup($userAgent) {
		$data = $this->get('/v1/detect/properties', array('useragent' => $userAgent));
		return json_decode($data);
	}

	/**
	 * @desc Call DeviceAtlas Cloud API
	 *
	 * @param $endpoint Path to endpoint
	 * @param $params Associative array with query parameters
	 *
	 * @return Data, or NULL on error (timeout, HTTP error)
	 *
	 */
	private function get($endpoint, $params) {
		$this->error = NULL;
		$this->errno = 0;

		$arr = array();
		$arr[] = 'licencekey='. rawurlencode($this->license_key);
		foreach($params as $key => $value)
			$arr[] = rawurlencode($key) .'='. rawurlencode($value);

		$url = 'https://'. $this->server . $endpoint .'?'. implode('&', $arr);
		curl_setopt($this->c, CURLOPT_HTTPHEADER, array('Accept: application/json'));
		curl_setopt($this->c, CURLOPT_URL, $url);

		$data = @curl_exec($this->c);
		$this->errno = curl_errno($this->c);
		$this->error = curl_error($this->c);
		if($data === FALSE) {
			error_log(__METHOD__ .': DeviceAtlas API call failed: '.
				curl_error($this->c) .', URL: '. $url);
			return NULL;
		}
		else if(curl_getinfo($this->c, CURLINFO_HTTP_CODE) !== 200) {
			error_log(__METHOD__ .': DeviceAtlas API call failed with non-200 OK'
				.' HTTP response: '. curl_getinfo($this->c, CURLINFO_HTTP_CODE)
				.', URL: '. $url);
			return NULL;
		}

		return $data;
	}
}

/**
 * 
$d = new DeviceAtlas('your-license-key-here);
var_dump($d->lookup('Mozilla/5.0 (Linux; U; Android 2.3.3; en-gb; GT-I9100 Build/GINGERBREAD) AppleWebKit/533.1 (KHTML, like Gecko) Version/4.0 Mobile Safari/533.1'));
 */
