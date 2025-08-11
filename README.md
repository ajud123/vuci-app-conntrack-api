# vuci-app-conntrack-api
This projects implements conntrack api for use with the web API on Teltonika routers. Main dependency is the [conntrack-ubus](https://github.com/ajud123/conntrack-ubus) package, as the web api calls ubus methods from the package.
The web API exposes the following methods:

---
### GET /api/conntrack/list
Returns an array of all the tracked connections.
By default, uses the `conntrack` table, however it can be changed.
Accepts query parameters, the parameter names are the same as
when using the conntrack CLI program, which are the following:
* `src`: String, representing the source IP of the connection, allows CIDR notation.
* `dst`: String, representing the destination IP of the connection, allows CIDR notation.
* `reply-src`: String, representing the reply source IP of the connection
* `reply-dst`: String, representing the reply destination IP of the connection
* `protocol`: String, representing the layer 4 protocol name (i.e tcp, udp)
* `family`: String, representing the layer 3 protocol name (i.e IPv4, IPv6)
* `timeout`: Number, representing the time left until the connection is removed
* `zone`: Number
* `orig-zone`: Number
* `reply-zone`: Number
* `status`: String, representing the connection status (i.e ASSURED)
* `mask-src`: String, representing the source IP mask, used for specifying multiple source IP addresses
* `mask-dst`: String, representing the destination IP mask, used for specifying multiple destination IP addresses
* `args`: Array, containing the protocol arguments in this format:

`args=arg1:val1;arg2:val2;...`

If a provided argument doesn't exist, it is ignored

Returns error code 422 if the request contains an argument which is recognized,
but cannot be used with the request.
Returns error code 200 on success.

---
### POST /api/conntrack/actions/delete_entries
This request takes in the following optional JSON body data:
* `table` - String, the name of the table to perform the deletion on.
If unspecified, defaults to `conntrack`

The following arguments are for filtering which entries to delete
* `src`: String, representing the source IP of the connection, allows CIDR notation.
* `dst`: String, representing the destination IP of the connection, allows CIDR notation.
* `reply-src`: String, representing the reply source IP of the connection
* `reply-dst`: String, representing the reply destination IP of the connection
* `protocol`: String, representing the layer 4 protocol name (i.e tcp, udp)
* `family`: String, representing the layer 3 protocol name (i.e IPv4, IPv6)
* `timeout`: Number, representing the time left until the connection is removed
* `zone`: Number
* `orig-zone`: Number
* `reply-zone`: Number
* `status`: String, representing the connection status (i.e ASSURED)
* `mask-src`: String, representing the source IP mask, used for specifying multiple source IP addresses
* `mask-dst`: String, representing the destination IP mask, used for specifying multiple destination IP addresses
* `args`: Array, containing the protocol arguments in this format: [ "arg1 val1", "arg2 val2", [...], ...]

---
### POST /api/conntrack/actions/flush_table
This request takes in the following optional JSON body data:
* `table` - String, the name of the table to perform the deletion on.
If unspecified, defaults to `conntrack`
* `protocol` - String, the layer 4 protocol name to specifically flush entries of. Optional.

---
### GET /api/conntrack/count_entries
The number of tracked connections from a given table
By default, uses the `conntrack` table, however it can be changed
with the `table` query parameter.

Returns error code 422 if the request cannot be processed.
Returns error code 200 on success.
