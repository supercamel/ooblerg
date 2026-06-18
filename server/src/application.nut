local GLib = import("GLib")
local Gio = import("Gio")

local Builder = import("repo/builder.nut")

class RepositoryApplication {
    app = null
    builder = null

    constructor(args) {
        this.builder = Builder.RepositoryBuilder()
        this.app = Gio.Application.new(
            "org.ooblerg.repository-server",
            Gio.ApplicationFlags.handles_command_line | Gio.ApplicationFlags.non_unique
        )

        this.add_options()

        this.app.connect("command-line", function(command_line) {
            return this.on_command_line(command_line)
        }.bindenv(this))
    }

    function add_options() {
        this.app.add_main_option("self-test", 0, 0, GLib.OptionArg.none,
            "Run server self-tests", null)
        this.app.add_main_option("rebuild-index", 0, 0, GLib.OptionArg.none,
            "Rebuild repository metadata before exiting or serving", null)
        this.app.add_main_option("serve", 0, 0, GLib.OptionArg.none,
            "Serve the repository over HTTP", null)
        this.app.add_main_option("server", 0, 0, GLib.OptionArg.none,
            "Alias for --serve", null)

        this.app.add_main_option("root", 0, 0, GLib.OptionArg.string,
            "Ooblerg checkout root", "DIR")
        this.app.add_main_option("artifact-dir", 0, 0, GLib.OptionArg.string,
            "Artifact directory", "DIR")
        this.app.add_main_option("repo-dir", 0, 0, GLib.OptionArg.string,
            "Repository output directory", "DIR")
        this.app.add_main_option("host", 0, 0, GLib.OptionArg.string,
            "Host to bind", "HOST")
        this.app.add_main_option("port", 0, 0, GLib.OptionArg.string,
            "Port to bind", "PORT")
        this.app.add_main_option("repository", 0, 0, GLib.OptionArg.string,
            "Repository name", "NAME")
    }

    function has_option(opts, name) {
        return opts.contains(name)
    }

    function string_option(opts, name, fallback) {
        if (!opts.contains(name)) return fallback
        local value = opts.lookup_value(name, null)
        return typeof value == "string" ? value : fallback
    }

    function make_options(opts) {
        return this.builder.normalize_options({
            root = this.string_option(opts, "root", ""),
            artifact_dir = this.string_option(opts, "artifact-dir", "out/artifacts"),
            repo_dir = this.string_option(opts, "repo-dir", "out/repo"),
            host = this.string_option(opts, "host", "127.0.0.1"),
            port = this.string_option(opts, "port", "8787"),
            repository = this.string_option(opts, "repository", "ooblerg-local"),
            packages = [],
        })
    }

    function print_help() {
        print("Ooblerg Package Repository Server\n")
        print("  sqgi server/main.nut --self-test\n")
        print("  sqgi server/main.nut --rebuild-index\n")
        print("  sqgi server/main.nut --serve --rebuild-index\n")
        print("  sqgi server/main.nut --server --rebuild-index\n")
        print("  options: --root=/path/to/ooblerg --artifact-dir=out/artifacts --repo-dir=out/repo --host=127.0.0.1 --port=8787\n")
    }

    function run_self_tests() {
        local root = this.builder.find_root()
        import(GLib.build_filenamev([root, "server", "test", "repo_tests.nut"]))
        import(GLib.build_filenamev([root, "server", "test", "http_tests.nut"]))
        print("[OK] server self-tests passed\n")
        return 0
    }

    function on_command_line(command_line) {
        local opts_dict = command_line.get_options_dict()

        if (this.has_option(opts_dict, "self-test")) {
            return this.run_self_tests()
        }

        local opts = this.make_options(opts_dict)
        local did_action = false

        if (this.has_option(opts_dict, "rebuild-index")) {
            print(this.builder.rebuild(opts))
            did_action = true
        }

        if (this.has_option(opts_dict, "serve") || this.has_option(opts_dict, "server")) {
            local Server = import(GLib.build_filenamev([opts.root, "server", "src", "http", "server.nut"]))
            Server.serve(opts)
            return 0
        }

        if (did_action) return 0

        this.print_help()
        return 0
    }

    function run(args) {
        local argv = ["server/main.nut"]
        foreach (i, arg in args) argv.push(arg)
        return this.app.run(argv.len(), argv)
    }
}

return {
    RepositoryApplication = RepositoryApplication,
}
