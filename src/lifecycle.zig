const std = @import("std");
const launcher = @import("chrome/launcher.zig");

/// 🛑 SIGINT/SIGTERM hook so kuri's `defer chrome.deinit()` actually runs.
///
/// Without this, Ctrl+C in the foreground or `kill <pid>` from a supervisor
/// drops kuri instantly: the OS doesn't unwind Zig defers, the child Chrome
/// becomes orphaned, and its SingletonLock/SingletonSocket are left behind
/// pointing at a now-dead PID. The next `kuri` then hangs for ~15s in
/// waitForDebuggerUrl before erroring out with ConnectionRefused.
///
/// We install a tiny C signal handler that calls `Launcher.deinit` (which is
/// just `kill(pid, SIGKILL); waitpid(pid)` — both signal-safe) on the global
/// launcher pointer, then `_exit(128 + sig)` so we don't try to unwind Zig
/// code from inside a signal frame.
var launcher_ptr: ?*launcher.Launcher = null;

pub fn install(l: *launcher.Launcher) void {
    // ⚠️ THIS ASSIGNMENT USED TO LIVE ONLY IN THE WINDOWS BRANCH BELOW, SO ON
    // macOS AND LINUX THE HANDLER ALWAYS SAW `launcher_ptr == null` AND DID
    // NOTHING. The handler was registered, fired, found no launcher, and exited —
    // which is why SIGTERM killed kuri and left its whole Chrome tree running
    // (measured: 10 processes, reparented to PID 1). Filed as FI-41.
    //
    // It read as a correct handler because the Windows path proved the pointer was
    // meant to be set; the POSIX path merely forgot. Instrumenting the handler is
    // what found it — it printed `launcher_ptr=NULL` while kuri was demonstrably
    // serving requests, so the pointer had never been assigned on this platform.
    //
    // ⚠️ Every other part of this mechanism was already correct and verified
    // separately: the handler runs (`waitpid` reported WIFEXITED(143), not
    // WIFSIGNALED(15)), `setpgid` sticks (Chrome's pgid == its pid), and a manual
    // `kill(-pgid, SIGKILL)` reaps the whole tree (10 → 0). A one-line omission made
    // all of it unreachable, which is why reading the code did not find it.
    launcher_ptr = l;

    if (@import("builtin").os.tag == .windows) {
        return;
    }

    var sa: std.c.Sigaction = std.mem.zeroes(std.c.Sigaction);
    sa.handler = .{ .handler = handler };
    sa.flags = std.c.SA.RESTART;

    _ = std.c.sigaction(std.c.SIG.INT, &sa, null);
    _ = std.c.sigaction(std.c.SIG.TERM, &sa, null);
    _ = std.c.sigaction(std.c.SIG.HUP, &sa, null);
}

fn handler(sig: std.c.SIG) callconv(.c) void {
    if (launcher_ptr) |l| {
        l.deinit();
        launcher_ptr = null;
    }
    // Skip Zig's std.process.exit — that re-enters allocators and stdio. Use
    // the libc primitive that just sets the exit code and goes.
    std.c.exit(128 + @as(c_int, @intCast(@intFromEnum(sig))));
}
