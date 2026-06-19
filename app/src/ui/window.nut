local GLib = import("GLib")
local Gio = import("Gio")
local Gdk = import("Gdk", "4.0")
local Gtk = import("Gtk", "4.0")
local Pango = import("Pango", "1.0")

local Config = import("../config.nut")
local U = import("../util.nut")
local Client = import("../repo/client.nut")
local Manifest = import("../pkg/manifest.nut")
local Solver = import("../pkg/solver.nut")
local Status = import("../pkg/status.nut")
local Transaction = import("../pkg/transaction.nut")
local Sysroot = import("../sysroot/paths.nut")
local PathIntegration = import("../system/path.nut")

local W = {}
local State = {
    settings = null,
    status_db = null,
    index = null,
    selected_name = null,
    package_filter = "all",
    busy = false,
    status_message = "Ready",
    css_loaded = false,
    test_exit_code = 0,
}

function remember(key, value) {
    if (key in W) W[key] = value
    else W[key] <- value
    return value
}

function label(text, xalign = 0.0) {
    local l = Gtk.Label.new(text)
    l.set_xalign(xalign)
    return l
}

function status_label(text, width = 0) {
    local l = label(text, 0.0)
    l.set_single_line_mode(true)
    l.set_ellipsize(Pango.EllipsizeMode.end)
    if (width > 0) l.set_width_chars(width)
    return l
}

function row_label(text, width) {
    local l = label(text, 0.0)
    l.set_width_chars(width)
    return l
}

function hbox(spacing = 6) {
    return Gtk.Box.new(Gtk.Orientation.horizontal, spacing)
}

function vbox(spacing = 6) {
    return Gtk.Box.new(Gtk.Orientation.vertical, spacing)
}

function margins(w, n) {
    w.set_margin_top(n)
    w.set_margin_bottom(n)
    w.set_margin_start(n)
    w.set_margin_end(n)
    return w
}

function text_button(icon_name, text, tooltip = "") {
    local b = Gtk.Button.new()
    local box = hbox(4)
    box.append(Gtk.Image.new_from_icon_name(icon_name))
    box.append(Gtk.Label.new(text))
    b.set_child(box)
    if (tooltip != "") b.set_tooltip_text(tooltip)
    return b
}

function icon_button(icon_name, tooltip) {
    local b = Gtk.Button.new_from_icon_name(icon_name)
    b.set_tooltip_text(tooltip)
    return b
}

function install_css() {
    if (State.css_loaded) return
    local display = Gdk.Display.get_default()
    if (display == null) return

    local provider = Gtk.CssProvider.new()
    local css = "" +
        ".package-state-installed { color: #19703a; font-weight: 700; }\n" +
        ".package-state-available { color: #6b7280; }\n"
    provider.load_from_data(css, css.len())
    Gtk.StyleContext.add_provider_for_display(display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    State.css_loaded = true
}

function icon_search_dirs() {
    local dirs = []
    local resources = GLib.getenv("SQGI_APP_RESOURCES")
    if (resources != null && resources != "") {
        dirs.append(GLib.build_filenamev([resources, "assets", "icons"]))
    }

    local cwd = GLib.get_current_dir()
    dirs.append(GLib.build_filenamev([cwd, "assets", "icons"]))
    dirs.append(GLib.build_filenamev([cwd, "app", "assets", "icons"]))
    return dirs
}

function install_app_icon(win = null) {
    local display = Gdk.Display.get_default()
    if (display == null) return false

    local theme = Gtk.IconTheme.get_for_display(display)
    foreach (dir in icon_search_dirs()) {
        if (U.is_directory(dir)) theme.add_search_path(dir)
    }

    local icon_name = Config.APP_ID
    if (!theme.has_icon(icon_name) && theme.has_icon("ooblerg-icon")) icon_name = "ooblerg-icon"
    if (!theme.has_icon(icon_name)) return false

    Gtk.Window.set_default_icon_name(icon_name)
    if (win != null) win.set_icon_name(icon_name)
    return true
}

function set_status(text) {
    State.status_message = text
    if ("status" in W) W.status.set_text(text)
    update_status_bar()
}

function set_busy(value, text = "") {
    State.busy = value
    if ("spinner" in W) {
        if (value) W.spinner.start()
        else W.spinner.stop()
    }
    if ("activity" in W) {
        W.activity.set_visible(value)
        W.activity.set_fraction(0.0)
        W.activity.set_text(value ? (text == "" ? "Working" : text) : "")
    }
    if (text != "") set_status(text)
    else update_status_bar()
}

function clamp01(value) {
    if (value < 0.0) return 0.0
    if (value > 1.0) return 1.0
    return value
}

function progress_subject(event) {
    if ("package" in event && event.package != "") return event.package
    if ("filename" in event && event.filename != "") return event.filename
    if ("path" in event && event.path != "") return GLib.path_get_basename(event.path)
    return "package"
}

function progress_count_text(event) {
    if ("current" in event && "total" in event && event.total > 0) {
        return " (" + event.current + "/" + event.total + ")"
    }
    return ""
}

function progress_percent_text(event) {
    if (!("fraction" in event)) return ""
    return format("%.0f%%", clamp01(event.fraction).tofloat() * 100.0)
}

function progress_status_text(event) {
    local phase = "phase" in event ? event.phase : "work"
    local subject = progress_subject(event)
    local count = progress_count_text(event)
    local percent = progress_percent_text(event)

    if (phase == "download") {
        local bytes = "bytes" in event ? U.human_size(event.bytes) : ""
        local total = "total" in event && event.total > 0 ? U.human_size(event.total) : "?"
        local tail = percent == "" ? bytes + " / " + total : bytes + " / " + total + "  " + percent
        return "Downloading " + subject + count + ": " + tail
    }
    if (phase == "verify") {
        local tail = percent == "" ? "" : ": " + percent
        return "Verifying " + subject + count + tail
    }
    if (phase == "extract") {
        local tail = percent == "" ? "" : ": " + percent
        return "Extracting " + subject + count + tail
    }
    if (phase == "cleanup") {
        if ("message" in event) return event.message
        return "Cleaning " + subject + count
    }
    if (phase == "manifest") return "Loading manifest " + subject + count
    if (phase == "remove") return "Removing " + subject + count
    if (phase == "status" && "message" in event) return event.message
    if (phase == "prepare" && "message" in event) return event.message
    return "Working on " + subject + count
}

function update_transaction_progress(event) {
    if (event == null) return
    State.busy = true
    local text = progress_status_text(event)
    if ("spinner" in W) W.spinner.start()
    if ("activity" in W) {
        W.activity.set_visible(true)
        local percent = progress_percent_text(event)
        if ("fraction" in event) {
            W.activity.set_fraction(clamp01(event.fraction))
            W.activity.set_text(percent)
        } else {
            W.activity.pulse()
            W.activity.set_text("")
        }
    }
    set_status(text)
}

function append_log(text) {
    if (!("log_buffer" in W)) return
    local end_iter = W.log_buffer.get_end_iter()
    W.log_buffer.insert(end_iter, text, -1)
    local mark = W.log_buffer.get_insert()
    W.log_view.scroll_to_mark(mark, 0.0, false, 0.0, 0.0)
}

function show_error(e) {
    set_busy(false)
    local text = e == null ? "unknown error" : e.tostring()
    set_status("Error: " + text)
    append_log("error: " + text + "\n")
}

function run_task(task) {
    task.catch(function(e) { show_error(e) })
}

function clear_children(container) {
    local child = container.get_first_child()
    while (child != null) {
        container.remove(child)
        child = container.get_first_child()
    }
}

function installed_text(name) {
    if (Status.installed(State.status_db, name)) return "installed"
    return "available"
}

function package_state_label(name) {
    local l = row_label(installed_text(name), 10)
    if (Status.installed(State.status_db, name)) l.add_css_class("package-state-installed")
    else l.add_css_class("package-state-available")
    return l
}

function installed_count() {
    if (State.status_db == null || !("packages" in State.status_db)) return 0
    local n = 0
    foreach (name, item in State.status_db.packages) n++
    return n
}

function visible_package_count() {
    if (!("package_row_names" in W)) return 0
    return W.package_row_names.len()
}

function update_status_bar() {
    if ("status" in W) W.status.set_text(State.status_message)

    if ("status_counts" in W) {
        if (State.index == null || !("packages" in State.index)) {
            W.status_counts.set_text("No repository loaded")
        } else {
            local total = State.index.packages.len()
            local installed = installed_count()
            local shown = visible_package_count()
            W.status_counts.set_text(
                total + " packages  |  " + installed + " installed  |  " +
                (total - installed) + " available  |  " + shown + " shown"
            )
        }
    }

    if ("status_selection" in W) {
        local pkg = selected_package()
        if (pkg == null) W.status_selection.set_text("No package selected")
        else W.status_selection.set_text("Selected: " + pkg.name + " (" + installed_text(pkg.name) + ")")
    }

    if ("status_source" in W) {
        local source = State.settings != null && "source_uri" in State.settings ? State.settings.source_uri : ""
        W.status_source.set_text(source == "" ? "Source not set" : source)
    }

    if ("path_state" in W) {
        local path_ready = PathIntegration.native_ready()
        if ("path_add_button" in W) W.path_add_button.set_sensitive(path_ready)
        if ("path_remove_button" in W) W.path_remove_button.set_sensitive(path_ready)
        if (!path_ready) {
            W.path_state.set_text("Windows PATH integration unavailable")
        } else if (PathIntegration.is_on_user_path()) {
            W.path_state.set_text("mingw64/bin is on user PATH")
        } else {
            W.path_state.set_text("mingw64/bin is not on user PATH")
        }
    }
}

function refresh_path_state(text = "") {
    if (text != "") set_status(text)
    update_status_bar()
}

function add_sysroot_to_path() {
    try {
        PathIntegration.add_to_user_path()
        refresh_path_state("Added mingw64/bin to user PATH")
        append_log("added user PATH entry: " + PathIntegration.mingw_bin_path() + "\n")
    } catch (e) {
        show_error(e)
    }
}

function remove_sysroot_from_path() {
    try {
        PathIntegration.remove_from_user_path()
        refresh_path_state("Removed mingw64/bin from user PATH")
        append_log("removed user PATH entry: " + PathIntegration.mingw_bin_path() + "\n")
    } catch (e) {
        show_error(e)
    }
}

function selected_package() {
    if (State.index == null || State.selected_name == null) return null
    local map = Manifest.package_map(State.index)
    return State.selected_name in map ? map[State.selected_name] : null
}

function split_path(path) {
    local out = []
    local start = 0
    for (local i = 0; i < path.len(); i++) {
        if (path.slice(i, i + 1) == "/") {
            if (i > start) out.append(path.slice(start, i))
            start = i + 1
        }
    }
    if (start < path.len()) out.append(path.slice(start))
    return out
}

function sysroot_rel_path(rel) {
    local parts = [Sysroot.path()]
    foreach (part in split_path(rel)) parts.append(part)
    return GLib.build_filenamev(parts)
}

function make_textview(monospace = false) {
    local view = Gtk.TextView.new()
    view.set_editable(false)
    view.set_cursor_visible(false)
    view.set_wrap_mode(Gtk.WrapMode.word_char)
    view.set_monospace(monospace)
    local scroll = Gtk.ScrolledWindow.new()
    scroll.set_hexpand(true)
    scroll.set_vexpand(true)
    scroll.set_child(view)
    return { view = view, buffer = view.get_buffer(), scroll = scroll }
}

function rebuild_detail() {
    if (!("detail_buffer" in W)) return
    local pkg = selected_package()
    if (pkg == null) {
        W.detail_buffer.set_text("Select a package.", -1)
        update_status_bar()
        return
    }
    local lines = []
    lines.append(pkg.name + " " + pkg.version)
    lines.append(installed_text(pkg.name))
    lines.append("")
    lines.append(Manifest.package_summary(pkg))
    if ("description" in pkg && pkg.description != Manifest.package_summary(pkg)) {
        lines.append("")
        lines.append(pkg.description)
    }
    local deps = Manifest.dependency_names(pkg)
    if (deps.len() > 0) {
        lines.append("")
        lines.append("Dependencies: " + U.join(deps, ", "))
    }
    if ("artifact" in pkg) lines.append("Artifact: " + pkg.artifact)
    if ("size" in pkg) lines.append("Download: " + U.human_size(pkg.size))
    if ("installed_size" in pkg) lines.append("Installed size: " + U.human_size(pkg.installed_size))
    if ("manifest" in pkg) lines.append("Manifest: " + pkg.manifest)
    W.detail_buffer.set_text(U.join(lines, "\n"), -1)
    update_status_bar()
}

function package_matches(pkg, filter) {
    if (filter == "") return true
    local hay = (pkg.name + " " + Manifest.package_summary(pkg)).tolower()
    return hay.find(filter) != null
}

function package_filter_matches(pkg) {
    local installed = Status.installed(State.status_db, pkg.name)
    if (State.package_filter == "installed") return installed
    if (State.package_filter == "available") return !installed
    return true
}

function normalize_package_filter(mode) {
    if (mode == "installed" || mode == "available") return mode
    return "all"
}

function set_package_filter(mode) {
    mode = normalize_package_filter(mode)
    State.package_filter = mode
    if ("filter_mode_buttons" in W) {
        foreach (key, button in W.filter_mode_buttons) {
            local want = key == mode
            if (button.get_active() != want) button.set_active(want)
        }
    }
    rebuild_package_list()
    rebuild_detail()
}

function filter_mode_button(mode, text, group = null) {
    local b = Gtk.ToggleButton.new_with_label(text)
    if (group != null) b.set_group(group)
    b.set_tooltip_text(text + " packages")
    b.connect("toggled", function() {
        if (b.get_active() && State.package_filter != mode) set_package_filter(mode)
    })
    return b
}

function rebuild_package_list() {
    if (!("package_list" in W)) return
    clear_children(W.package_list)
    remember("package_row_names", [])
    remember("package_rows", {})
    W.package_row_names.clear()
    W.package_rows = {}
    if (State.index == null) {
        update_status_bar()
        return
    }
    local filter = "filter_entry" in W ? U.trim(W.filter_entry.get_text()).tolower() : ""

    foreach (pkg in Manifest.sorted_packages(State.index)) {
        if (!package_filter_matches(pkg)) continue
        if (!package_matches(pkg, filter)) continue
        local row = Gtk.ListBoxRow.new()
        W.package_row_names.append(pkg.name)
        W.package_rows[pkg.name] <- row
        local box = hbox(8)
        box.append(package_state_label(pkg.name))
        local name = row_label(pkg.name, 24)
        name.set_tooltip_text(pkg.name)
        box.append(name)
        box.append(row_label(pkg.version, 20))
        local summary = label(Manifest.package_summary(pkg), 0.0)
        summary.set_hexpand(true)
        summary.set_wrap(true)
        box.append(summary)
        row.set_child(margins(box, 4))
        W.package_list.append(row)
    }
    if (State.selected_name != null && !(State.selected_name in W.package_rows)) State.selected_name = null
    update_status_bar()
}

function load_local_state() {
    Config.ensure_dirs()
    State.settings = Config.load_settings()
    State.status_db = Status.load(State.settings.source_uri)
}

async function refresh_repository() {
    set_busy(true, "Refreshing repository")
    await sqgi.sleep(0)
    local uri = U.trim(W.source_entry.get_text())
    State.index = Client.load_index(uri)
    State.settings.source_uri <- uri
    Config.save_settings(State.settings)
    State.status_db.source_uri <- uri
    rebuild_package_list()
    rebuild_detail()
    set_busy(false, "Loaded " + State.index.packages.len() + " packages")
    append_log("loaded index: " + uri + "\n")
}

function plan_change_count(plan) {
    local n = 0
    if (plan != null && "install" in plan) n += plan.install.len()
    if (plan != null && "remove" in plan) n += plan.remove.len()
    if (plan != null && "cleanup" in plan) n += plan.cleanup.len()
    return n
}

function plan_can_apply(plan) {
    if (plan == null) return false
    if ("blocked" in plan && plan.blocked.len() > 0) return false
    return plan_change_count(plan) > 0
}

async function execute_plan(plan) {
    if (plan == null) throw "missing transaction plan"
    local count = plan_change_count(plan)
    if (count == 0) {
        set_status("No package changes are needed")
        return
    }

    local action_text = "Installing packages"
    if (plan.action == "remove") action_text = "Removing packages"
    else if (plan.action == "cleanup") action_text = "Cleaning leftovers"
    set_busy(true, action_text)
    await sqgi.sleep(0)
    State.status_db = await Transaction.apply_async(State.index, State.status_db, State.settings.source_uri, plan,
        function(line) { append_log(line + "\n") },
        function(event) { update_transaction_progress(event) })
    rebuild_package_list()
    rebuild_detail()
    set_busy(false, "Applied " + count + " package changes")
}

function show_plan_dialog(plan, apply_callback = null) {
    local dialog = Gtk.Dialog.new()
    remember("plan_dialog", dialog)
    dialog.set_title("Review Transaction")
    dialog.set_modal(true)
    dialog.set_transient_for(W.win)
    dialog.set_default_size(520, 420)
    dialog.add_button("Close", Gtk.ResponseType.close)
    if (apply_callback != null && plan_can_apply(plan)) {
        dialog.add_button("Apply", Gtk.ResponseType.apply)
    }

    local area = dialog.get_content_area()
    local tv = make_textview(true)
    tv.buffer.set_text(Solver.describe_plan(plan), -1)
    area.append(margins(tv.scroll, 8))
    dialog.connect("response", function(response) {
        dialog.close()
        W.plan_dialog = null
        if (response == Gtk.ResponseType.apply && apply_callback != null) apply_callback()
    })
    dialog.present()
}

function require_selected() {
    local pkg = selected_package()
    if (pkg == null) throw "select a package first"
    return pkg
}

function plan_install_selected() {
    local pkg = require_selected()
    local plan = Solver.install_plan(State.index, State.status_db, [pkg.name])
    show_plan_dialog(plan, function() { run_task(execute_plan(plan)) })
    return plan
}

function plan_remove_selected() {
    local pkg = require_selected()
    local plan = Solver.remove_plan(State.index, State.status_db, [pkg.name])
    show_plan_dialog(plan, function() { run_task(execute_plan(plan)) })
    return plan
}

function plan_cleanup_selected() {
    local pkg = require_selected()
    local plan = Solver.cleanup_plan(State.index, State.status_db, [pkg.name])
    show_plan_dialog(plan, function() { run_task(execute_plan(plan)) })
    return plan
}

function find_package_row(name) {
    if (!("package_list" in W)) return null
    if ("package_rows" in W && name in W.package_rows) return W.package_rows[name]
    return null
}

function row_package_name(row) {
    if (row == null) return null
    if ("package_row_names" in W) {
        local index = row.get_index()
        if (index >= 0 && index < W.package_row_names.len()) return W.package_row_names[index]
    }
    if ("package_rows" in W) {
        foreach (name, candidate in W.package_rows) {
            if (candidate == row) return name
        }
    }
    return null
}

function select_package(name) {
    local row = find_package_row(name)
    if (row == null) return null
    W.package_list.select_row(row)
    State.selected_name = name
    rebuild_detail()
    return row
}

function package_list_count() {
    if (!("package_list" in W)) return 0
    local n = 0
    local child = W.package_list.get_first_child()
    while (child != null) {
        n++
        child = child.get_next_sibling()
    }
    return n
}

function plan_has(items, name) {
    foreach (item in items) {
        if (item.name == name) return true
    }
    return false
}

function close_plan_dialog() {
    if ("plan_dialog" in W && W.plan_dialog != null) {
        W.plan_dialog.close()
        W.plan_dialog = null
    }
}

async function respond_plan_dialog(response) {
    check_gui_test("plan_dialog" in W && W.plan_dialog != null, "transaction review dialog is not open")
    W.plan_dialog.response(response)
    await sqgi.sleep(0)
    check_gui_test(!("plan_dialog" in W) || W.plan_dialog == null, "transaction review dialog did not close")
}

async function wait_for_gui_condition(message, predicate, timeout_ms = 20000) {
    local deadline = GLib.get_monotonic_time() + timeout_ms * 1000
    while (GLib.get_monotonic_time() < deadline) {
        if (predicate()) return
        await sqgi.sleep(50)
    }
    throw message
}

function check_gui_test(condition, message) {
    if (!condition) throw message
}

function widget_text(key) {
    if (!(key in W) || W[key] == null) return ""
    return W[key].get_text()
}

function log_text() {
    if (!("log_buffer" in W) || W.log_buffer == null) return ""
    return W.log_buffer.get_text(W.log_buffer.get_start_iter(), W.log_buffer.get_end_iter(), false)
}

async function drive_gtk_smoke_test(app, options) {
    try {
        local source_uri = "source_uri" in options ? U.trim(options.source_uri) : ""
        local package_name = "test_package" in options ? options.test_package : "native-sdk"
        if (source_uri == "") source_uri = State.settings.source_uri
        W.source_entry.set_text(source_uri)

        await refresh_repository()
        check_gui_test(State.index != null, "repository index was not loaded")
        check_gui_test(State.index.packages.len() > 0, "repository index contains no packages")
        check_gui_test(package_list_count() > 0, "package list did not populate")
        check_gui_test("win" in W && W.win.get_icon_name() == Config.APP_ID,
            "window icon name was not set to " + Config.APP_ID)
        check_gui_test(widget_text("status_counts").find("packages") != null, "status bar package counts did not update")
        check_gui_test(widget_text("status_source").find(source_uri) != null, "status bar source URI did not update")
        check_gui_test(widget_text("path_state").find("PATH") != null, "Windows PATH status did not initialize")

        W.filter_entry.set_text(package_name)
        await sqgi.sleep(0)
        set_package_filter("installed")
        await sqgi.sleep(0)
        check_gui_test(find_package_row(package_name) == null,
            "fresh sysroot unexpectedly showed package in installed filter: " + package_name)
        set_package_filter("available")
        await sqgi.sleep(0)
        check_gui_test(find_package_row(package_name) != null,
            "available filter hid uninstalled package: " + package_name)
        set_package_filter("all")
        await sqgi.sleep(0)
        local row = find_package_row(package_name)
        check_gui_test(row != null, "package row not found after filtering: " + package_name)
        State.selected_name = null
        W.package_list.select_row(row)
        await sqgi.sleep(0)
        check_gui_test(State.selected_name == package_name, "listbox row-selected signal did not update selected package")
        select_package(package_name)
        await sqgi.sleep(0)
        check_gui_test(State.selected_name == package_name, "selected package was not updated")
        check_gui_test(widget_text("status_selection").find(package_name) != null, "status bar selected package did not update")
        local pkg = selected_package()
        check_gui_test(pkg != null && pkg.name == package_name, "selected package lookup failed")

        local install_plan = plan_install_selected()
        check_gui_test(plan_has(install_plan.install, package_name), "install plan does not contain " + package_name)
        if (package_name == "native-sdk") {
            check_gui_test(plan_has(install_plan.install, "gcc"), "native-sdk plan should include gcc")
            check_gui_test(!plan_has(install_plan.install, "busybox-w32"), "native-sdk plan should not include busybox-w32")
        }
        await respond_plan_dialog(Gtk.ResponseType.close)
        check_gui_test(!Status.installed(State.status_db, package_name), "close response unexpectedly installed package")

        install_plan = plan_install_selected()
        await respond_plan_dialog(Gtk.ResponseType.apply)
        await wait_for_gui_condition("package was not marked installed: " + package_name,
            function() { return Status.installed(State.status_db, package_name) })
        check_gui_test(widget_text("status").find("Applied") != null, "status bar did not report applied install")
        local manifest_path = GLib.build_filenamev([Config.package_db_dir(), package_name + ".pkg.json"])
        check_gui_test(U.file_exists(manifest_path), "local package manifest was not written: " + manifest_path)
        local local_manifest = U.read_json(manifest_path)
        local installed_file = null
        if ("files" in local_manifest && local_manifest.files.len() > 0) {
            installed_file = sysroot_rel_path(local_manifest.files[0].path)
            check_gui_test(U.file_exists(installed_file), "installed payload file was not extracted: " + local_manifest.files[0].path)
        }
        rebuild_package_list()
        row = find_package_row(package_name)
        check_gui_test(row != null, "installed package row disappeared: " + package_name)
        set_package_filter("installed")
        await sqgi.sleep(0)
        check_gui_test(find_package_row(package_name) != null,
            "installed filter hid installed package: " + package_name)
        set_package_filter("available")
        await sqgi.sleep(0)
        check_gui_test(find_package_row(package_name) == null,
            "available filter showed installed package: " + package_name)
        set_package_filter("all")
        await sqgi.sleep(0)
        row = find_package_row(package_name)
        check_gui_test(row != null, "package row did not return after switching back to all: " + package_name)
        select_package(package_name)
        await sqgi.sleep(0)
        local remove_plan = plan_remove_selected()
        check_gui_test(plan_has(remove_plan.remove, package_name), "remove plan does not contain " + package_name)
        if (package_name == "native-sdk") {
            check_gui_test(plan_has(remove_plan.remove, "gcc"), "remove plan should include automatic orphan gcc")
        }
        check_gui_test(remove_plan.blocked.len() == 0, "remove plan is unexpectedly blocked")
        await respond_plan_dialog(Gtk.ResponseType.apply)
        await wait_for_gui_condition("package was not removed from status: " + package_name,
            function() { return !Status.installed(State.status_db, package_name) })
        check_gui_test(widget_text("status").find("Applied") != null, "status bar did not report applied remove")
        check_gui_test(!U.file_exists(manifest_path), "local package manifest was not removed: " + manifest_path)
        if (installed_file != null) {
            check_gui_test(!U.file_exists(installed_file), "installed payload file was not removed: " + installed_file)
        }
        set_package_filter("installed")
        await sqgi.sleep(0)
        check_gui_test(find_package_row(package_name) == null,
            "installed filter showed removed package: " + package_name)
        set_package_filter("available")
        await sqgi.sleep(0)
        check_gui_test(find_package_row(package_name) != null,
            "available filter hid removed package: " + package_name)
        set_package_filter("all")

        print("[OK] gtk smoke: loaded " + State.index.packages.len() +
            " packages, installed and removed " + package_name + "\n")
        State.test_exit_code = 0
        app.quit()
    } catch (e) {
        print("[FAIL] gtk smoke: " + e + "\n")
        print("[FAIL] gtk smoke status: " + widget_text("status") + "\n")
        local log = log_text()
        if (log != "") print("[FAIL] gtk smoke log:\n" + log)
        State.test_exit_code = 1
        app.quit()
    }
}

function build_header(root) {
    local bar = hbox(8)
    remember("source_entry", Gtk.Entry.new())
    W.source_entry.set_hexpand(true)
    W.source_entry.set_text(State.settings.source_uri)
    W.source_entry.set_placeholder_text("Repository index URI")
    bar.append(label("Source", 0.0))
    bar.append(W.source_entry)

    local refresh = icon_button("view-refresh-symbolic", "Refresh repository index")
    refresh.connect("clicked", function() { run_task(refresh_repository()) })
    bar.append(refresh)

    remember("spinner", Gtk.Spinner.new())
    bar.append(W.spinner)
    root.append(margins(bar, 8))

    local sysroot_row = hbox(8)
    sysroot_row.append(label("Sysroot", 0.0))
    local sysroot = label(Sysroot.path(), 0.0)
    sysroot.set_selectable(true)
    sysroot.set_hexpand(true)
    sysroot_row.append(sysroot)
    root.append(margins(sysroot_row, 8))

    local path_row = hbox(8)
    path_row.append(label("Windows PATH", 0.0))
    remember("path_state", status_label("", 36))
    W.path_state.set_hexpand(true)
    path_row.append(W.path_state)
    local add_path = text_button("list-add-symbolic", "Add", "Add mingw64/bin to the current user's Windows PATH")
    remember("path_add_button", add_path)
    add_path.connect("clicked", function() { add_sysroot_to_path() })
    path_row.append(add_path)
    local remove_path = text_button("list-remove-symbolic", "Remove", "Remove mingw64/bin from the current user's Windows PATH")
    remember("path_remove_button", remove_path)
    remove_path.connect("clicked", function() { remove_sysroot_from_path() })
    path_row.append(remove_path)
    root.append(margins(path_row, 8))
}

function build_body(root) {
    local pane = hbox(8)
    pane.set_hexpand(true)
    pane.set_vexpand(true)

    local left = vbox(6)
    left.set_hexpand(true)
    left.set_vexpand(true)
    left.set_size_request(720, -1)

    local filter_row = hbox(8)
    remember("filter_entry", Gtk.SearchEntry.new())
    W.filter_entry.set_hexpand(true)
    W.filter_entry.set_placeholder_text("Search packages")
    W.filter_entry.connect("changed", function() { rebuild_package_list() })
    filter_row.append(W.filter_entry)

    local modes = hbox(0)
    modes.add_css_class("linked")
    remember("filter_mode_buttons", {})
    local all_mode = filter_mode_button("all", "All")
    local installed_mode = filter_mode_button("installed", "Installed", all_mode)
    local available_mode = filter_mode_button("available", "Available", all_mode)
    W.filter_mode_buttons["all"] <- all_mode
    W.filter_mode_buttons["installed"] <- installed_mode
    W.filter_mode_buttons["available"] <- available_mode
    modes.append(all_mode)
    modes.append(installed_mode)
    modes.append(available_mode)
    all_mode.set_active(true)
    filter_row.append(modes)
    left.append(filter_row)

    remember("package_list", Gtk.ListBox.new())
    W.package_list.set_selection_mode(Gtk.SelectionMode.single)
    W.package_list.connect("row-selected", function(row) {
        local name = row_package_name(row)
        if (name != null) State.selected_name = name
        rebuild_detail()
    })
    local list_scroll = Gtk.ScrolledWindow.new()
    list_scroll.set_hexpand(true)
    list_scroll.set_vexpand(true)
    list_scroll.set_child(W.package_list)
    left.append(list_scroll)
    pane.append(left)

    local right = vbox(8)
    right.set_size_request(420, -1)
    local details = make_textview(false)
    remember("detail_buffer", details.buffer)
    right.append(details.scroll)

    local actions = hbox(6)
    local install = text_button("list-add-symbolic", "Install", "Install with dependencies")
    install.connect("clicked", function() {
        try { plan_install_selected() } catch (e) { show_error(e) }
    })
    actions.append(install)
    local remove = text_button("list-remove-symbolic", "Remove", "Remove package and automatic orphans")
    remove.connect("clicked", function() {
        try { plan_remove_selected() } catch (e) { show_error(e) }
    })
    actions.append(remove)
    local cleanup = text_button("edit-clear-symbolic", "Clean", "Clean unmanaged files left by failed installs")
    cleanup.connect("clicked", function() {
        try { plan_cleanup_selected() } catch (e) { show_error(e) }
    })
    actions.append(cleanup)
    right.append(actions)

    local log = make_textview(true)
    remember("log_view", log.view)
    remember("log_buffer", log.buffer)
    log.scroll.set_size_request(-1, 130)
    right.append(log.scroll)
    pane.append(right)

    root.append(margins(pane, 8))
}

function build_status(root) {
    root.append(Gtk.Separator.new(Gtk.Orientation.horizontal))

    local bar = hbox(12)
    bar.add_css_class("toolbar")

    remember("status", status_label(State.status_message, 28))
    W.status.set_hexpand(true)
    bar.append(W.status)

    remember("activity", Gtk.ProgressBar.new())
    W.activity.set_show_text(true)
    W.activity.set_size_request(220, -1)
    W.activity.set_visible(false)
    bar.append(W.activity)

    remember("status_counts", status_label("No repository loaded", 36))
    W.status_counts.add_css_class("dim-label")
    bar.append(W.status_counts)

    remember("status_selection", status_label("No package selected", 28))
    W.status_selection.add_css_class("dim-label")
    bar.append(W.status_selection)

    remember("status_source", status_label("", 34))
    W.status_source.add_css_class("dim-label")
    W.status_source.set_hexpand(true)
    bar.append(W.status_source)

    root.append(margins(bar, 8))
    update_status_bar()
}

function create_app(options = null) {
    load_local_state()
    if (options != null && "source_uri" in options && U.trim(options.source_uri) != "") {
        State.settings.source_uri <- U.trim(options.source_uri)
        State.status_db.source_uri <- State.settings.source_uri
    }
    GLib.set_prgname(Config.APP_ID)
    GLib.set_application_name(Config.APP_NAME)

    local app_flags = Gio.ApplicationFlags.flags_none
    if (options != null && "gtk_smoke_test" in options && options.gtk_smoke_test) {
        app_flags = Gio.ApplicationFlags.non_unique
    }
    local app = Gtk.Application.new(Config.APP_ID, app_flags)
    app.connect("activate", function() {
        local win = Gtk.ApplicationWindow.new(app)
        win.set_title(Config.APP_NAME)
        win.set_default_size(1200, 760)
        remember("win", win)
        install_css()
        install_app_icon(win)

        local root = vbox(0)
        win.set_child(root)
        build_header(root)
        build_body(root)
        build_status(root)
        rebuild_package_list()
        rebuild_detail()
        win.present()

        if (options != null && "auto_refresh" in options && options.auto_refresh) {
            sqgi.timeout_add(100, function() {
                run_task(refresh_repository())
                return false
            })
        }
        if (options != null && "gtk_smoke_test" in options && options.gtk_smoke_test) {
            local timeout_ms = "test_timeout_ms" in options ? options.test_timeout_ms : 10000
            sqgi.timeout_add(timeout_ms, function() {
                print("[FAIL] gtk smoke: timed out after " + timeout_ms + "ms\n")
                State.test_exit_code = 1
                app.quit()
                return false
            })
            sqgi.timeout_add(100, function() {
                drive_gtk_smoke_test(app, options)
                return false
            })
        }
    })
    return app
}

function test_exit_code() {
    return State.test_exit_code
}

return {
    create_app = create_app,
    test_exit_code = test_exit_code,
}
