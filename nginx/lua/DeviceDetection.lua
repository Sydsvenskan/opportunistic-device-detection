--[[
Oppertunistic device detection (User-Agent) for Nginx (ngx_lua module)

Lookups User-Agent: strings against an Nginx shared dictionary (optional)
and memcached.

User-Agent: strings for which lookups failed will be stored in memcached
under a key called `ua-<N>` where `N` is the number of failed lookups.
The current value of `N` is given by another key called `ua-idx`.

It's expected that an external script regularly polls the key `ua-idx` and
performs device loookups for all `ua-<N>` keys, where `N` is between the
previously value of `ua-idx` (or `1` if it never run) and the current value
of `ua-idx`.  Once a lookup has been performed, the `ua-<N>` keys may then
be deleted.

A sample PHP script which retrieves unknown User-Agent: strings from memcached
and do lookups against DeviceAtlas (commerical service) is provided in the
repository where this file is located.

	-- noah@hd.se, 2012-2015


Sample Nginx configuration:

http {
	# Assumes you've these files in /etc/nginx/lua/
	# - this file
	# - https://raw.githubusercontent.com/openresty/lua-resty-memcached/master/lib/resty/memcached.lua
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

	server {
		listen 80;
		server_name _;

		# Set X-Device: request header for upstream services
		rewrite_by_lua '
			local device = g_dd:lookup_ua(ngx.var.http_user_agent)
			if device then
				ngx.req.set_header("X-Device", device)
				-- Make sure the backend returns a Vary:X-Device response
				-- header if it returns different content for different
				-- values of the X-Device: request header so cache servers
				-- can be smart about what they return from their caches
			else
				-- If the lookup failed, set a sane default
				ngx.req.set_header("X-Device", "touch")
			end
		';

		location = /x-device {
			# To demonstrate that it works (once data is present in memcached)
			content_by_lua '
				ngx.say("nginx or memcached lookup of User-Agent string: ",
					ngx.vars.http_x_device)
			';
		}
	}
}

]]

local ngx_md5 = ngx.md5
local ngx_WARN = ngx.WARN
local ngx_ERR = ngx.ERR
local ngx_INFO = ngx.INFO
local ngx_shared = ngx.shared
local ngx_log = ngx.log

local _module = {
	_VERSION = '1.0',
}

local _metatable = { __index = _module }

function _module.new(self, memcached, opts)
	local opt_dict = nil
	local opt_mc_host = '127.0.0.1'
	local opt_mc_port = 11211
	local opt_mc_socket = nil
	local opt_mc_timeout = 200  -- 0.2 seconds

	if opts then
		if opts.dict then
			opt_dict = opts.dict
		end
		opt_mc_module = opts.mc_module
		if opts.host then
			opt_mc_host = opts.mc_host
		end
		if opts.mc_port then
			opt_mc_port = opts.mc_port
		end
		if opts.mc_timeout then
			opt_mc_timeout = opts.mc_timeout
		end
		if opts.mc_socket then
			opt_mc_socket = opts.mc_socket
		end
	end

	return setmetatable({
		dict = opt_dict,
		mc_module = memcached,
		mc_host = opt_mc_host,
		mc_port = opt_mc_port,
		mc_timeout = opt_mc_timeout,
		mc_socket = opt_mc_socket
	}, _metatable)
end

function _module.lookup_ua(self, user_agent)
	local device, err

	if not user_agent then
		ngx_log(ngx_INFO, "DeviceDetection: lookup_ua() got nil argument")
		return nil
	end

	-- compress User-Agent string
	key = 'ua-' .. ngx_md5(user_agent)

	-- lookup against Nginx shared dictionary (if available)
	if self.dict then
		device, err = self:lookup_nginx(key)
		if err then
			ngx_log(ngx_WARN, "DeviceDetection: lookup_nginx(): " .. err)
		end
		if device then
			return device
		end
	end

	-- lookup against memcached (if available)
	local memcached = self.mc_module
	if not memcached then
		return nil
	end
	local memc, err = memcached:new()
	if err then
		ngx_log(ngx_WARN, "DeviceDetection: Failed to create memcached instance: ", err)
		return nil
	end
	memc:set_timeout(self.mc_timeout)

	local ok, err
	if self.mc_socket then
		ok, err = memc:connect(self.mc_socket)
	else
		ok, err = memc:connect(self.mc_host, self.mc_port)
	end
	if not ok then
		ngx_log(ngx_WARN, "DeviceDetection: Failed to connect to memcached: ", err)
		return nil
	end

	local device, flags, err = memc:get(key)
	if err then
		ngx_log(ngx_WARN, "DeviceDetection: Failed to retrieve key ", key, ": ", err)
	end
	if device then
		if self.dict then
			-- Update Nginx dictionary before returning result
			self:set_nginx(key, device)
		end
		ok, err = memc:close()
		return device
	end

	-- Log failure to lookup key
	local idx_key = 'ua-idx'
	local idx, err = memc:incr(idx_key, 1)
	if err then
		if err == 'NOT_FOUND' then
			idx = 1
			memc:set(idx_key, idx)
		else
			ngx_log(ngx_WARN, "DeviceDetection: Failed to increment index key ", idx_key, ": ", err)
		end
	end

	ua_key = 'ua-' .. idx
	ok, err = memc:set(ua_key, user_agent)

	ngx_log(ngx_INFO, "DeviceDetection: Wrote unknown User-Agent: string with key ", key, " to ", ua_key, ": ", user_agent)
	ok, err = memc:close()

	return nil
end

function _module.lookup_nginx(self, key)
	local dict = ngx_shared[self.dict]
	if not dict then
		return nil, "Not a lua_shared_dict: " .. self.dict
	end
	local value, err = dict:get(key)
	return value, err
end

function _module.set_nginx(self, key, value)
	local dict = ngx_shared[self.dict]
	if not dict then
		return nil, "Not a lua_shared_dict: " .. self.dict
	end
	local ok, err, forcible = dict:set(key, value)
	return ok, err
end

return _module
