local FunctionService = require("api/FunctionService")

local NetAPI = FunctionService:new()

require "ubus"
require "uci"

-- GET /api/conntrack/list
-- Returns an array of all the tracked connections.
-- By default, uses the `conntrack` table, however it can be changed.


-- GET /api/network/br_interfaces
-- Returns an array of all network devices 
-- as present in UCI config.
-- The format structure of the returned data 
-- Is equivalent to the UCI structure of the
-- network config. 
-- Possible fields for a single interface are:
--
-- (`field_name` - `field_type`)
-- * `device` - `string`
-- * `mtu` - `number`
-- * `auto` - `boolean`
-- * `ipv6` - `boolean`
-- * `force_link` - `boolean`
-- * `disabled` - `boolean`
-- * `ip4table` - `string`
-- * `ip6table` - `string`
-- 
-- Following options MAY be present if the `proto` field is set to `static`:
--
-- (`field_name` - `field_type`)
-- * `interface` - `string`
-- * `ipaddr` - `ip address`
-- * `netmask` - `netmask`
-- * `gateway` - `ip address`
-- * `broadcast` - `ip address`
-- * `ip6addr` - `ipv6 address`
-- * `ip6gw` - `ipv6 address`
-- * `dns` - `list of ip addresses`
-- * `layer` - `integer`
-- Reference: https://openwrt.org/docs/guide-user/network/ucicheatsheet#section_interface
function NetAPI:GET_TYPE_br_interfaces()
        local conn = ubus.connect()
        local conf = uci.cursor()
        if conn == nil or conf == nil then
                return self:ResponseError("Failed to get UBUS or UCI instances.")
        end
        local interfaces_tbl = {}
        if not conf:foreach("network", "interface", function (s)
                local device = conn:call("network.device", "status", {name = s.device})
                if device.type == "bridge" then
                        local newDev = s
                        newDev.internalName = s['.name']
                        for k, v in pairs(s) do
                                if string.sub(k, 0, 1) == "." then
                                        newDev[k] = nil
                                end
                        end
                        newDev.bridgeDevices = device['bridge-members']
                        local bridgeIfs = conf:get("network", string.gsub(s.device, '-', '_'), "ports")
                        newDev.bridgeInterfaces = bridgeIfs
                        table.insert(interfaces_tbl, newDev)
                end
                return true
        end) then
                -- Can't read the network config
                return self:ResponseError("Failed to get interfaces")
        end

        conn:close()
	return self:ResponseOK({
		interfaces = interfaces_tbl
	})
end

-- Line iterator function, courtesy of https://stackoverflow.com/a/19329565 :)
local function line_iterator(s)
        if s:sub(-1)~="\n" then s=s.."\n" end
        return s:gmatch("(.-)\n")
end

local function get_index_for_route(routes, lookup, route)
        local idx = lookup[tostring(route)]
        if idx == nil then
                table.insert(routes, {id = route, routes = {}})
                lookup[tostring(route)] = #routes
                idx = #routes
        end
        return idx
end

-- GET /api/network/get_routes
-- Returns an array of all existing IPv4 routes as present in UCI network config
-- The return structure is as follows:
-- * `id` - The ID of the route as seen in `/etc/iproute2/rt_tables`
-- * `name` - The name of the route as seen in `/etc/iproute2/rt_tables`
-- * `routes` - The routes that the route table contains.
--
-- (Note: the `name` field may not be present if the API failed to
-- read the `rt_tables` file or a route is for a table that is not defined in `rt_tables`)
--
-- The following fields may be present in an element of the routes array:
--
-- (`field_name` - `field_type`)
-- * `interface` - `string`
-- * `target` - `ip address`
-- * `netmask` - `netmask`
-- * `gateway` - `ip address`
-- * `metric` - `number`
-- * `mtu` - `number`
-- * `table` - `routing table`
-- * `source` - `ip address`
-- * `onlink` - `boolean`
-- * `type` - `string`
-- * `proto` - `routing protocol`
-- * `disabled` - `boolean`
--
-- Reference: https://openwrt.org/docs/guide-user/network/ucicheatsheet#section_route
function NetAPI:GET_TYPE_get_routes()
        local conn = ubus.connect()
        local conf = uci.cursor()
        if conn == nil or conf == nil then
                return self:ResponseError("Failed to get UBUS or UCI instances.")
        end
        local resp = conn:call("file", "read", {path = "/etc/iproute2/rt_tables"})
        local lookup = {}
        local routes = {}

        conn:close()
        if resp == nil or resp.data == nil then
                -- Failed to read route table, but maybe we can still get routes.
                if not conf:foreach("network", "route", function (s)
                        local idx = get_index_for_route(routes, lookup, s.table)
                        local info = {}
                        for k, v in pairs(s) do
                                if string.sub(k, 0, 1) ~= "." then
                                        info[k] = v
                                end
                        end
                        table.insert(routes[idx].routes, info)
                end) then
                        -- Can't read routes either.
                        return self:ResponseError("Could not read route tables, and no routes are present (or can't read them)")
                end
                -- This should be a partial success, not sure how or if to report that
	        return self:ResponseOK(routes)
        end
        local contents = string.gsub(resp.data, "\\n", "\n")
        for line in line_iterator(contents) do
                if line ~= nil then
                        if string.sub(line, 0, 1) ~= "#" then
                                local id = string.match(line, "%d+")
                                local name = string.match(line, "\t(.+)")
                                table.insert(routes, {name = name, id = id, routes = {}})
                                lookup[tostring(id)] = #routes;
                        end
                end
        end


        -- Not checking for errors here, if it fails, probably means no rules are present
        conf:foreach("network", "route", function (s)
                local idx = get_index_for_route(routes, lookup, s.table)
                local info = {}
                for k, v in pairs(s) do
                        if string.sub(k, 0, 1) ~= "." then
                                info[k] = v
                        end
                end
                table.insert(routes[idx].routes, info)
        end)

	return self:ResponseOK(routes)
end

-- GET /api/network/get_dhcp_leases
-- Returns an array of all currently connected DHCP clients
-- The individual array element's structure is as follows:
-- * `valid` - For how many seconds is the DHCP lease is valid.
-- * `mac` - The MAC address of the device that owns the lease.
-- * `hostname` - The hostname of the device.
-- * `device` - The network device that the device is connected to.
-- * `active` - If the device that the lease belongs to is connected.
function NetAPI:GET_TYPE_get_dhcp_clients()
        -- Read DHCP leases from ubus `dnsmasq` `ipv4leases`
        -- Get all devices ubus `networkmap` `devices_lan`
        local conn = ubus.connect()
        if conn == nil then
                return self:ResponseError("Failed to get UBUS instance.")
        end
        local resp = conn:call("dnsmasq", "ipv4leases", {})
        if resp == nil then
                return self:ResponseError("Could not get ipv4 DHCP leases.")
        end
        local netmap = conn:call("networkmap", "devices_lan", {})
        local leases = {}
        local devices = {}
        if netmap ~= nil then
                for i, device in ipairs(netmap.devices) do
                        devices[device.mac] = true
                end
        end -- If netmap is nil, it's a partial error, can still continue,
            -- as at this point we still have DHCP leases
        for i, lease in ipairs(resp.leases) do
                local activeDevice
                if devices[lease.mac] == true then activeDevice = true else activeDevice = false end
                table.insert(leases, {valid = lease.valid, mac = lease.mac, hostname = lease.hostname, device = lease.device, active = activeDevice})
        end
        conn:close()

	return self:ResponseOK(leases)
end

function NetAPI:UpdateBridge()
        local interface = self.arguments.data.interface
        local mtu = self.arguments.data.mtu
        local name = self.arguments.data.name
        local mac = self.arguments.data.macaddr
        local config = uci.cursor()
        if config == nil then
                self:add_critical_error(500, "Failed to get UCI instance.", "uci.cursor()")
                return
        end

        local changes = 0
        if mtu ~= nil then
                if mtu == 0 then
                        config:delete("network", interface, "mtu")
                else
                        local devName = config:get("network", interface, "device")
                        config:set("network", string.gsub(devName, '-', '_'), "mtu", mtu)
                end
                changes = changes + 1
        end

        if name ~= nil then
                name = string.gsub(name, "[^A-Za-z0-9_]", "")
                config:set("network", interface, "name", name)
                changes = changes + 1
        end

        if mac ~= nil then
                local devName = config:get("network", interface, "device")
                config:set("network", string.gsub(devName, '-', '_'), "macaddr", mac)
                changes = changes + 1
        end

        if changes > 0 then
                config:commit("network")
                local conn = ubus.connect()
                if config == nil then
                        self:add_critical_error(500, "Failed to get UBUS instance.", "ubus.connect()")
                        return
                end
                conn:call("uci", "reload_config", {})
                conn:close()
        end

	return self:ResponseOK({
		result = "Updated " .. changes .. " values",
	})
end

-- POST /api/network/actions/update_bridge
-- This request takes in the following JSON body data:
-- ```
-- {
--      "data": {
--              "interface": "interface_name",
--              "mtu": new_interface_mtu_value,
--              "name": "new_interface_display_name",
--              "mac": "new_interface_mac_address",
--      }
-- }
-- ```
-- `mtu`, `name`, `mac` fields are optional.
-- `interface` field is requried. A string of a-Z, 0-9 and _ characters is accepted in the `name` field. 
-- Any other characters will be removed.
--
-- After request is complete, the UCI network config will be modified
-- to the provided new values and the network service will be reloaded.
-- If only `interface` field is provided, nothing will be changed and 
-- the network service will not be reloaded. 
local test_action = NetAPI:action("update_bridge", NetAPI.UpdateBridge)
	local interface = test_action:option("interface")
        interface.require = true
        interface.maxlength = 256

        local mtu = test_action:option("mtu")
        function mtu:validate(value)
                return self.dt:uinteger(value)
        end

        local name = test_action:option("name")
        name.maxlength = 256

        local mac = test_action:option("macaddr")
        function mac:validate(value)
                local valid, msg = self.dt:macaddr(value)
                if valid then
                        if string.sub(value, 0, 2) == "00" then
                                return true
                        else
                                return false, "Unicast MAC address is allowed (e.g., 00:23:45:67:89:AB)."
                        end
                end
                return false, msg
        end

function NetAPI:RenameBridgeDevice()
        local old = self.arguments.data.oldDevice
        old = string.gsub(old, "[^A-Za-z0-9_%-]", "")
        local oldUCI = string.gsub(old, '-', '_')

        local new = self.arguments.data.newDevice
        new = string.gsub(new, "[^A-Za-z0-9_%-]", "")
        local newUCI = string.gsub(new, '-', '_')

        local config = uci.cursor()
        if config == nil then
                self:add_critical_error(500, "Failed to get UCI instance.", "uci.cursor()")
                return
        end

        local found = false
        config:set("network", newUCI, "device")
        if not config:foreach("network", "device", function (s)
                if s['.name'] == oldUCI then
                        for k, v in pairs(s) do
                                if string.sub(k, 0, 1) ~= "." then
                                        config:set("network", newUCI, k, v)
                                end
                        end
                        found = true
                end
        end) then
                self:add_error(500, "No configured devices found.", "config:set(\"network\", newUCI, \"device\")")
                return
        end
        if found == true then
                config:set("network", newUCI, "name", new)

                config:delete("network", oldUCI)

                -- If this fails, no interfaces are present/configured
                config:foreach("network", "interface", function (s)
                        if s.device == old then
                                config:set("network", s['.name'], "device", new)
                        end
                end)

                config:commit("network")
                local conn = ubus.connect()
                if config == nil then
                        self:add_critical_error(500, "Failed to get UBUS instance.", "ubus.connect()")
                        return
                end
                conn:call("uci", "reload_config", {})
                conn:close()
                
                return self:ResponseOK({
		        result = "Internal name changed successfully",
	        })
        end

	return self:ResponseError("Could not find given device")
end

-- POST /api/network/actions/rename_bridge
-- This request takes in the following JSON body data:
-- ```
-- {
--      "data": {
--              "oldDevice": "old_bridge_device_name",
--              "newDevice": "new_bridge_device_name",
--      }
-- }
-- ```
-- `oldDevice` and `newDevice` fields are requried.
-- 
-- * `oldDevice` represents the old bridge device name 
-- as seen in the `device` field of the `bridge_interfaces` GET request
-- * `newDevice` represents the new bridge device name
--
-- A string of a-Z, 0-9 and characters are accepted in the `oldDevice` and `newDevice fields. 
-- Internally, `-` characters are replaced to `_` as per the UCI spec:
-- https://openwrt.org/docs/guide-user/base-system/uci#sections_naming
-- It is recommended to use the device names as seen in the `bridge_interfaces` GET request, as that is
-- what is used to find and update the interfaces.
-- Any other characters will be removed.
local test_action = NetAPI:action("rename_bridge", NetAPI.RenameBridgeDevice)
	local oldDevice = test_action:option("oldDevice")
        oldDevice.require = true
        oldDevice.maxlength = 256

	local newDevice = test_action:option("newDevice")
        newDevice.require = true
        newDevice.maxlength = 256


return NetAPI
