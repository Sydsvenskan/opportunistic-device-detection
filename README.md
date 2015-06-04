# Overview

This package contains code to do device detection in Nginx and Varnish on a best-effort basis.

It relies on an external service called DeviceAtlas that provides an API to identify device features the User-Agent: header that browsers including in HTTP requests.


# Requirements

* Nginx
    + Nginx LUA module (https://github.com/openresty/lua-nginx-module)
* Varnish
    + https://github.com/varnish/libvmod-digest
    + https://github.com/sodabrew/libvmod-memcached
* Memcached
* PHP client
* DeviceAtlas.com subscription


# How it works

`User-Agent:` strings in incoming HTTP requests are hashed (to provide fixed length keys) and looked up against a local memcached instance.  If the key is found in memcached, a new `X-Device:` header is set on the request object in Nginx/Varnish with the value returned from memcached.

If the key was not found in memcached, the User-Agent: string is stored in memcached under a numbered key of the form `ua-<sequence number>`.  The name of the key is constructed by first incrementing the value of a dedicated counter key called `ua-idx`.  This allows an external process to later retrieve a list of User-Agent: strings for which lookups against memcached failed.


# Backend requirements

The presence of the `X-Device:` header in incoming HTTP requests allows backend services to return different content depending on the value of the header.

Because requests for a single URL may yield different responses depending on the contents of the `X-Device:` header, Varnish (or other caching proxies) needs a way to distinguish each variant in its cache.  This can be achieved by including a `Vary:` header in HTTP responses.

To make Varnish differentiate cache entries by both the URL and the request header `X-Device:`, set the HTTP response header `Vary:` to:

    Vary: X-Device


# Installation

## Memcached

On Debian/Ubuntu, install memcached:

    $ sudo apt-get install memcached

With the default options in `/etc/memcached.conf`, memcached will listen on `127.0.0.1:11211`.


## Nginx

Nginx needs to be built with the (non-official) LUA module from https://github.com/openresty/lua-nginx-module.

On Debian/Ubuntu systems the package `nginx-extras` provides a version of Nginx built with support for LUA:

    $ sudo apt-get install nginx-extras


### Nginx configuration

This repository contains a number of files to support doing lookups against an Nginx shared dictionary (optional) and memcached:

* `nginx/lua/DeviceDetection.lua` (wrapper which does device detection against Nginx/memcached)
* `nginx/lua/memcached.lua`  (LUA package to talk to memcached)
* `nginx/lua/nginx-device-lookup-init.lua` (sample code needed in the `http{}` block)
* `nginx/lua/nginx-device-lookup-rewrite.lua` (sample code for a `server{}` block)

Copy the `.lua` files to a directory available to Nginx, for instance `/etc/nginx/lua`.

The device lookup code needs to be configured in the `http {}` block of Nginx.  Create  `/etc/nginx/conf.d/devicedetection.conf` and put the following lines in it:

    # Assumning this file lives inside /etc/nginx/conf.d and is being parsed
    # in the context of the http {} block:
    lua_package_path '/etc/nginx/lua/?.lua;;';
    
    # User-Agent<->device type cache shared among Nginx workers
    # Not needed if you're OK with queries against memcached for each
    # request.  In that case, do not set the 'dict' key below.
    lua_shared_dict ua_type 10m;
    
    # Initialize the device detection instance
    init_by_lua '
    	local memcached = require("memcached")
    	local DeviceDetection = require("DeviceDetection")
    
    	-- Global variable
    	g_dd = DeviceDetection:new(memcached, {
    		dict = "ua_type",       -- (not required but recommended)
    		mc_host = "127.0.0.1",  -- (default)
    		mc_port = 11211,        -- (default)
    		mc_socket = nil,        -- (could be: unix:/run/memcached.sock)
    		mc_timeout = 200        -- (connect timeout, default 200ms)
    	})
    ';

For each `server {}` block where you need device detection, add the following line:

    # Set a request header called X-Device:
    rewrite_by_lua_file '/etc/nginx/lua/nginx-device-lookup-rewrite.lua';

This will tag each request with a `X-Device:` header.

NOTE: You will probably want to edit the default `X-Device:` header set when a lookup against memcached fails because of a not-yet-known User-Agent: string.  It's currently set to `touch` which may or may not match your requirements.  The value should be chosen from what the external script may map User-Agent: strings to (see `mapPropertiesToDeviceType()` in `php/deviceatlas-resolve-unknown-ua.php`).


## Varnish

The required VCL code to lookup and store data in memcached is available here:

* `varnish/vcl_recv-deviceatlas.vcl`

You'll want to include this in your `vcl_recv {}` block in your VCL file.


### Varnish modules

The following extra modules are required to talk to memcached and compress User-Agent: strings into fixed length values.  You'll want to include this code block at the top of your VCL file:

    /**
     * Digest and memcached - used for DeviceAtlas
     * https://github.com/varnish/libvmod-digest
     * https://github.com/sodabrew/libvmod-memcached
     */
    import digest;
    import memcached;

These modules are non-standard and need to be be compiled by hand.  For more information on how to do this, see their respective READMEs on GitHub:

* https://github.com/varnish/libvmod-digest#installation
* https://github.com/sodabrew/libvmod-memcached#installation


## Update service

The code required to keep data in memcached fresh is available here:

* `php/DeviceAtlas.class.php`
* `php/deviceatlas-resolve-unknown-ua.php`

The first file, `DeviceAtlas.class.php`, contains code to talk to DeviceAtlas' service.

The second file, `deviceatlas-resolve-unknown-ua.php`, retrieves User-Agent: strings from memcached, queries DeviceAtlas for devices features, interprets the results and updates memcached keys corresponding to the User-Agent: strings.

Thus, this script needs to be called regularly, preferably via cron:

    # Update memcached on 127.0.0.1
    * * * * php /usr/local/bin/deviceatlas-resolve-unknown-ua.php LICENSE-KEY-HERE 127.0.0.1

The script `deviceatlas-resolve-unknown-ua.php` takes one or more addresses to memcached servers on its command line.  To update multiple servers, use something like:

    $ php /usr/local/bin/deviceatlas-resolve-unknown-ua.php LICENSE-KEY-HERE varnish1.example.com varnish2.example.com

The DeviceAtlas license key needs to be supplied as the first argument to the script.

**NOTE**: You will probably want to modify `mapPropertiesToDeviceType()` in `php/deviceatlas-resolve-unknown-ua.php` and decide for yourself what you want to map different `User-Agent:` strings to.  Currently the script use four variants:

* `mobile` (dumb feature phone)
* `touch` (smartphones with touch screens)
* `tablet` (tablet devices)
* `desktop` (everything else)


### PHP packages required (Debian/Ubuntu)

The following packages needs to be installed to be able to run the update service.  CA certificates are required to talk to DeviceAtlas over https (to avoid leaking visitors' User-Agent: strings over plaintext internet).

    $ sudo apt-get install php5-cli php5-curl php5-memcache ca-certificates

