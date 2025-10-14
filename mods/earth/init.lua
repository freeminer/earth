-- geoip_on_join/init.lua
-- Do a GeoIP lookup for a player when they join and send the result to that player.
-- Configurable via core.conf:
--   geoip_on_join.enable = true               (default true) -- enable automatic lookup on join
--   geoip_on_join.api_url = <url_with_%s>     (default ip-api.com URL)
--   geoip_on_join.api_key = <key>             (optional; if provider needs a key; use %k in api_url to substitute)
--   geoip_on_join.cache_ttl = <seconds>       (default 3600)
-- Example default api_url: http://ip-api.com/json/%s?fields=status,message,country,regionName,city,lat,lon,timezone,isp,query

local http = core.request_http_api()
if not http then
    core.log("warning", "[geoip_on_join] HTTP API not available; geo lookups disabled")
end

local function strip_port(ip)
    if not ip then return "" end
    -- IPv6 in brackets: "[::1]:12345" -> "::1"
    local v6 = ip:match("^%[(.-)%]")
    if v6 then return v6 end
    -- IPv4 or plain host with optional :port -> "1.2.3.4:1234" -> "1.2.3.4"
    return ip:match("^(.-):%d+$") or ip
end

local function is_private_ip(ip)
    if not ip or ip == "" then return false end
    -- IPv4 private/reserved blocks
    if ip:match("^127%.") or ip:match("^10%.") or ip:match("^192%.168%.") or ip:match("^172%.(1[6-9]|2[0-9]|3[0-1])%.") then
        return true
    end
    -- IPv6 special cases
    if ip == "::1" then return true end
    local lc = ip:lower()
    if lc:match("^fc") or lc:match("^fd") or lc:match("^fe80") then return true end
    return false
end

local function get_api_url_for_ip(ip)
    local base = core.settings:get("geoip_on_join.api_url") or
        "http://ip-api.com/json/%s?fields=status,message,country,regionName,city,lat,lon,timezone,isp,query"
    local key = core.settings:get("geoip.api_key") or ""
    if key ~= "" then
        if base:find("%%k") then
            base = base:gsub("%%k", key)
        else
            if base:find("%?") then
                base = base .. "&key=" .. key
            else
                base = base .. "?key=" .. key
            end
        end
    end
    return base:format(ip)
end


local EQUATOR_LEN = 40075696.0
local center = {X=0, Z=0}
local scale = {X=1, Z=1}
function pos_to_ll(x, z)
    local lon = (x * scale.X) / (EQUATOR_LEN / 360) + center.X
    local lat = (z * scale.Z) / (EQUATOR_LEN / 360) + center.Z
    if lat < 90 and lat > -90 and lon < 180 and lon > -180 then
        return { lat = lat, lon = lon }   -- return as a table with named fields
    else
        return { lat = 89.9999, lon = 0 }
    end
end

function ll_to_pos(l)
  local deg2m = EQUATOR_LEN / 360
  local x = (l.lon / scale.X - center.X) * deg2m
  local z = (l.lat / scale.Z - center.Z) * deg2m
  return  {x = x, z = z}
end

-- simple cache: ip -> { data = table or nil, fetched = time() }
local cache = {}
local cache_ttl = tonumber(core.settings:get("geoip.ache_ttl")) or 365*24*3600

local function cache_get(ip)
    local e = cache[ip]
    if not e then return nil end
    if os.time() - (e.fetched or 0) > cache_ttl then
        cache[ip] = nil
        return nil
    end
    return e.data
end

local function cache_set(ip, data)
    cache[ip] = { data = data, fetched = os.time() }
end

local mg_earth = core.settings:get("mg_earth")
local mg_earth_ok, mg_earth_data = pcall(core.parse_json, mg_earth)

local function move_player_to_geo(player, data)
    if data.lat and data.lon then

        local center_y = 0
        if mg_earth_ok and mg_earth_data and mg_earth_data.center then
            data.lon = data.lon - mg_earth_data.center.x
            data.lat = data.lat - mg_earth_data.center.z
            center_y = mg_earth_data.center.y
        end

        local pos = ll_to_pos(data)

        pos.y = core.get_spawn_level(pos.x, pos.z) - center_y
        core.chat_send_player(player:get_player_name(), "Earth: Moving to " .. (data.country or "").. " " .. (data.city or "") .. " : "..pos.x..",".. pos.y .. "," ..pos.z)
        player:set_pos(pos)
		return true
    end
	return false
end


local function do_geo_lookup_for_player(player)
    if not http then
        print("[geoip] HTTP API not available on server; cannot perform GeoIP lookup.")
        return
    end

    local pname = player:get_player_name()
    local raw_ip = (core.get_player_ip and core.get_player_ip(pname)) or ""
    local ip = raw_ip

    if ip == "" then
        --print(pname, "[geoip] Could not retrieve your IP from the server.")
        return
    end

    if is_private_ip(ip) then
        return
    end

    -- Check cache
    local cached = cache_get(ip)
    if cached then
        return move_player_to_geo(player, data)
    end

    local url = get_api_url_for_ip(ip)
    http.fetch({ url = url, timeout = 8 }, function(result)
        if not result or not result.succeeded then
            local err = (result and result.error) and result.error or "unknown error"
            core.chat_send_player(pname, "[geoip] GeoIP request failed: " .. tostring(err))
            print("geo fail", tostring(err))
            return
        end
        print("Player geo: ", ip, result.data)
        local ok, data = pcall(core.parse_json, result.data)
        if not ok or not data then
            --core.chat_send_player(pname, "[geoip] Failed to parse GeoIP response.")
            print("geo fail", data )
            return
        end

        -- Store in cache (even errors are stored to avoid hammering API; store raw response table)
        cache_set(ip, data)

        return move_player_to_geo(player, data)
    end)
    return true
end


--[[
-- Whether automatic lookup is enabled (default true)
local enable_on_join = core.settings:get_bool("geoip_on_join.enable", true)
core.register_on_joinplayer(function(player)
    if not enable_on_join then return end
    -- perform lookup in a safe pcall to avoid crashing on unexpected errors
    local ok, err = pcall(do_geo_lookup_for_player, player)
    if not ok then
        core.log("error", "[geoip_on_join] error during geo lookup for player " .. tostring(player and player:get_player_name()) .. ": " .. tostring(err))
    end
end)
]]

--[[
core.register_chatcommand("mygeo", {
    params = "",
    description = "Run GeoIP lookup for your own IP and print the approximate location to you.",
    func = function(name, _)
        local player = core.get_player_by_name(name)
        if not player then
            return false, "Player not found."
        end
        do_geo_lookup_for_player(player)
        return true, "GeoIP lookup started..."
    end,
})
]]
           
if mg_earth_ok and mg_earth_data and mg_earth_data.center and mg_earth_data.center.x and mg_earth_data.center.z then
elseif core.settings:get("earth_geo_spawn") then
    core.register_on_newplayer(do_geo_lookup_for_player)
    core.register_on_respawnplayer(do_geo_lookup_for_player)
end
