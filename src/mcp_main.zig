//! kuri-mcp — a Model Context Protocol (stdio JSON-RPC 2.0) server that exposes
//! kuri's browser automation as MCP tools, with chrome-devtools-mcp-compatible
//! tool names. It forwards each tool call to a running kuri HTTP server
//! (KURI_BASE, default http://127.0.0.1:8080; optional KURI_SECRET bearer auth),
//! so an MCP agent gets kuri's COMPACT accessibility snapshot — far fewer tokens
//! than chrome-devtools-mcp's take_snapshot for the same page.
//!
//! Transport: newline-delimited JSON-RPC over stdin/stdout (std.Io, no libc).

const std = @import("std");

var g_base: []const u8 = "http://127.0.0.1:8080";
var g_secret: ?[]const u8 = null;
var g_out: ?*std.Io.Writer = null;
/// The allocator handed to `main` by the runtime. Stored globally because the
/// fetch watchdog thread in `kuriGet` must allocate an arena that OUTLIVES the
/// per-message arena, and the thread signature has nowhere to thread a second
/// allocator through. See the ownership note in `kuriGet`.
var g_gpa: std.mem.Allocator = undefined;

/// Outcome of a fetch that must never itself return an error union, because it
/// runs on a watchdog thread and reports through shared state.
const Result = union(enum) {
    body: []const u8,
    err: anyerror,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    g_gpa = gpa;
    const env = init.environ_map;
    if (env.get("KURI_BASE")) |b| g_base = b;
    g_secret = env.get("KURI_SECRET");

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Publish it: `kuriGet` waits on a Condition through this exact instance.
    g_main_io = io;

    const line_buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(line_buf);
    const in_rbuf = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(in_rbuf);
    const out_wbuf = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(out_wbuf);

    var fr = std.Io.File.stdin().reader(io, in_rbuf);
    var fw = std.Io.File.stdout().writer(io, out_wbuf);
    g_out = &fw.interface;
    const r = &fr.interface;

    while (readLine(r, line_buf)) |line| {
        if (line.len == 0) continue;
        var arena_impl = std.heap.ArenaAllocator.init(gpa);
        defer arena_impl.deinit();
        handleMessage(arena_impl.allocator(), line);
    }
}

// Protocol versions we support, newest first. We echo the client's requested
// version when recognized (old clients reject a newer version than they sent).
const supported_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

fn negotiateProtocolVersion(requested: []const u8) []const u8 {
    if (requested.len == 0) return supported_versions[0];
    for (supported_versions) |v| if (std.mem.eql(u8, v, requested)) return v;
    // Unknown: future date => our newest; older => our oldest known.
    if (std.mem.order(u8, requested, supported_versions[0]) == .gt) return supported_versions[0];
    return supported_versions[supported_versions.len - 1];
}

fn handleMessage(arena: std.mem.Allocator, line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, trimmed, .{}) catch {
        respondError(arena, null, -32700, "Parse error");
        return;
    };
    if (parsed.value != .object) {
        respondError(arena, null, -32600, "Invalid Request");
        return;
    }
    const obj = parsed.value.object;
    const id_val = obj.get("id");
    const method = strField(obj, "method") orelse return;

    if (std.mem.eql(u8, method, "initialize")) {
        // Negotiate: echo the client's requested protocolVersion when known.
        var requested: []const u8 = "";
        if (obj.get("params")) |p| if (p == .object) {
            if (strField(p.object, "protocolVersion")) |rv| requested = rv;
        };
        const ver = negotiateProtocolVersion(requested);
        const result = std.fmt.allocPrint(arena, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"kuri\",\"version\":\"{s}\"}}}}", .{ ver, @import("build_options").version }) catch return;
        respondRaw(arena, id_val, result);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        if (id_val != null) respondRaw(arena, id_val, tools_list_json);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        callTool(arena, obj, id_val);
    } else if (std.mem.eql(u8, method, "ping")) {
        if (id_val != null) respondRaw(arena, id_val, "{}");
    } else if (std.mem.startsWith(u8, method, "notifications/")) {
        // no response
    } else if (id_val != null) {
        respondError(arena, id_val, -32601, "Method not found");
    }
}

fn callTool(arena: std.mem.Allocator, obj: std.json.ObjectMap, id_val: ?std.json.Value) void {
    const params = obj.get("params");
    if (params == null or params.? != .object) return respondError(arena, id_val, -32602, "invalid params");
    const p = params.?.object;
    const name = strField(p, "name") orelse return respondError(arena, id_val, -32602, "missing tool name");
    const args: ?std.json.ObjectMap = if (p.get("arguments")) |av| (if (av == .object) av.object else null) else null;

    // Map chrome-devtools-mcp-compatible tool names to kuri HTTP endpoints.
    if (std.mem.eql(u8, name, "navigate_page")) {
        const url = argStr(args, "url") orelse return toolError(arena, id_val, "missing 'url'");
        forward(arena, id_val, "/navigate", &.{.{ "url", url }}, true);
    } else if (std.mem.eql(u8, name, "take_snapshot")) {
        var buf: [3]Param = undefined;
        buf[0] = .{ "format", "compact" };
        var n: usize = 1;
        if (argStr(args, "uid")) |uid| {
            buf[n] = .{ "scope", uid };
            n += 1;
        }
        if (argNumStr(arena, args, "limit")) |lim| {
            buf[n] = .{ "limit", lim };
            n += 1;
        }
        forward(arena, id_val, "/snapshot", buf[0..n], true);
    } else if (std.mem.eql(u8, name, "take_snapshot_diff")) {
        if (argNumStr(arena, args, "limit")) |lim| {
            forward(arena, id_val, "/diff/snapshot", &.{.{ "limit", lim }}, true);
        } else {
            forward(arena, id_val, "/diff/snapshot", &.{}, true);
        }
    } else if (std.mem.eql(u8, name, "get_page_state")) {
        forward(arena, id_val, "/page/state", &.{}, true);
    } else if (std.mem.eql(u8, name, "click")) {
        const uid = argStr(args, "uid") orelse return toolError(arena, id_val, "missing 'uid'");
        forward(arena, id_val, "/action", &.{ .{ "action", "click" }, .{ "ref", uid } }, true);
    } else if (std.mem.eql(u8, name, "fill")) {
        const uid = argStr(args, "uid") orelse return toolError(arena, id_val, "missing 'uid'");
        const value = argStr(args, "value") orelse "";
        forward(arena, id_val, "/action", &.{ .{ "action", "fill" }, .{ "ref", uid }, .{ "value", value } }, true);
    } else if (std.mem.eql(u8, name, "hover")) {
        const uid = argStr(args, "uid") orelse return toolError(arena, id_val, "missing 'uid'");
        forward(arena, id_val, "/action", &.{ .{ "action", "hover" }, .{ "ref", uid } }, true);
    } else if (std.mem.eql(u8, name, "type_text")) {
        const text = argStr(args, "text") orelse return toolError(arena, id_val, "missing 'text'");
        forward(arena, id_val, "/keyboard/type", &.{.{ "text", text }}, true);
    } else if (std.mem.eql(u8, name, "evaluate_script")) {
        const expr = argStr(args, "expression") orelse argStr(args, "function") orelse return toolError(arena, id_val, "missing 'expression'");
        forward(arena, id_val, "/evaluate", &.{.{ "expression", expr }}, true);
    } else if (std.mem.eql(u8, name, "take_screenshot")) {
        forward(arena, id_val, "/screenshot", &.{.{ "save", "true" }}, true);
    } else if (std.mem.eql(u8, name, "list_pages")) {
        forward(arena, id_val, "/tabs", &.{}, false);
    } else if (std.mem.eql(u8, name, "new_page")) {
        const url = argStr(args, "url") orelse "about:blank";
        forward(arena, id_val, "/tab/new", &.{.{ "url", url }}, false);
    } else if (std.mem.eql(u8, name, "list_network_requests")) {
        forward(arena, id_val, "/har/replay", &.{}, true);
    } else if (std.mem.eql(u8, name, "wait_for")) {
        const text = argStr(args, "text") orelse return toolError(arena, id_val, "missing 'text'");
        forward(arena, id_val, "/find", &.{.{ "text", text }}, true);
    } else {
        respondError(arena, id_val, -32602, "unknown tool");
    }
}

const Param = struct { []const u8, []const u8 };

/// Resolve the current/first tab id from GET /tabs (kuri page-scoped endpoints
/// need an explicit tab_id since each forwarded request is a fresh connection).
fn resolveTabId(arena: std.mem.Allocator) ?[]const u8 {
    const url = std.fmt.allocPrint(arena, "{s}/tabs", .{g_base}) catch return null;
    // ⚠️ THIS CALL IS BUDGETED, AND IT IS NOT OBVIOUS FROM HERE.
    //
    // `kuriGet` waits up to REQUEST_BUDGET_MS for a reply. A `with_tab` tool call
    // makes TWO of them — this tab lookup, then the real request in `forward` —
    // so a hung server costs 2x the budget for ONE tool call. Measured: 64s for
    // `get_page_state`, i.e. two 30s waits back to back. If a third lookup is
    // ever added to this path, that multiplies again, which is why the budget is
    // named rather than written as a literal in the fetch.
    //
    // The `catch return null` below SWALLOWS the timeout: a hung server makes
    // this return null, so `forward` proceeds WITHOUT a tab_id and the caller
    // sees whatever that produces — not a timeout message. That is deliberate
    // (a missing tab is a legitimate state and callers handle it), but it means
    // an operator seeing a tab-scoped error should not assume the server
    // answered.
    const body = kuriGet(arena, url) catch return null;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return null;
    if (parsed.value != .array) return null;
    const arr = parsed.value.array;
    if (arr.items.len == 0) return null;
    const first = arr.items[0];
    if (first != .object) return null;
    const idv = first.object.get("id") orelse return null;
    return switch (idv) {
        .string => |s| arena.dupe(u8, s) catch null,
        else => null,
    };
}

/// GET {base}{path}?k=v&... from the kuri server; return its body as MCP text.
/// When `with_tab`, a resolved tab_id is added so page-scoped endpoints work.
fn forward(arena: std.mem.Allocator, id_val: ?std.json.Value, path: []const u8, params: []const Param, with_tab: bool) void {
    var url: std.ArrayListUnmanaged(u8) = .empty;
    url.appendSlice(arena, g_base) catch return;
    url.appendSlice(arena, path) catch return;
    var first = true;
    if (with_tab) {
        if (resolveTabId(arena)) |tab| {
            url.appendSlice(arena, "?tab_id=") catch return;
            urlencode(&url, arena, tab) catch return;
            first = false;
        }
    }
    for (params) |kv| {
        url.appendSlice(arena, if (first) "?" else "&") catch return;
        first = false;
        url.appendSlice(arena, kv[0]) catch return;
        url.append(arena, '=') catch return;
        urlencode(&url, arena, kv[1]) catch return;
    }
    const body = kuriGet(arena, url.items) catch |err| {
        return toolError(arena, id_val, @errorName(err));
    };
    toolText(arena, id_val, body);
}

fn kuriGet(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    // ══════════════════════════════════════════════════════════════════════
    // REVISIT WHEN ZIG ADDS A REQUEST TIMEOUT — see the long note below.
    // ══════════════════════════════════════════════════════════════════════
    //
    // A hung kuri server must not hang this MCP server forever, so the fetch is
    // bounded by a watchdog thread. That is a WORKAROUND for a missing stdlib
    // capability, not a design choice, and the point of this comment is that a
    // future reader can find it and delete it.
    //
    // ── WHAT IS MISSING, AND WHERE ────────────────────────────────────────
    //
    // Zig's HTTP client has NO timeout for reading a response. Verified against
    // the actual source, not the docs:
    //
    //   · Zig 0.17.0  —  lib/std/http/Client.zig
    //   · Zig 0.18.0-dev.253+16d31ceed (master at the time of writing)
    //
    // In BOTH, `RequestOptions` — what `Client.request` and `Request.receiveHead`
    // take — has no timeout field at all. The whole file contains exactly ONE
    // `timeout`, on `ConnectTcpOptions`:
    //
    //     pub const ConnectTcpOptions = struct {
    //         ...
    //         timeout: Io.Timeout = .none,   // <-- CONNECT ONLY
    //     };
    //
    // So a server that ACCEPTS the TCP connection and then never responds cannot
    // be timed out through the client API at any version available today. The
    // lower-level `Socket.receiveManyTimeout` does accept `Io.Timeout`, but
    // `Client.request` does not expose the socket, and reaching it would mean
    // hand-rolling the HTTP request in this file.
    //
    // ── HOW TO DETECT THAT THIS IS FIXED ──────────────────────────────────
    //
    //     rg -n 'timeout' lib/std/http/Client.zig
    //
    // If that reports more than one match — specifically, if `RequestOptions`
    // grows a `timeout` or `deadline` field — replace this whole function with a
    // single `client.request(...)` carrying that field, and delete the watchdog:
    //
    //     client.request(.GET, uri, .{ .timeout = .{ .duration = REQUEST_TIMEOUT } })
    //
    // Until then, this is the only way to bound it.
    //
    // ── WHY THE SYMPTOM IS WORSE THAN A HANG ──────────────────────────────
    //
    // Without this, `kuri-mcp` blocks indefinitely and writes NO JSON-RPC
    // response. pi waits behind it, so the failure looks like pi being broken
    // rather than a tool that never returned: no output, no error, no exit.
    //
    // Observed against a listener that accepts and never replies. A REFUSED
    // connection, by contrast, returns `ConnectionRefused` immediately and
    // correctly — so only the hung case was unbounded, which is also the case a
    // wedged browser produces. Defect register FI-38.
    //
    // ── HOW THE WATCHDOG WORKS ────────────────────────────────────────────
    //
    // The fetch runs on a spawned thread; this thread waits on a condition with
    // a deadline and returns `error.RequestTimeout` if it expires.
    //
    // ⚠️ MEMORY OWNERSHIP IS THE PART THAT IS EASY TO GET WRONG HERE, so it is
    // stated explicitly: the fetch thread allocates its OWN arena from `gpa` and
    // **frees it before signalling**. It hands back only a body it has duped
    // into `gpa`. The consumer therefore never touches thread-owned memory, and
    // a thread that is still blocked when the deadline expires cannot be reading
    // memory the caller has already released — which is exactly the
    // use-after-free that a first draft of this had when the thread borrowed the
    // caller's per-message arena.
    //
    // The remaining cost is real and accepted: on timeout the fetch thread is
    // DETACHED and keeps blocking until its socket read finishes or the process
    // exits, holding its arena. Bounded by the number of timeouts, and bounded
    // again by the process, which lives for one pi session. A detached thread
    // blocked in a syscall cannot be cancelled safely in any portable way, so
    // "join harder" is not an available improvement; the real fixes are a
    // subprocess fetch, or the stdlib field above.

    const FetchCtx = struct {
        gpa: std.mem.Allocator,
        url: []const u8,
        /// Duped into gpa; the CONSUMER owns this after a successful wait.
        body: ?[]u8 = null,
        err: ?anyerror = null,
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        done: bool = false,

        fn run(ctx: *@This()) void {
            // Arena lives entirely inside this thread and dies before signalling.
            var arena_impl = std.heap.ArenaAllocator.init(ctx.gpa);
            defer arena_impl.deinit();
            const scratch = arena_impl.allocator();

            // A `Threaded` per thread, created and destroyed here: it owns the
            // io implementation this thread's syscalls go through, so it must
            // not be shared with the main thread.
            var threaded: std.Io.Threaded = .init(ctx.gpa, .{});
            defer threaded.deinit();
            const self_io = threaded.io();

            const got = kuriGetUnbounded(scratch, ctx.url, self_io);

            ctx.mutex.lockUncancelable(self_io);
            defer ctx.mutex.unlock(self_io);
            switch (got) {
                // Copy out of the arena: it is freed by `defer` on the way out
                // of this frame, after the consumer has been signalled.
                .body => |b| ctx.body = ctx.gpa.dupe(u8, b) catch null,
                .err => |e| ctx.err = e,
            }
            ctx.done = true;
            ctx.cond.signal(self_io);
        }
    };

    var ctx = FetchCtx{ .gpa = g_gpa, .url = url };

    const thread = std.Thread.spawn(.{}, FetchCtx.run, .{&ctx}) catch |err| {
        // Could not spawn: fall back to an unbounded call rather than failing a
        // tool the caller legitimately asked for. Logged so it is not silent —
        // an unbounded request is exactly the failure this function exists to
        // prevent, so reaching here means the protection is off for this call.
        std.log.warn("kuri-mcp: watchdog thread spawn failed ({s}); request is unbounded", .{@errorName(err)});
        return switch (kuriGetUnbounded(arena, url, mainIo())) {
            .body => |b| b,
            .err => |e| e,
        };
    };
    thread.detach();

    // ── WHY A POLL LOOP AND NOT `Condition.waitTimeout` ──────────────────
    //
    // The first implementation used `ctx.cond.waitTimeout(io, &ctx.mutex,
    // REQUEST_TIMEOUT)`, which is the idiomatic form and compiles cleanly. It
    // DID NOT FIRE: the fixed binary ran a 50s cap to completion against a
    // never-replying listener, i.e. it still hung. `waitTimeout` is built on
    // `io.futexWaitTimeout`, and a futex wait woken by a signal from a DIFFERENT
    // `Threaded` instance — which is what the fetch thread is — is not
    // guaranteed to observe it.
    //
    // Rather than fight obscure cross-instance futex semantics, this polls the
    // `done` flag under the same mutex. It cannot silently fail to wake: every
    // iteration re-reads the flag, so a signal is observed on the next tick
    // regardless of which io signalled it. The cost is one wake per interval.
    //
    // ⚠️ Verified by A/B against the pre-fix binary. If you change this back to
    // a condition wait, RE-RUN that test — `waitTimeout` returning without error
    // is not evidence that it times out.
    const POLL_INTERVAL: std.Io.Duration = .fromMilliseconds(100);
    // Ticks x interval = the budget for ONE fetch. 300 x 100ms = 30s.
    //
    // ⚠️ THIS IS PER FETCH, NOT PER TOOL CALL. `resolveTabId` fetches too, so a
    // `with_tab` tool call can wait twice this. See the note in `resolveTabId`.
    // Measured end to end: `get_page_state` against a hung server returned
    // `RequestTimeout` after 64s, not 30s.
    const TICKS_BEFORE_TIMEOUT: u32 = 300;
    var ticks: u32 = 0;
    while (true) {
        ctx.mutex.lockUncancelable(mainIo());
        if (ctx.done) {
            const owned = ctx.body;
            const failed = ctx.err;
            ctx.mutex.unlock(mainIo());
            if (failed) |e| {
                if (owned) |b| g_gpa.free(b);
                return e;
            }
            const b = owned orelse return error.EmptyResponse;
            defer g_gpa.free(b);
            // Copy into the caller's arena, which is what it asked for.
            return arena.dupe(u8, b);
        }
        ctx.mutex.unlock(mainIo());

        ticks += 1;
        if (ticks >= TICKS_BEFORE_TIMEOUT) return error.RequestTimeout;
        std.Io.sleep(mainIo(), POLL_INTERVAL, .awake) catch {
            // A cancelled sleep must not spin the loop hot; treat it as one tick
            // of progress, which the counter above already accounts for.
        };
    }
}

/// The io this process actually runs on, set once by `main`.
///
/// ⚠️ IT MUST BE THE SAME INSTANCE `main` USES. A first version of this declared
/// its own `std.Io.Threaded = .init_single_threaded`, which is a DIFFERENT
/// instance from the one `main` builds — and a `Mutex`/`Condition` waited on
/// through a foreign io never wakes, so the 30s timeout silently never fired and
/// the hang this change exists to remove was still there. The A/B test caught
/// it: the fixed binary ran the full 50s cap with no timeout.
var g_main_io: ?std.Io = null;

fn mainIo() std.Io {
    return g_main_io orelse @panic("g_main_io used before main initialised it");
}
/// The actual fetch, with no timeout of its own. Called only from the watchdog
/// thread in `kuriGet`, or as its spawn-failure fallback — so it must not assume
/// it will return promptly, and it takes the caller's `io` rather than making
/// one, because the caller owns the `Threaded` its syscalls run through.
///
/// See the REVISIT note in `kuriGet`.
fn kuriGetUnbounded(arena: std.mem.Allocator, url: []const u8, self_io: std.Io) Result {
    var client: std.http.Client = .{ .allocator = arena, .io = self_io };
    defer client.deinit();
    const uri = std.Uri.parse(url) catch |e| return .{ .err = e };
    var headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
    if (g_secret) |s| {
        const bearer = std.fmt.allocPrint(arena, "Bearer {s}", .{s}) catch |e| return .{ .err = e };
        headers.append(arena, .{ .name = "authorization", .value = bearer }) catch |e| return .{ .err = e };
    }
    var req = client.request(.GET, uri, .{ .redirect_behavior = .unhandled, .extra_headers = headers.items }) catch |e| return .{ .err = e };
    defer req.deinit();
    req.sendBodiless() catch |e| return .{ .err = e };
    var response = req.receiveHead(&.{}) catch |e| return .{ .err = e };
    var rbody: std.ArrayList(u8) = .empty;
    var tbuf: [16384]u8 = undefined;
    var dc: std.http.Decompress = undefined;
    var dbuf: [std.compress.flate.max_window_len]u8 = undefined;
    const rd = response.readerDecompressing(&tbuf, &dc, &dbuf);
    rd.appendRemainingUnlimited(arena, &rbody) catch |e| return .{ .err = e };
    return .{ .body = rbody.items };
}

// ---- JSON-RPC framing (single-line responses) ------------------------------

const tools_list_json = "{\"tools\":[" ++
    "{\"name\":\"navigate_page\",\"description\":\"Navigate the current page to a URL.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}},\"required\":[\"url\"]}}," ++
    "{\"name\":\"take_snapshot\",\"description\":\"Compact accessibility-tree snapshot of the page with @uid refs (token-efficient). Optional: uid re-snapshots only that element's subtree; limit collapses runs of same-role siblings to the first N plus a '… +K more' line. On list-heavy pages call with limit (e.g. 5), then a scoped uid snapshot to expand just the part you need.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"uid\":{\"type\":\"string\",\"description\":\"Scope to the subtree under this @uid from a previous snapshot\"},\"limit\":{\"type\":\"integer\",\"description\":\"Max same-role siblings per parent before truncation\"}}}}," ++
    "{\"name\":\"take_snapshot_diff\",\"description\":\"Only what changed since the last diff call for this tab: compact lines prefixed + (added), ~ (changed), - (removed). First call returns the whole page as additions. Prefer over take_snapshot inside an action loop — typically 3-9x fewer tokens. Optional limit: when a mass change (navigation) makes the diff fall back to a full snapshot, truncate that fallback to N items per sibling run.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\",\"description\":\"Truncation for the page-replaced fallback view\"}}}}," ++
    "{\"name\":\"get_page_state\",\"description\":\"Ultra-light page observation (~48 tokens): url, title, scroll position, viewport, form/link/input counts. Use to orient before paying for a snapshot.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
    "{\"name\":\"click\",\"description\":\"Click the element with the given uid.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"uid\":{\"type\":\"string\"}},\"required\":[\"uid\"]}}," ++
    "{\"name\":\"fill\",\"description\":\"Type text into the input/select with the given uid.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"uid\":{\"type\":\"string\"},\"value\":{\"type\":\"string\"}},\"required\":[\"uid\",\"value\"]}}," ++
    "{\"name\":\"hover\",\"description\":\"Hover the element with the given uid.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"uid\":{\"type\":\"string\"}},\"required\":[\"uid\"]}}," ++
    "{\"name\":\"type_text\",\"description\":\"Type text into the focused element.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}}," ++
    "{\"name\":\"evaluate_script\",\"description\":\"Evaluate JavaScript on the page.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\"}},\"required\":[\"expression\"]}}," ++
    "{\"name\":\"take_screenshot\",\"description\":\"Capture a screenshot to disk and return the file path — image bytes never enter context.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
    "{\"name\":\"list_pages\",\"description\":\"List open pages/tabs.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
    "{\"name\":\"new_page\",\"description\":\"Open a new page at a URL.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}}}}," ++
    "{\"name\":\"list_network_requests\",\"description\":\"List captured API-shaped network requests (JSON/XML/GraphQL responses and POST/PUT/PATCH/DELETE calls) with ready-to-use curl/fetch/python snippets. Requires /har/start to have been called first. Full response bodies are not included here -- call /har/stop for a jsonl_path with previews and gzip sidecars for large bodies.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
    "{\"name\":\"wait_for\",\"description\":\"Wait for text to appear on the page.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}}" ++
    "]}";

fn respondRaw(arena: std.mem.Allocator, id_val: ?std.json.Value, result_json: []const u8) void {
    if (id_val == null) return;
    const id = idToString(arena, id_val.?);
    const msg = std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}\n", .{ id, result_json }) catch return;
    writeAll(msg);
}

fn respondError(arena: std.mem.Allocator, id_val: ?std.json.Value, code: i32, message: []const u8) void {
    // Errors carry id:null when the request id is absent/unparseable (JSON-RPC).
    const id = if (id_val) |v| idToString(arena, v) else "null";
    const msg = std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}\n", .{ id, code, message }) catch return;
    writeAll(msg);
}

fn toolText(arena: std.mem.Allocator, id_val: ?std.json.Value, text: []const u8) void {
    const escaped = jsonEscape(arena, text) catch text;
    const result = std.fmt.allocPrint(arena, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}", .{escaped}) catch return;
    respondRaw(arena, id_val, result);
}

fn toolError(arena: std.mem.Allocator, id_val: ?std.json.Value, text: []const u8) void {
    const escaped = jsonEscape(arena, text) catch text;
    const result = std.fmt.allocPrint(arena, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"isError\":true}}", .{escaped}) catch return;
    respondRaw(arena, id_val, result);
}

fn idToString(arena: std.mem.Allocator, id: std.json.Value) []const u8 {
    return switch (id) {
        .integer => |n| std.fmt.allocPrint(arena, "{d}", .{n}) catch "0",
        .string => |s| std.fmt.allocPrint(arena, "\"{s}\"", .{s}) catch "\"0\"",
        else => "null",
    };
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Integer-or-string argument rendered as decimal text (MCP clients send JSON
/// numbers for integer-typed params; accept both).
fn argNumStr(arena: std.mem.Allocator, args: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const obj = args orelse return null;
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| std.fmt.allocPrint(arena, "{d}", .{i}) catch null,
        .string => |s| s,
        else => null,
    };
}

fn argStr(args: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const obj = args orelse return null;
    return strField(obj, key);
}

fn jsonEscape(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        else => if (c < 0x20) {
            try out.appendSlice(arena, "\\u00");
            const hex = "0123456789abcdef";
            try out.append(arena, hex[c >> 4]);
            try out.append(arena, hex[c & 0xf]);
        } else try out.append(arena, c),
    };
    return out.items;
}

fn urlencode(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            try buf.append(a, c);
        } else {
            const hex = "0123456789ABCDEF";
            try buf.append(a, '%');
            try buf.append(a, hex[c >> 4]);
            try buf.append(a, hex[c & 0x0F]);
        }
    }
}

// ---- stdio over std.Io (no libc) -------------------------------------------

fn readLine(r: *std.Io.Reader, buf: []u8) ?[]const u8 {
    var i: usize = 0;
    while (i < buf.len) {
        const b = r.takeByte() catch {
            if (i == 0) return null;
            return buf[0..i];
        };
        if (b == '\n') return buf[0..i];
        buf[i] = b;
        i += 1;
    }
    return buf[0..i];
}

fn writeAll(bytes: []const u8) void {
    const w = g_out orelse return;
    w.writeAll(bytes) catch return;
    w.flush() catch return;
}
