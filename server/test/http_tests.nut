local GLib = import("GLib")
local Soup = import("Soup", "3.0")
local Server = import("../src/http/server.nut")

local opts = {
    repo_dir = "out/repo",
    host = "127.0.0.1",
    port = "0",
}

local repo_server = Server.RepositoryHttpServer(opts)
local server = repo_server.make_soup_server()
server.add_handler("/", function(server_obj, msg, path, query) {
    repo_server.handle_request(server_obj, msg, path, query)
})
server.listen_local(0, Soup.ServerListenOptions.ipv4_only)

local uris = server.get_uris()
assert(uris.len() > 0)
local base_url = uris[0].to_string()
local loop = GLib.MainLoop.new(null, false)
local failed = null

async function run_checks() {
    local session = Soup.Session.new()
    local msg = Soup.Message.new("GET", base_url + "healthz")
    local bytes = await session.send_and_read_async(msg, GLib.PRIORITY_DEFAULT)
    assert(msg.get_status() == 200)
    assert(bytes.get_data().find("\"ok\":true") != null)
    loop.quit()
}

run_checks().catch(function(e) {
    failed = e
    loop.quit()
})

sqgi.timeout_add(3000, function() {
    if (failed == null) failed = "HTTP self-test timed out"
    loop.quit()
    return false
})

loop.run()
if (failed != null) throw failed

return true
