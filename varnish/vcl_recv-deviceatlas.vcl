/**
 * There is no point in running the DeviceAtlas code for all requests.
 *
 * Here, only consider requests for paths known to be related to
 * section or article pages (i.e, ends with a "/"), Escenic pages with
 * non-friendly URLs (i.e, ends with ".ece"), WordPress pages or
 * independent PHP-scripts (i.e, ends with ".php")
 *
 */
if(req.url ~ "/$" || req.url ~ "/\?" || req.url ~ "\.ece$" || req.url ~ "\.ece\?" || req.url ~ "\.php$" || req.url ~ "\.php\?") {
	/* Compress the User-Agent string to a 8 byte hex string (32 bits entropy) */

	/**
	 * Not all requests have a User-Agent: header set.
	 *
	 * Make sure it is always set to something, or else
	 * vmod_memcached will crash later because it doesn't
	 * like NULL keys.
	 *
	 * We could of course handle this with a seperate 
	 * variable (temporary header) and preserve the
	 * originally missing User-Agent: header, but 
	 * currently we don't.  :)
	 *
	 */
	if(!req.http.User-Agent) {
		set req.http.User-Agent = "-";
	}

	/**
	 * Compress the variable length User-Agent: header with MD5
	 * and extract an eight digit hex string.  This will
	 * effectively map each User-Agent: string into 32 bits.
	 *
	 * The returned data is appended to an arbitrary prefix
	 * ("ua-") and stored in a temporary request header
	 *
	 * It will be used as a key for a memcached lookup later.
	 *
	 */
	// set req.http.X-temp = "ua-" + regsub(digest.hash_md5(req.http.User-Agent), "(........).*", "\1");
	set req.http.X-temp = "ua-" + digest.hash_md5(req.http.User-Agent);

	/**
	 * To aid debugging, we allow requests where X-Device: is
	 * already set, even if it is empty.
	 *
	 * If a request has been restarted within Varnish, the header
	 * has likely already been set by a previous lookup by this
	 * code.
	 *
	 * In most cases, however, the header is not set.  Therefore
	 * we attempt to set it by querying memcached for whatever
	 * key we came up with for the User-Agent: header.
	 *
	 */
	if(!req.http.X-Device) {
		set req.http.X-Device = memcached.get(req.http.X-temp);
	}

	/**
	 * If the key computed for the User-Agent: string was not
	 * found in memcached, the X-Device: header will now have
	 * an empty value.
	 *
	 * If that happens, we use a hardcoded default instead and
	 * make sure all (matching) requests that end up on our
	 * backends always have something sane set in the X-Device:
	 * header.
	 *
	 * Additionally, the fact that the lookup failed is stored
	 * in memcached along with the value of the User-Agent:
	 * header.
	 * That allows us to extract misses with an external program,
	 * lookup the corresponding User-Agent: strings and finally
	 * update memcached with information about what kind of
	 * devices the User-Agent: strings represent.
	 *
	 */
	if(req.http.X-Device ~ "^$") {
		/**
		 * Hardcoded default value if memcached lookups fail.
		 * Use one of "desktop", "touch", "tablet" or "mobile"
		 */
		set req.http.X-Device = "touch";

		/**
		 * Log the miss in memcached.
		 *
		 * The key "ua-idx" is used as an increasing counter.
		 * The User-Agent: string will be stored in the key
		 * "ua-<counter value>" to allow it to be extracted
		 * later.
		 */
		set req.http.X-temp = memcached.get("ua");
		if(req.http.X-temp ~ "^$") {
			memcached.set("ua-idx", "1", 0, 0);
			set req.http.X-temp = "ua-1";
		}
		else {
			set req.http.X-temp = "ua-" + memcached.incr("ua-idx", 1);
		}

		memcached.set(req.http.X-temp, req.http.User-Agent, 0, 0);
	}

	/* Delete temporary variable */
	remove req.http.X-temp;

	/**
	 * Done.  The X-Device: header (req.http.X-Device) is now set to
	 * one of "desktop", "touch" or "mobile" (assuming that is what
	 * the external program stores in memcached ... )
	 */
}
