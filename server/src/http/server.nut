local GLib = import("GLib")
local Static = import("static.nut")
local Metrics = import("metrics.nut")

local Soup = null
try {
    Soup = import("Soup", "3.0")
} catch (e) {
    Soup = null
}

function send_text(msg, status, content_type, body) {
    msg.set_status(status, null)
    msg.set_response(content_type, Soup.MemoryUse.copy, body)
}

function make_soup_server() {
    if (Soup == null) throw "libsoup 3.0 is not available in this SQGI runtime"
    return sqgi.new_object(Soup.Server, {})
}

class RepositoryHttpServer {
    opts = null
    server = null
    loop = null
    metrics = null

    constructor(opts) {
        this.opts = opts
        if ("metrics_dir" in opts && opts.metrics_dir != "") {
            this.metrics = Metrics.MetricsRecorder(opts.metrics_dir)
        }
    }

    function make_soup_server() {
        return ::make_soup_server()
    }

    function handle_request(server, msg, path, query) {
        local method = msg.get_method()
        local status = Soup.Status.ok
        local bytes = 0
        if (method != "GET" && method != "HEAD") {
            status = Soup.Status.method_not_allowed
            local body = "method not allowed\n"
            bytes = body.len()
            send_text(msg, status, "text/plain", body)
            this.record_request(msg, path, status, bytes)
            return
        }
        if (path == "/healthz") {
            send_text(msg, Soup.Status.ok, "application/json", "{\"ok\":true}\n")
            return
        }
        local resolved = Static.resolve(this.opts.repo_dir, path)
        if (resolved == null) {
            status = Soup.Status.not_found
            local body = "not found\n"
            bytes = body.len()
            send_text(msg, status, "text/plain", body)
            this.record_request(msg, path, status, bytes)
            return
        }
        local body = Static.body(this.opts.repo_dir, resolved)
        bytes = method == "HEAD" ? 0 : body.len()
        send_text(msg, status, resolved.content_type, body)
        this.record_request(msg, path, status, bytes)
    }

    function record_request(msg, path, status, bytes) {
        if (this.metrics == null) return
        try {
            this.metrics.record(msg, path, status, bytes)
        } catch (e) {
            print("metrics write failed: " + e + "\n")
        }
    }

    function serve() {
        this.server = this.make_soup_server()
        this.server.add_handler("/", function(server_obj, msg, path, query) {
            this.handle_request(server_obj, msg, path, query)
        }.bindenv(this))

        local port = this.opts.port.tointeger()
        if (this.opts.host == "127.0.0.1" || this.opts.host == "localhost") {
            this.server.listen_local(port, Soup.ServerListenOptions.ipv4_only)
        } else {
            this.server.listen_all(port, Soup.ServerListenOptions.ipv4_only)
        }
        print("serving " + this.opts.repo_dir + " at http://" + this.opts.host + ":" + this.opts.port + "/\n")
        this.loop = GLib.MainLoop.new(null, false)
        this.loop.run()
    }
}

function handle_request(opts, server, msg, path, query) {
    return RepositoryHttpServer(opts).handle_request(server, msg, path, query)
}

function serve(opts) {
    return RepositoryHttpServer(opts).serve()
}

return {
    RepositoryHttpServer = RepositoryHttpServer,
    serve = serve,
    make_soup_server = make_soup_server,
    handle_request = handle_request,
}
