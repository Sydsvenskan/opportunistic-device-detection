-- In your Nginx server {} block, do:
--   # http://wiki.nginx.org/HttpLuaModule#access_by_lua_file
--   rewrite_by_lua_file '/etc/nginx/lua/nginx-device-lookup-rewrite.lua';
--
local device = g_dd:lookup_ua(ngx.var.http_user_agent)
if device then
	ngx.req.set_header("X-Device", device)
	-- Make sure the backend returns a Vary:X-Device response
	-- header if it returns different content for different
	-- values of the X-Device: request header so cache servers
	-- can be smart about what they return from their caches
else
	-- If the lookup failed, set a sane default value
	ngx.req.set_header("X-Device", "touch")
end
