local FunctionService = require("api/FunctionService")

local ConntrackAPI = FunctionService:new()

require "ubus"
require "uci"

local function process_params(params)
        local newParams         = params;
        newParams.timeout       = tonumber(params.timeout);
        newParams.zone          = tonumber(params.zone);
        newParams["orig-zone"]  = tonumber(params["orig-zone"]);
        newParams["reply-zone"] = tonumber(params["reply-zone"]);
        if newParams.zero ~= nil then
                if newParams.zero == "true" then
                        newParams.zero = true;
                else
                        newParams = false;
                end
        end
        if params.args ~= nil then
                local args = {};
                for arg in string.gmatch(params.args, "([%w:]+),?") do
                        local sep = string.find(arg, ":")
                        table.insert(args, string.sub(arg, 0, sep - 1) .. " " .. string.sub(arg, sep + 1));
                end
                newParams.args = args;
        end
        return newParams;
end

local function parse_conntrack_retval(input)
        if input.errcode == 0 then
                input.errcode = nil;
                input.message = nil;
                for k, v in pairs(input) do
                        return v, false;
                end
        else
                return { code = input.errcode, message = input.message }, true
        end
end

-- GET /api/conntrack/list
-- Returns an array of all the tracked connections.
-- By default, uses the `conntrack` table, however it can be changed.
-- Accepts query parameters, the parameter names are the same as
-- when using the conntrack CLI program, which are the following:
-- * `src`: String, representing the source IP of the connection, allows CIDR notation.
-- * `dst`: String, representing the destination IP of the connection, allows CIDR notation.
-- * `reply-src`: String, representing the reply source IP of the connection
-- * `reply-dst`: String, representing the reply destination IP of the connection
-- * `protocol`: String, representing the layer 4 protocol name (i.e tcp, udp)
-- * `family`: String, representing the layer 3 protocol name (i.e IPv4, IPv6)
-- * `timeout`: Number, representing the time left until the connection is removed
-- * `zone`: Number
-- * `orig-zone`: Number
-- * `reply-zone`: Number
-- * `status`: String, representing the connection status (i.e ASSURED)
-- * `mask-src`: String, representing the source IP mask, used for specifying multiple source IP addresses
-- * `mask-dst`: String, representing the destination IP mask, used for specifying multiple destination IP addresses
-- * `args`: Array, containing the protocol arguments in this format:
--
-- `args=arg1:val1;arg2:val2;...`
--
-- If a provided argument doesn't exist, it is ignored
--
-- Returns error code 422 if the request contains an argument which is recognized,
-- but cannot be used with the request.
-- Returns error code 200 on success.
function ConntrackAPI:GET_TYPE_list()
        local params = process_params(self.query_parameters);
        local conn = ubus.connect();

        if conn == nil then
                return self:ResponseError("Failed to get UBUS instance.");
        end
        local data = conn:call("conntrack", "list_table", params);
        conn:close()
        if data == nil then
                self:ResponseError(
                        "Failed to get a response from conntrack ubus object. Check the system log for more information.");
        end
        local responseObj, errored = parse_conntrack_retval(data);
        if errored then
                self:ResponseError(responseObj);
        end
        return self:ResponseOK(responseObj);
end

function ConntrackAPI:DeleteEntries()
        local conn = ubus.connect();
        if conn == nil then
                self:add_critical_error(422, "Failed to get UBUS instance.", "ubus.connect()")
                return
        end

        local argstype = type(self.arguments.data.args)
        if argstype ~= "nil" and argstype ~= "table" then
                self:add_critical_error(422, "Expected a string array, got ".. type(self.arguments.data.args) .. ".", "")
                return
        end

        
        local result = conn:call("conntrack", "delete_entry", self.arguments.data)
        if result == nil then
                self:add_critical_error(422, "Failed to get a response from conntrack ubus object. Check the system log for more information.", "conn:call()")
                return
        end
        local output = parse_conntrack_retval(result)
        if output.errcode == nil then
                return self:ResponseOK(result)
        end
        self:add_critical_error(422, output, "conntrack-ubus");
        return
end

-- POST /api/conntrack/actions/delete_entries
--
-- This request takes in the following optional JSON body data:
-- * `table` - String, the name of the table to perform the deletion on.
-- If unspecified, defaults to `conntrack`
--
-- The following arguments are for filtering which entries to delete
-- * `src`: String, representing the source IP of the connection, allows CIDR notation.
-- * `dst`: String, representing the destination IP of the connection, allows CIDR notation.
-- * `reply-src`: String, representing the reply source IP of the connection
-- * `reply-dst`: String, representing the reply destination IP of the connection
-- * `protocol`: String, representing the layer 4 protocol name (i.e tcp, udp)
-- * `family`: String, representing the layer 3 protocol name (i.e IPv4, IPv6)
-- * `timeout`: Number, representing the time left until the connection is removed
-- * `zone`: Number
-- * `orig-zone`: Number
-- * `reply-zone`: Number
-- * `status`: String, representing the connection status (i.e ASSURED)
-- * `mask-src`: String, representing the source IP mask, used for specifying multiple source IP addresses
-- * `mask-dst`: String, representing the destination IP mask, used for specifying multiple destination IP addresses
-- * `args`: Array, containing the protocol arguments in this format: [ "arg1 val1", "arg2 val2", [...], ...]
local delete_entries = ConntrackAPI:action("delete_entries", ConntrackAPI.DeleteEntries)
        local table = delete_entries:option("table");
        table.maxlength = 256;

        local src = delete_entries:option("src");
        function src:validate(value)
                local status, _ = self.dt:cidr4(value);
                if not status then
                        status, _ = self.dt:cidr6(value);
                end
                if not status then -- CIDR was not IPv4 nor IPv6
                        status, _ = self.dt:ipaddr(value)
                        if not status then
                                return false, "Invalid IP address provided."
                        end
                end
                return true;
        end

        local dst = delete_entries:option("dst");
        function dst:validate(value)
                local status, _ = self.dt:cidr4(value);
                if not status then
                        status, _ = self.dt:cidr6(value);
                end
                if not status then -- CIDR was not IPv4 nor IPv6
                        status, _ = self.dt:ipaddr(value)
                        if not status then
                                return false, "Invalid IP address provided."
                        end
                end
                return true;
        end

        local rsrc = delete_entries:option("reply-src");
        function rsrc:validate(value)
                return self.dt:ipaddr(value);
        end

        local rdst = delete_entries:option("reply-dst");
        function rdst:validate(value)
                return self.dt:ipaddr(value);
        end

        local protocol = delete_entries:option("protocol")
        protocol.maxlength = 32;        -- Arbitrary limit, however the conntrack API doesn't have 
                                        -- a protocol name that is longer than 32 characters 

        local family = delete_entries:option("family")
        family.maxlength = 32;         -- Arbitrary limit, same reason as above

        local timeout = delete_entries:option("timeout")
        function timeout:validate(value)
                return self.dt:uinteger(value)
        end

        local zone = delete_entries:option("zone")
        function zone:validate(value)
                return self.dt:uinteger(value)
        end

        local origzone = delete_entries:option("orig-zone")
        function origzone:validate(value)
                return self.dt:uinteger(value)
        end

        local replyzone = delete_entries:option("reply-zone")
        function replyzone:validate(value)
                return self.dt:uinteger(value)
        end

        local status = delete_entries:option("status")
        status.maxlength = 64;         -- Arbitrary limit, same reason as above

        local msrc = delete_entries:option("mask-src");
        function msrc:validate(value)
                return self.dt:ipmask(value);
        end

        local mdst = delete_entries:option("mask-dst");
        function mdst:validate(value)
                return self.dt:ipmask(value);
        end

        local args = delete_entries:option("args");
        function args:validate(value)
                if string.find(value, " ") == nil then
                        return false, "Invalid argument " .. value;
                end
                return true
        end

function ConntrackAPI:FlushTable()
        local conn = ubus.connect();
        if conn == nil then
                self:add_critical_error(422, "Failed to get UBUS instance.", "ubus.connect()")
                return
        end
        local table = self.arguments.data.table
        local protocol = self.arguments.data.protocol
        
        local result = conn:call("conntrack", "flush_table", {table = table, protocol = protocol})
        if result == nil then
                self:add_critical_error(422, "Failed to get a response from conntrack ubus object. Check the system log for more information.", "conn:call()")
                return
        end
        -- We don't additionally process anything, as the `flush_table` command
        -- doesn't return anything extra on success.
        if result.errcode == 0 then
                return self:ResponseOK("The " .. table .. " table has been emptied.")
        end
        self:add_critical_error(422, result, "conntrack-ubus");
        return
end

-- POST /api/conntrack/actions/flush_table
--
-- This request takes in the following optional JSON body data:
-- * `table` - String, the name of the table to perform the deletion on.
-- If unspecified, defaults to `conntrack`
-- * `protocol` - String, the layer 4 protocol name to specifically flush entries of. Optional.
local flush_table = ConntrackAPI:action("flush_table", ConntrackAPI.FlushTable)
        local f_table = flush_table:option("table");
        f_table.maxlength = 256;
        local f_protocol = flush_table:option("protocol");
        f_protocol.maxlength = 256;

-- GET /api/conntrack/count_entries
-- The number of tracked connections from a given table
-- By default, uses the `conntrack` table, however it can be changed
-- with the `table` query parameter.
--
-- Returns error code 422 if the request cannot be processed.
-- Returns error code 200 on success.
function ConntrackAPI:GET_TYPE_count_entries()
        local table = self.query_parameters.table;
        local conn = ubus.connect();

        if conn == nil then
                return self:ResponseError("Failed to get UBUS instance.");
        end
        local data = conn:call("conntrack", "count_entries", {table = table});
        conn:close()
        if data == nil then
                self:ResponseError(
                        "Failed to get a response from conntrack ubus object. Check the system log for more information.");
        end
        local responseObj, errored = parse_conntrack_retval(data);
        if errored then
                self:ResponseError(responseObj);
        end
        return self:ResponseOK(responseObj);
end

return ConntrackAPI
