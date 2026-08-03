// © 2024 Carl Åstholm
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

pub const std_options: std.Options = .{ .log_level = .debug };

// Zig 0.16.0's default `std.Options.debug_io` (used by std.log and panics)
// pulls in `std.Io.Threaded`, whose POSIX child-wait code fails to compile
// for wasm32-emscripten (stdlib bug, fixed upstream for 0.17.0-dev via
// ziglang/zig#31850). Route around it only for the emscripten target; every
// other target keeps the stdlib's normal defaults.
pub const std_options_debug_io: std.Io = if (builtin.target.os.tag == .emscripten)
    std.Io.failing
else
    std.Io.Threaded.global_single_threaded.io();

pub const panic = if (builtin.target.os.tag == .emscripten)
    std.debug.no_panic
else
    std.debug.FullPanic(std.debug.defaultPanic);

const app_log = std.log.scoped(.app);

pub fn main() !u8 {
    if (builtin.target.os.tag == .emscripten) return webMain();
    return nativeMain();
}

//#region Native host: loads game.zig as a hot-reloadable shared library

const windows = std.os.windows;

extern "kernel32" fn LoadLibraryW(lpLibFileName: windows.LPCWSTR) callconv(.winapi) ?windows.HMODULE;
extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) callconv(.winapi) windows.BOOL;

const lib_prefix = switch (builtin.target.os.tag) {
    .windows => "",
    else => "lib",
};
const lib_suffix = switch (builtin.target.os.tag) {
    .windows => ".dll",
    .macos => ".dylib",
    else => ".so",
};

/// A loaded instance of the game library (actually a uniquely-named side
/// copy of it - see `HotReload.swap`). Only holds function pointers; never
/// holds game state itself, since the whole point is that this gets thrown
/// away and replaced on every reload while `GameState` lives on in the host.
///
/// `std.DynLib` doesn't support Windows in this Zig version (its `InnerType`
/// switch has no `.windows` arm), so Windows keeps the hand-rolled
/// LoadLibraryW/GetProcAddress/FreeLibrary path while Linux/macOS go through
/// `std.DynLib` (real `dlopen`, not the no-libc `ElfDynLib` path - see
/// `link_libc` in build.zig - since the game library needs its SDL3 symbols
/// resolved against the host's already-loaded libSDL3).
const GameModule = switch (builtin.target.os.tag) {
    .windows => WindowsGameModule,
    .linux, .macos => PosixGameModule,
    else => @compileError("the hot-reload host is not implemented for this OS"),
};

const WindowsGameModule = struct {
    handle: windows.HMODULE,
    gameStateSize: *const fn () callconv(.c) usize,
    gameStateAlign: *const fn () callconv(.c) usize,
    gameInit: *const fn (*anyopaque) callconv(.c) bool,
    gameEvent: *const fn (*anyopaque, *c.SDL_Event) callconv(.c) bool,
    gameIterate: *const fn (*anyopaque) callconv(.c) bool,
    gameQuit: *const fn (*anyopaque) callconv(.c) void,
    gameReloaded: *const fn (*anyopaque) callconv(.c) void,

    fn load(path: []const u8) !WindowsGameModule {
        var wbuf: [windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const path_w = try wideFromUtf8(&wbuf, path);

        const handle = LoadLibraryW(path_w.ptr) orelse {
            app_log.err("LoadLibraryW failed: {}", .{windows.GetLastError()});
            return error.LoadLibraryFailed;
        };
        errdefer _ = FreeLibrary(handle);

        return .{
            .handle = handle,
            .gameStateSize = @ptrCast(try getProc(handle, "gameStateSize")),
            .gameStateAlign = @ptrCast(try getProc(handle, "gameStateAlign")),
            .gameInit = @ptrCast(try getProc(handle, "gameInit")),
            .gameEvent = @ptrCast(try getProc(handle, "gameEvent")),
            .gameIterate = @ptrCast(try getProc(handle, "gameIterate")),
            .gameQuit = @ptrCast(try getProc(handle, "gameQuit")),
            .gameReloaded = @ptrCast(try getProc(handle, "gameReloaded")),
        };
    }

    fn unload(module: WindowsGameModule) void {
        _ = FreeLibrary(module.handle);
    }
};

fn getProc(handle: windows.HMODULE, name: [*:0]const u8) !*anyopaque {
    return GetProcAddress(handle, name) orelse {
        app_log.err("GetProcAddress({s}) failed: {}", .{ name, windows.GetLastError() });
        return error.GetProcAddressFailed;
    };
}

fn wideFromUtf8(buf: []u16, path: []const u8) ![:0]const u16 {
    const len = try windows.wtf8ToWtf16Le(buf[0 .. buf.len - 1], path);
    buf[len] = 0;
    return buf[0..len :0];
}

const PosixGameModule = struct {
    handle: std.DynLib,
    gameStateSize: *const fn () callconv(.c) usize,
    gameStateAlign: *const fn () callconv(.c) usize,
    gameInit: *const fn (*anyopaque) callconv(.c) bool,
    gameEvent: *const fn (*anyopaque, *c.SDL_Event) callconv(.c) bool,
    gameIterate: *const fn (*anyopaque) callconv(.c) bool,
    gameQuit: *const fn (*anyopaque) callconv(.c) void,
    gameReloaded: *const fn (*anyopaque) callconv(.c) void,

    fn load(path: []const u8) !PosixGameModule {
        var handle = std.DynLib.open(path) catch |err| {
            app_log.err("DynLib.open({s}) failed: {s}", .{ path, @errorName(err) });
            return err;
        };
        errdefer handle.close();

        return .{
            .handle = handle,
            .gameStateSize = @ptrCast(try getProcDynLib(&handle, "gameStateSize")),
            .gameStateAlign = @ptrCast(try getProcDynLib(&handle, "gameStateAlign")),
            .gameInit = @ptrCast(try getProcDynLib(&handle, "gameInit")),
            .gameEvent = @ptrCast(try getProcDynLib(&handle, "gameEvent")),
            .gameIterate = @ptrCast(try getProcDynLib(&handle, "gameIterate")),
            .gameQuit = @ptrCast(try getProcDynLib(&handle, "gameQuit")),
            .gameReloaded = @ptrCast(try getProcDynLib(&handle, "gameReloaded")),
        };
    }

    fn unload(module: PosixGameModule) void {
        var handle = module.handle;
        handle.close();
    }
};

fn getProcDynLib(handle: *std.DynLib, name: [:0]const u8) !*anyopaque {
    return handle.lookup(*anyopaque, name) orelse {
        app_log.err("DynLib.lookup({s}) failed", .{name});
        return error.GetProcAddressFailed;
    };
}

/// Copies `source_path` to `dest_path`, retrying with a short backoff if the
/// source is momentarily locked by a `zig build` still writing it.
fn copyDllWithRetry(io: std.Io, source_path: []const u8, dest_path: []const u8) !void {
    const max_attempts = 20;
    var attempt: usize = 0;
    while (true) {
        if (std.Io.Dir.cwd().copyFile(source_path, std.Io.Dir.cwd(), dest_path, io, .{})) |_| {
            return;
        } else |err| {
            attempt += 1;
            if (attempt >= max_attempts) return err;
            try std.Io.sleep(io, .fromMilliseconds(50), .awake);
        }
    }
}

/// Loads the game library from one of two alternating side-file names, so
/// that the original library built by `zig build` is never itself locked
/// (Windows) or subject to a stale cached mapping from the dynamic linker
/// (Linux/macOS), and so that the slot being copied into is always the one
/// that isn't currently loaded.
const HotReload = struct {
    source_path: []const u8,
    temp_paths: [2][]const u8,
    next_slot: usize = 0,
    io_threaded: std.Io.Threaded,

    fn init(source_path: []const u8, temp_paths: [2][]const u8) HotReload {
        return .{
            .source_path = source_path,
            .temp_paths = temp_paths,
            .io_threaded = .init(std.heap.page_allocator, .{}),
        };
    }

    fn swap(hr: *HotReload, prev: ?GameModule) !GameModule {
        const io = hr.io_threaded.io();
        const slot = hr.next_slot;
        const dest_path = hr.temp_paths[slot];

        try copyDllWithRetry(io, hr.source_path, dest_path);

        const new_module = try GameModule.load(dest_path);

        if (prev) |old| old.unload();
        hr.next_slot = 1 - slot;
        return new_module;
    }
};

/// Polls `source_path`'s mtime and flips `reload_pending` when it changes.
/// Never touches `GameState` or calls into the game module directly - all
/// init/swap/free logic stays on the main thread, between frames.
fn watchForReload(source_path: []const u8, reload_pending: *std.atomic.Value(bool), stop: *std.atomic.Value(bool)) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var last_mtime: ?std.Io.Timestamp = null;
    while (!stop.load(.acquire)) {
        std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
        const stat = std.Io.Dir.cwd().statFile(io, source_path, .{}) catch continue;
        if (last_mtime) |prev| {
            if (stat.mtime.nanoseconds != prev.nanoseconds) {
                reload_pending.store(true, .release);
            }
        }
        last_mtime = stat.mtime;
    }
}

fn nativeMain() !u8 {
    comptime switch (builtin.target.os.tag) {
        .windows, .linux, .macos => {},
        else => @compileError("the hot-reload host is not implemented for this OS"),
    };

    const allocator = std.heap.page_allocator;

    const exe_dir = blk: {
        var exe_dir_threaded: std.Io.Threaded = .init(allocator, .{});
        defer exe_dir_threaded.deinit();
        break :blk try std.process.executableDirPathAlloc(exe_dir_threaded.io(), allocator);
    };

    const dll_source_path = try std.fs.path.join(allocator, &.{ exe_dir, lib_prefix ++ "game" ++ lib_suffix });
    const temp_path_a = try std.fs.path.join(allocator, &.{ exe_dir, lib_prefix ++ "game_hotload_a" ++ lib_suffix });
    const temp_path_b = try std.fs.path.join(allocator, &.{ exe_dir, lib_prefix ++ "game_hotload_b" ++ lib_suffix });

    // Best-effort cleanup of side files potentially left behind by a crashed previous run.
    {
        var cleanup_threaded: std.Io.Threaded = .init(allocator, .{});
        defer cleanup_threaded.deinit();
        const io = cleanup_threaded.io();
        std.Io.Dir.deleteFileAbsolute(io, temp_path_a) catch {};
        std.Io.Dir.deleteFileAbsolute(io, temp_path_b) catch {};
    }

    var hot_reload: HotReload = .init(dll_source_path, .{ temp_path_a, temp_path_b });
    defer hot_reload.io_threaded.deinit();

    var module = try hot_reload.swap(null);

    const state_size = module.gameStateSize();
    const state_alignment = std.mem.Alignment.fromByteUnits(module.gameStateAlign());
    const state_bytes = allocator.rawAlloc(state_size, state_alignment, @returnAddress()) orelse return error.OutOfMemory;
    defer allocator.rawFree(state_bytes[0..state_size], state_alignment, @returnAddress());
    const state: *anyopaque = @ptrCast(state_bytes);

    defer module.unload();

    if (!module.gameInit(state)) return error.GameInitFailed;
    defer module.gameQuit(state);

    var reload_pending: std.atomic.Value(bool) = .init(false);
    var stop_watcher: std.atomic.Value(bool) = .init(false);

    const watcher_thread = try std.Thread.spawn(.{}, watchForReload, .{ dll_source_path, &reload_pending, &stop_watcher });
    defer {
        stop_watcher.store(true, .release);
        watcher_thread.join();
    }

    main_loop: while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (!module.gameEvent(state, &event)) break :main_loop;
        }

        if (!module.gameIterate(state)) break :main_loop;

        if (reload_pending.swap(false, .acquire)) {
            if (hot_reload.swap(module)) |new_module| {
                module = new_module;
                module.gameReloaded(state);
                app_log.info("game library reloaded", .{});
            } else |err| {
                app_log.warn("hot reload failed, keeping previous version: {s}", .{@errorName(err)});
            }
        }
    }

    return 0;
}

//#endregion Native host

//#region Web (emscripten): statically-linked, no hot reload, no threads

const game = if (builtin.target.os.tag == .emscripten) @import("game") else struct {};

var web_game_state: if (builtin.target.os.tag == .emscripten) game.GameState else void = undefined;

fn webMain() !u8 {
    var empty_argv: [0:null]?[*:0]u8 = .{};
    const status: u8 = @truncate(@as(c_uint, @bitCast(c.SDL_RunApp(empty_argv.len, @ptrCast(&empty_argv), sdlMainC, null))));
    return status;
}

fn sdlMainC(argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
    return c.SDL_EnterAppMainCallbacks(argc, @ptrCast(argv), sdlAppInitC, sdlAppIterateC, sdlAppEventC, sdlAppQuitC);
}

fn sdlAppInitC(appstate: ?*?*anyopaque, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c.SDL_AppResult {
    _ = appstate;
    _ = argc;
    _ = argv;
    return if (game.gameInit(@ptrCast(&web_game_state))) c.SDL_APP_CONTINUE else c.SDL_APP_FAILURE;
}

fn sdlAppIterateC(appstate: ?*anyopaque) callconv(.c) c.SDL_AppResult {
    _ = appstate;
    return if (game.gameIterate(@ptrCast(&web_game_state))) c.SDL_APP_CONTINUE else c.SDL_APP_FAILURE;
}

fn sdlAppEventC(appstate: ?*anyopaque, event: ?*c.SDL_Event) callconv(.c) c.SDL_AppResult {
    _ = appstate;
    return if (game.gameEvent(@ptrCast(&web_game_state), event.?)) c.SDL_APP_CONTINUE else c.SDL_APP_SUCCESS;
}

fn sdlAppQuitC(appstate: ?*anyopaque, result: c.SDL_AppResult) callconv(.c) void {
    _ = appstate;
    _ = result;
    game.gameQuit(@ptrCast(&web_game_state));
}

//#endregion Web
