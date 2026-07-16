// © 2024 Carl Åstholm
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

pub const std_options: std.Options = .{ .log_level = .debug };

const target_triple: [:0]const u8 = x: {
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    break :x (builtin.target.zigTriple(fba.allocator()) catch unreachable) ++ "";
};

const sdl_log = std.log.scoped(.sdl);
const app_log = std.log.scoped(.app);

const sprites = struct {
    const png = @embedFile("sprites.png");

    // zig fmt: off
    const brick_2x1_purple: c.SDL_FRect = .{ .x =   1, .y =  1, .w = 64, .h = 32 };
    const brick_1x1_purple: c.SDL_FRect = .{ .x =  67, .y =  1, .w = 32, .h = 32 };
    const brick_2x1_red:    c.SDL_FRect = .{ .x = 101, .y =  1, .w = 64, .h = 32 };
    const brick_1x1_red:    c.SDL_FRect = .{ .x = 167, .y =  1, .w = 32, .h = 32 };
    const brick_2x1_yellow: c.SDL_FRect = .{ .x =   1, .y = 35, .w = 64, .h = 32 };
    const brick_1x1_yellow: c.SDL_FRect = .{ .x =  67, .y = 35, .w = 32, .h = 32 };
    const brick_2x1_green:  c.SDL_FRect = .{ .x = 101, .y = 35, .w = 64, .h = 32 };
    const brick_1x1_green:  c.SDL_FRect = .{ .x = 167, .y = 35, .w = 32, .h = 32 };
    const brick_2x1_blue:   c.SDL_FRect = .{ .x =   1, .y = 69, .w = 64, .h = 32 };
    const brick_1x1_blue:   c.SDL_FRect = .{ .x =  67, .y = 69, .w = 32, .h = 32 };
    const brick_2x1_gray:   c.SDL_FRect = .{ .x = 101, .y = 69, .w = 64, .h = 32 };
    const brick_1x1_gray:   c.SDL_FRect = .{ .x = 167, .y = 69, .w = 32, .h = 32 };

    const ball:   c.SDL_FRect = .{ .x =  2, .y = 104, .w =  22, .h = 22 };
    const paddle: c.SDL_FRect = .{ .x = 27, .y = 103, .w = 104, .h = 24 };
    // zig fmt: on
};

const sounds = struct {
    const wav = @embedFile("sounds.wav");

    // zig fmt: off
    const hit_wall   = .{      0,  4_886 };
    const hit_paddle = .{  4_886, 17_165 };
    const hit_brick  = .{ 17_165, 25_592 };
    const win        = .{ 25_592, 49_362 };
    const lose       = .{ 49_362, 64_024 };
    // zig fmt: on
};

const window_w = 640;
const window_h = 480;

/// Owned by the host (main.zig): allocated once, at a stable address, and
/// never touched across a hot reload except via these exported functions.
/// Only this DLL's *code* gets swapped on reload; adding/removing/reordering
/// fields requires a full process restart. Never store the address of this
/// DLL's own const/static data here (see `Paddle`/`Ball`/`Brick.src_rect`) -
/// such an address is only valid for the currently-loaded DLL instance and
/// will dangle after the next reload.
pub const GameState = struct {
    fully_initialized: bool,
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,

    sprites_texture: *c.SDL_Texture,

    sounds_spec: c.SDL_AudioSpec,
    sounds_data: []u8,

    audio_device: c.SDL_AudioDeviceID,

    audio_streams_buf: [8]*c.SDL_AudioStream,
    audio_streams: []*c.SDL_AudioStream,

    gamepad: ?*c.SDL_Gamepad,

    phcon: PhysicalControllerState,
    prev_phcon: PhysicalControllerState,
    vcon: VirtualControllerState,
    prev_vcon: VirtualControllerState,

    best_score: u32,

    timekeeper: Timekeeper,

    paddle: Paddle,
    ball: Ball,
    bricks_buf: [100]Brick,
    bricks: std.ArrayListUnmanaged(Brick),

    score: u32,
    score_color: [3]u8,
};

fn gameInitImpl(state: *GameState) !void {
    std.log.debug("{s} {s}", .{ target_triple, @tagName(builtin.mode) });
    const platform: [*:0]const u8 = c.SDL_GetPlatform();
    sdl_log.debug("SDL platform: {s}", .{platform});
    sdl_log.debug("SDL build time version: {d}.{d}.{d}", .{
        c.SDL_MAJOR_VERSION,
        c.SDL_MINOR_VERSION,
        c.SDL_MICRO_VERSION,
    });
    sdl_log.debug("SDL build time revision: {s}", .{c.SDL_REVISION});
    {
        const version = c.SDL_GetVersion();
        sdl_log.debug("SDL runtime version: {d}.{d}.{d}", .{
            c.SDL_VERSIONNUM_MAJOR(version),
            c.SDL_VERSIONNUM_MINOR(version),
            c.SDL_VERSIONNUM_MICRO(version),
        });
        const revision: [*:0]const u8 = c.SDL_GetRevision();
        sdl_log.debug("SDL runtime revision: {s}", .{revision});
    }

    try errify(c.SDL_SetAppMetadata("Speedbreaker", "0.0.0", "example.zig-examples.breakout"));

    try errify(c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO | c.SDL_INIT_GAMEPAD));
    // We don't need to call 'SDL_Quit()' when using main callbacks.

    sdl_log.debug("SDL video drivers: {f}", .{fmtSdlDrivers(
        c.SDL_GetCurrentVideoDriver().?,
        c.SDL_GetNumVideoDrivers(),
        c.SDL_GetVideoDriver,
    )});
    sdl_log.debug("SDL audio drivers: {f}", .{fmtSdlDrivers(
        c.SDL_GetCurrentAudioDriver().?,
        c.SDL_GetNumAudioDrivers(),
        c.SDL_GetAudioDriver,
    )});

    errify(c.SDL_SetHint(c.SDL_HINT_RENDER_VSYNC, "1")) catch {};

    try errify(c.SDL_CreateWindowAndRenderer("Speedbreaker", window_w, window_h, 0, @ptrCast(&state.window), @ptrCast(&state.renderer)));
    errdefer c.SDL_DestroyWindow(state.window);
    errdefer c.SDL_DestroyRenderer(state.renderer);

    sdl_log.debug("SDL render drivers: {f}", .{fmtSdlDrivers(
        c.SDL_GetRendererName(state.renderer).?,
        c.SDL_GetNumRenderDrivers(),
        c.SDL_GetRenderDriver,
    )});

    {
        const stream: *c.SDL_IOStream = try errify(c.SDL_IOFromConstMem(sprites.png, sprites.png.len));
        const surface: *c.SDL_Surface = try errify(c.SDL_LoadPNG_IO(stream, true));
        defer c.SDL_DestroySurface(surface);

        state.sprites_texture = try errify(c.SDL_CreateTextureFromSurface(state.renderer, surface));
        errdefer comptime unreachable;
    }
    errdefer c.SDL_DestroyTexture(state.sprites_texture);

    {
        const stream: *c.SDL_IOStream = try errify(c.SDL_IOFromConstMem(sounds.wav, sounds.wav.len));
        var data_ptr: ?[*]u8 = undefined;
        var data_len: u32 = undefined;
        try errify(c.SDL_LoadWAV_IO(stream, true, &state.sounds_spec, &data_ptr, &data_len));
        errdefer comptime unreachable;

        state.sounds_data = data_ptr.?[0..data_len];
    }
    errdefer c.SDL_free(state.sounds_data.ptr);

    state.audio_device = try errify(c.SDL_OpenAudioDevice(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &state.sounds_spec));
    errdefer c.SDL_CloseAudioDevice(state.audio_device);

    state.audio_streams = state.audio_streams_buf[0..0];
    errdefer while (state.audio_streams.len != 0) {
        c.SDL_DestroyAudioStream(state.audio_streams[state.audio_streams.len - 1]);
        state.audio_streams.len -= 1;
    };
    while (state.audio_streams.len < state.audio_streams_buf.len) {
        state.audio_streams.len += 1;
        state.audio_streams[state.audio_streams.len - 1] = try errify(c.SDL_CreateAudioStream(&state.sounds_spec, null));
    }

    try errify(c.SDL_BindAudioStreams(state.audio_device, @ptrCast(state.audio_streams.ptr), @intCast(state.audio_streams.len)));

    {
        var count: c_int = 0;
        const gamepads: [*]c.SDL_JoystickID = try errify(c.SDL_GetGamepads(&count));
        defer c.SDL_free(gamepads);

        state.gamepad = if (count > 0) try errify(c.SDL_OpenGamepad(gamepads[0])) else null;
    }
    errdefer c.SDL_CloseGamepad(state.gamepad);

    state.phcon = .{};
    state.prev_phcon = state.phcon;
    state.vcon = .{};
    state.prev_vcon = state.vcon;

    try loadBestScore(state);

    state.timekeeper = .{ .tocks_per_s = c.SDL_GetPerformanceFrequency() };

    try resetGame(state);

    state.fully_initialized = true;
    errdefer comptime unreachable;
}

fn resetGame(state: *GameState) !void {
    state.paddle = .{
        .box = .{
            .x = window_w * 0.5 - sprites.paddle.w * 0.5,
            .y = window_h - sprites.paddle.h,
            .w = sprites.paddle.w,
            .h = sprites.paddle.h,
        },
        .src_rect = sprites.paddle,
    };

    state.ball = .{
        .box = .{
            .x = state.paddle.box.x + state.paddle.box.w * 0.5,
            .y = state.paddle.box.y - sprites.ball.h,
            .w = sprites.ball.w,
            .h = sprites.ball.h,
        },
        .vel_x = 0,
        .vel_y = 0,
        .launched = false,
        .src_rect = sprites.ball,
    };

    state.bricks = .initBuffer(&state.bricks_buf);
    {
        const x = window_w * 0.5;
        const h = sprites.brick_1x1_gray.h;
        const gap = 5;
        for ([_][2]*const c.SDL_FRect{
            .{ &sprites.brick_1x1_purple, &sprites.brick_2x1_purple },
            .{ &sprites.brick_1x1_red, &sprites.brick_2x1_red },
            .{ &sprites.brick_1x1_yellow, &sprites.brick_2x1_yellow },
            .{ &sprites.brick_1x1_green, &sprites.brick_2x1_green },
            .{ &sprites.brick_1x1_blue, &sprites.brick_2x1_blue },
            .{ &sprites.brick_1x1_gray, &sprites.brick_2x1_gray },
        }, 0..) |src_rects, row| {
            const y = gap + (h + gap) * (@as(f32, @floatFromInt(row)) + 1);
            var large = row % 2 == 0;
            var src_rect = src_rects[@intFromBool(large)];
            try state.bricks.appendBounded(.{
                .box = .{
                    .x = x - src_rect.w * 0.5,
                    .y = y,
                    .w = src_rect.w,
                    .h = src_rect.h,
                },
                .src_rect = src_rect.*,
            });
            var rel_x: f32 = 0;
            var count: usize = 0;
            while (count < 4) : (count += 1) {
                rel_x += src_rect.w * 0.5 + gap;
                large = !large;
                src_rect = src_rects[@intFromBool(large)];
                rel_x += src_rect.w * 0.5;
                for ([_]f32{ -1, 1 }) |sign| {
                    try state.bricks.appendBounded(.{
                        .box = .{
                            .x = x - src_rect.w * 0.5 + rel_x * sign,
                            .y = y,
                            .w = src_rect.w,
                            .h = src_rect.h,
                        },
                        .src_rect = src_rect.*,
                    });
                }
            }
        }
    }

    state.score = 0;
    state.score_color = .{ 0xff, 0xff, 0xff };
}

fn gameIterateImpl(state: *GameState) !bool {
    var sounds_to_play: std.EnumSet(enum {
        hit_wall,
        hit_paddle,
        hit_brick,
        win,
        lose,
    }) = .empty;

    var won = false;

    // Update the game state.
    while (state.timekeeper.consume()) {
        // Map the physical controller state to the virtual controller state.

        state.prev_vcon = state.vcon;
        state.vcon.move_paddle_exact = 0;

        state.vcon.move_paddle_left =
            state.phcon.k_left or
            state.phcon.g_left or
            state.phcon.g_leftx <= -0x4000;
        state.vcon.move_paddle_right =
            state.phcon.k_right or
            state.phcon.g_right or
            state.phcon.g_leftx >= 0x4000;
        state.vcon.slow_paddle_movement =
            state.phcon.k_lshift or
            state.phcon.g_left_shoulder or
            state.phcon.g_right_shoulder or
            state.phcon.g_left_trigger >= 0x2000 or
            state.phcon.g_right_trigger >= 0x2000;
        state.vcon.launch_ball =
            state.phcon.k_space or
            state.phcon.g_south or
            state.phcon.g_east;
        state.vcon.reset_game =
            state.phcon.k_r or
            state.phcon.g_back or
            state.phcon.g_start;

        if (!state.vcon.lock_mouse) {
            if (state.phcon.m_left and !state.prev_phcon.m_left) {
                state.vcon.lock_mouse = true;
                try errify(c.SDL_SetWindowRelativeMouseMode(state.window, true));
            }
        } else {
            if (state.phcon.k_escape and !state.prev_phcon.k_escape) {
                state.vcon.lock_mouse = false;
                try errify(c.SDL_SetWindowRelativeMouseMode(state.window, false));
            } else {
                state.vcon.launch_ball = state.vcon.launch_ball or state.phcon.m_left;
                state.vcon.move_paddle_exact = state.phcon.m_xrel;
            }
        }

        state.prev_phcon = state.phcon;
        state.phcon.m_xrel = 0;

        if (state.vcon.reset_game and !state.prev_vcon.reset_game) {
            try resetGame(state);
            return true;
        }

        // Move the paddle.
        {
            var paddle_vel_x: f32 = 0;
            var keyboard_gamepad_vel_x: f32 = 0;
            if (state.vcon.move_paddle_left) keyboard_gamepad_vel_x -= 10;
            if (state.vcon.move_paddle_right) keyboard_gamepad_vel_x += 10;
            if (state.vcon.slow_paddle_movement) keyboard_gamepad_vel_x *= 0.5;
            paddle_vel_x += keyboard_gamepad_vel_x;
            var mouse_vel_x = state.vcon.move_paddle_exact;
            if (state.vcon.slow_paddle_movement) mouse_vel_x *= 0.25;
            paddle_vel_x += mouse_vel_x;
            state.paddle.box.x = std.math.clamp(state.paddle.box.x + paddle_vel_x, 0, window_w - state.paddle.box.w);
        }

        const previous_ball_y = state.ball.box.y;

        if (!state.ball.launched) {
            // Stick the ball to the paddle.
            state.ball.box.x = state.paddle.box.x + state.paddle.box.w * 0.5;

            if (state.vcon.launch_ball and !state.prev_vcon.launch_ball) {
                // Launch the ball.
                const angle = state.ball.getPaddleBounceAngle(state.paddle);
                state.ball.vel_x = @cos(angle) * 4;
                state.ball.vel_y = @sin(angle) * 4;
                state.ball.launched = true;
            }
        }

        if (state.ball.launched) {
            // Check for and handle collisions using swept AABB collision detection.
            var remaining_vel_x: f32 = state.ball.vel_x;
            var remaining_vel_y: f32 = state.ball.vel_y;
            while (remaining_vel_x != 0 or remaining_vel_y != 0) {
                var t: f32 = 1;
                var sign_x: f32 = 0;
                var sign_y: f32 = 0;
                var collidee: union(enum) {
                    none: void,
                    wall: void,
                    paddle: void,
                    brick: usize,
                } = .none;

                const remaining_vel_x_inv = 1 / remaining_vel_x;
                const remaining_vel_y_inv = 1 / remaining_vel_y;

                if (remaining_vel_x < 0) {
                    // Left wall
                    const wall_t = -state.ball.box.x * remaining_vel_x_inv;
                    if (t - wall_t >= 0.001) {
                        t = wall_t;
                        sign_x = 1;
                        collidee = .wall;
                    }
                } else if (remaining_vel_x > 0) {
                    // Right wall
                    const wall_t = (window_w - state.ball.box.w - state.ball.box.x) * remaining_vel_x_inv;
                    if (t - wall_t >= 0.001) {
                        t = wall_t;
                        sign_x = -1;
                        collidee = .wall;
                    }
                }
                if (remaining_vel_y < 0) {
                    // Top wall
                    const wall_t = -state.ball.box.y * remaining_vel_y_inv;
                    if (t - wall_t >= 0.001) {
                        t = wall_t;
                        sign_y = 1;
                        collidee = .wall;
                    }
                } else if (remaining_vel_y > 0) {
                    // Paddle
                    const paddle_top: Box = .{
                        .x = state.paddle.box.x,
                        .y = state.paddle.box.y,
                        .w = state.paddle.box.w,
                        .h = 0,
                    };
                    if (state.ball.box.sweepTest(remaining_vel_x, remaining_vel_y, paddle_top, 0, 0)) |collision| {
                        if (t - collision.t >= 0.001) {
                            t = @min(0, collision.t);
                            sign_y = -1;
                            collidee = .paddle;
                        }
                    }
                }

                // Bricks
                const broad: Box = .{
                    .x = @min(state.ball.box.x, state.ball.box.x + remaining_vel_x),
                    .y = @min(state.ball.box.y, state.ball.box.y + remaining_vel_y),
                    .w = @max(state.ball.box.w, state.ball.box.w + remaining_vel_x),
                    .h = @max(state.ball.box.h, state.ball.box.h + remaining_vel_y),
                };
                for (state.bricks.items, 0..) |brick, i| {
                    if (broad.intersects(brick.box)) {
                        if (state.ball.box.sweepTest(remaining_vel_x, remaining_vel_y, brick.box, 0, 0)) |collision| {
                            if (t - collision.t >= 0.001) {
                                t = collision.t;
                                sign_x = collision.sign_x;
                                sign_y = collision.sign_y;
                                collidee = .{ .brick = i };
                            }
                        }
                    }
                }

                // Bounce the ball off the object it collided with (if any).
                if (collidee == .paddle) {
                    const angle = state.ball.getPaddleBounceAngle(state.paddle);
                    const vel_factor = 1.05;
                    state.ball.box.x += remaining_vel_x * t;
                    state.ball.box.y += remaining_vel_y * t;
                    const vel = @sqrt(state.ball.vel_x * state.ball.vel_x + state.ball.vel_y * state.ball.vel_y) * vel_factor;
                    state.ball.vel_x = @cos(angle) * vel;
                    state.ball.vel_y = @sin(angle) * vel;
                    remaining_vel_x *= (1 - t);
                    remaining_vel_y *= (1 - t);
                    const remaining_vel = @sqrt(remaining_vel_x * remaining_vel_x + remaining_vel_y * remaining_vel_y) * vel_factor;
                    remaining_vel_x = @cos(angle) * remaining_vel;
                    remaining_vel_y = @sin(angle) * remaining_vel;
                } else {
                    state.ball.box.x += remaining_vel_x * t;
                    state.ball.box.y += remaining_vel_y * t;
                    state.ball.vel_x = std.math.copysign(state.ball.vel_x, if (sign_x != 0) sign_x else remaining_vel_x);
                    state.ball.vel_y = std.math.copysign(state.ball.vel_y, if (sign_y != 0) sign_y else remaining_vel_y);
                    remaining_vel_x = std.math.copysign(remaining_vel_x * (1 - t), state.ball.vel_x);
                    remaining_vel_y = std.math.copysign(remaining_vel_y * (1 - t), state.ball.vel_y);
                    if (collidee == .brick) {
                        _ = state.bricks.swapRemove(collidee.brick);
                    }
                }

                // Enqueue an appropriate sound effect.
                switch (collidee) {
                    .wall => {
                        if (state.ball.box.y < window_h) {
                            sounds_to_play.insert(.hit_wall);
                        }
                    },
                    .paddle => {
                        sounds_to_play.insert(.hit_paddle);
                    },
                    .brick => {
                        if (state.bricks.items.len == 0) {
                            won = true;
                            sounds_to_play.insert(.win);
                        } else {
                            sounds_to_play.insert(.hit_brick);
                        }
                    },
                    .none => {},
                }
            }
        }

        if (previous_ball_y < window_h and state.ball.box.y >= window_h) {
            // The ball fell below the paddle.
            if (state.bricks.items.len != 0) {
                sounds_to_play.insert(.lose);
            }
        }

        // Update score.
        if (state.ball.launched) {
            if (state.ball.box.y < window_h) {
                if (state.bricks.items.len != 0) {
                    state.score +|= 1;
                } else {
                    state.best_score = @min(state.score, state.best_score);
                }
            }
            if (state.score <= state.best_score and state.bricks.items.len == 0) {
                state.score_color = .{ 0x52, 0xcc, 0x73 };
            } else if (state.ball.box.y >= window_h or state.score > state.best_score) {
                state.score_color = .{ 0xcc, 0x5c, 0x52 };
            }
        }
    }

    // Save score.
    if (won and state.score < state.best_score) {
        try saveBestScore(state);
    }

    // Play audio.
    {
        // We have created eight SDL audio streams. When we want to play a sound effect,
        // we loop through the streams for the first one that isn't playing any audio
        // and write the audio to that stream.
        // This is a kind of stupid and naive way of handling audio, but it's very easy to
        // set up and use. A proper program would probably use an audio mixing callback.
        var stream_index: usize = 0;
        var it = sounds_to_play.iterator();
        iterate_sounds: while (it.next()) |sound| {
            const stream = find_available_stream: while (stream_index < state.audio_streams.len) {
                defer stream_index += 1;
                const stream = state.audio_streams[stream_index];
                if (try errify(c.SDL_GetAudioStreamAvailable(stream)) == 0) {
                    break :find_available_stream stream;
                }
            } else {
                break :iterate_sounds;
            };
            const frame_size = @as(usize, @intCast(c.SDL_AUDIO_BYTESIZE(state.sounds_spec.format))) * @as(usize, @intCast(state.sounds_spec.channels));
            const start: usize, const end: usize = switch (sound) {
                .hit_wall => sounds.hit_wall,
                .hit_paddle => sounds.hit_paddle,
                .hit_brick => sounds.hit_brick,
                .win => sounds.win,
                .lose => sounds.lose,
            };
            const data = state.sounds_data[(frame_size * start)..(frame_size * end)];
            try errify(c.SDL_PutAudioStreamData(stream, data.ptr, @intCast(data.len)));
        }
    }

    // Draw.
    {
        try errify(c.SDL_SetRenderDrawColor(state.renderer, 0x47, 0x5b, 0x8d, 0xff));

        try errify(c.SDL_RenderClear(state.renderer));

        for (state.bricks.items) |brick| try renderObject(state.renderer, state.sprites_texture, &brick.src_rect, brick.box);
        try renderObject(state.renderer, state.sprites_texture, &state.ball.src_rect, state.ball.box);
        try renderObject(state.renderer, state.sprites_texture, &state.paddle.src_rect, state.paddle.box);

        try errify(c.SDL_SetRenderScale(state.renderer, 2, 2));
        {
            var buf: [12]u8 = undefined;
            var time: f32 = @min(@as(f32, @floatFromInt(state.score)) / Timekeeper.updates_per_s, 99.999);
            var text = try std.fmt.bufPrintSentinel(&buf, "TIME {d:0>6.3}", .{time}, 0);
            try errify(c.SDL_SetRenderDrawColor(state.renderer, state.score_color[0], state.score_color[1], state.score_color[2], 0xff));
            try errify(c.SDL_RenderDebugText(state.renderer, 8, 8, text.ptr));
            time = @min(@as(f32, @floatFromInt(state.best_score)) / Timekeeper.updates_per_s, 99.999);
            text = try std.fmt.bufPrintSentinel(&buf, "BEST {d:0>6.3}", .{time}, 0);
            try errify(c.SDL_SetRenderDrawColor(state.renderer, 0xff, 0xff, 0xff, 0xff));
            try errify(c.SDL_RenderDebugText(state.renderer, window_w / 2 - 8 * 12, 8, text.ptr));
        }
        try errify(c.SDL_SetRenderScale(state.renderer, 1, 1));

        try errify(c.SDL_RenderPresent(state.renderer));
    }

    state.timekeeper.produce(c.SDL_GetPerformanceCounter());

    return true;
}

fn gameEventImpl(state: *GameState, event: *c.SDL_Event) !bool {
    switch (event.type) {
        c.SDL_EVENT_QUIT => {
            return false;
        },
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
            const down = event.type == c.SDL_EVENT_KEY_DOWN;
            switch (event.key.scancode) {
                c.SDL_SCANCODE_LEFT => state.phcon.k_left = down,
                c.SDL_SCANCODE_RIGHT => state.phcon.k_right = down,
                c.SDL_SCANCODE_LSHIFT => state.phcon.k_lshift = down,
                c.SDL_SCANCODE_SPACE => state.phcon.k_space = down,
                c.SDL_SCANCODE_R => state.phcon.k_r = down,
                c.SDL_SCANCODE_ESCAPE => state.phcon.k_escape = down,
                else => {},
            }
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
            const down = event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN;
            switch (event.button.button) {
                c.SDL_BUTTON_LEFT => state.phcon.m_left = down,
                else => {},
            }
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            state.phcon.m_xrel += event.motion.xrel;
        },
        c.SDL_EVENT_GAMEPAD_ADDED => {
            if (state.gamepad == null) {
                state.gamepad = try errify(c.SDL_OpenGamepad(event.gdevice.which));
            }
        },
        c.SDL_EVENT_GAMEPAD_REMOVED => {
            if (state.gamepad != null) {
                c.SDL_CloseGamepad(state.gamepad);
                state.gamepad = null;
            }
        },
        c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_EVENT_GAMEPAD_BUTTON_UP => {
            const down = event.type == c.SDL_EVENT_GAMEPAD_BUTTON_DOWN;
            switch (event.gbutton.button) {
                c.SDL_GAMEPAD_BUTTON_DPAD_LEFT => state.phcon.g_left = down,
                c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT => state.phcon.g_right = down,
                c.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER => state.phcon.g_left_shoulder = down,
                c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER => state.phcon.g_right_shoulder = down,
                c.SDL_GAMEPAD_BUTTON_SOUTH => state.phcon.g_south = down,
                c.SDL_GAMEPAD_BUTTON_EAST => state.phcon.g_east = down,
                c.SDL_GAMEPAD_BUTTON_BACK => state.phcon.g_back = down,
                c.SDL_GAMEPAD_BUTTON_START => state.phcon.g_start = down,
                else => {},
            }
        },
        c.SDL_EVENT_GAMEPAD_AXIS_MOTION => {
            switch (event.gaxis.axis) {
                c.SDL_GAMEPAD_AXIS_LEFTX => state.phcon.g_leftx = event.gaxis.value,
                c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER => state.phcon.g_left_trigger = event.gaxis.value,
                c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER => state.phcon.g_right_trigger = event.gaxis.value,
                else => {},
            }
        },
        else => {},
    }

    return true;
}

fn gameQuitImpl(state: *GameState) void {
    if (state.fully_initialized) {
        c.SDL_CloseGamepad(state.gamepad);
        while (state.audio_streams.len != 0) {
            c.SDL_DestroyAudioStream(state.audio_streams[state.audio_streams.len - 1]);
            state.audio_streams.len -= 1;
        }
        c.SDL_CloseAudioDevice(state.audio_device);
        c.SDL_free(state.sounds_data.ptr);
        c.SDL_DestroyTexture(state.sprites_texture);
        c.SDL_DestroyRenderer(state.renderer);
        c.SDL_DestroyWindow(state.window);
        state.fully_initialized = false;
    }
}

const Box = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    fn intersects(a: Box, b: Box) bool {
        const min_x = b.x - a.w;
        const max_x = b.x + b.w;
        if (a.x > min_x and a.x < max_x) {
            const min_y = b.y - a.h;
            const max_y = b.y + b.h;
            if (a.y > min_y and a.y < max_y) {
                return true;
            }
        }
        return false;
    }

    fn sweepTest(a: Box, a_vel_x: f32, a_vel_y: f32, b: Box, b_vel_x: f32, b_vel_y: f32) ?Collision {
        const vel_x_inv = 1 / (a_vel_x - b_vel_x);
        const vel_y_inv = 1 / (a_vel_y - b_vel_y);
        const min_x = b.x - a.w;
        const min_y = b.y - a.h;
        const max_x = b.x + b.w;
        const max_y = b.y + b.h;
        const t_min_x = (min_x - a.x) * vel_x_inv;
        const t_min_y = (min_y - a.y) * vel_y_inv;
        const t_max_x = (max_x - a.x) * vel_x_inv;
        const t_max_y = (max_y - a.y) * vel_y_inv;
        const entry_x = @min(t_min_x, t_max_x);
        const entry_y = @min(t_min_y, t_max_y);
        const exit_x = @max(t_min_x, t_max_x);
        const exit_y = @max(t_min_y, t_max_y);

        const last_entry = @max(entry_x, entry_y);
        const first_exit = @min(exit_x, exit_y);
        if (last_entry < first_exit and last_entry < 1 and first_exit > 0) {
            var sign_x: f32 = 0;
            var sign_y: f32 = 0;
            sign_x -= @floatFromInt(@intFromBool(last_entry == t_min_x));
            sign_x += @floatFromInt(@intFromBool(last_entry == t_max_x));
            sign_y -= @floatFromInt(@intFromBool(last_entry == t_min_y));
            sign_y += @floatFromInt(@intFromBool(last_entry == t_max_y));
            return .{ .t = last_entry, .sign_x = sign_x, .sign_y = sign_y };
        }
        return null;
    }

    const Collision = struct {
        t: f32,
        sign_x: f32,
        sign_y: f32,
    };
};

const Paddle = struct {
    box: Box,
    src_rect: c.SDL_FRect,
};

const Ball = struct {
    box: Box,
    vel_x: f32,
    vel_y: f32,
    launched: bool,
    src_rect: c.SDL_FRect,

    fn getPaddleBounceAngle(ball_: Ball, paddle_: Paddle) f32 {
        const min_x = paddle_.box.x - ball_.box.w;
        const max_x = paddle_.box.x + paddle_.box.w;
        const min_angle = std.math.degreesToRadians(195);
        const max_angle = std.math.degreesToRadians(345);
        const angle = ((ball_.box.x - min_x) / (max_x - min_x)) * (max_angle - min_angle) + min_angle;
        return std.math.clamp(angle, min_angle, max_angle);
    }
};

const Brick = struct {
    box: Box,
    src_rect: c.SDL_FRect,
};

fn renderObject(renderer_: *c.SDL_Renderer, texture: *c.SDL_Texture, src: *const c.SDL_FRect, dst: Box) !void {
    try errify(c.SDL_RenderTexture(renderer_, texture, src, &.{
        .x = dst.x,
        .y = dst.y,
        .w = dst.w,
        .h = dst.h,
    }));
}

const PhysicalControllerState = struct {
    k_left: bool = false,
    k_right: bool = false,
    k_lshift: bool = false,
    k_space: bool = false,
    k_r: bool = false,
    k_escape: bool = false,

    m_left: bool = false,
    m_xrel: f32 = 0,

    g_left: bool = false,
    g_right: bool = false,
    g_left_shoulder: bool = false,
    g_right_shoulder: bool = false,
    g_south: bool = false,
    g_east: bool = false,
    g_back: bool = false,
    g_start: bool = false,
    g_leftx: i16 = 0,
    g_left_trigger: i16 = 0,
    g_right_trigger: i16 = 0,
};

const VirtualControllerState = struct {
    move_paddle_left: bool = false,
    move_paddle_right: bool = false,
    slow_paddle_movement: bool = false,
    launch_ball: bool = false,
    reset_game: bool = false,

    lock_mouse: bool = false,
    move_paddle_exact: f32 = 0,
};

/// Facilitates updating the game logic at a fixed rate.
/// Inspired <https://github.com/TylerGlaiel/FrameTimingControl> and the linked article.
const Timekeeper = struct {
    const updates_per_s = 60;
    const max_accumulated_updates = 8;
    const snap_frame_rates = .{ updates_per_s, 30, 120, 144 };
    const ticks_per_tock = 720; // Least common multiple of 'snap_frame_rates'
    const snap_tolerance_us = 200;
    const us_per_s = 1_000_000;

    tocks_per_s: u64,
    accumulated_ticks: u64 = 0,
    previous_timestamp: ?u64 = null,

    fn consume(timekeeper_: *Timekeeper) bool {
        const ticks_per_s: u64 = timekeeper_.tocks_per_s * ticks_per_tock;
        const ticks_per_update: u64 = @divExact(ticks_per_s, updates_per_s);
        if (timekeeper_.accumulated_ticks >= ticks_per_update) {
            timekeeper_.accumulated_ticks -= ticks_per_update;
            return true;
        } else {
            return false;
        }
    }

    fn produce(timekeeper_: *Timekeeper, current_timestamp: u64) void {
        if (timekeeper_.previous_timestamp) |previous_timestamp| {
            const ticks_per_s: u64 = timekeeper_.tocks_per_s * ticks_per_tock;
            const elapsed_ticks: u64 = (current_timestamp -% previous_timestamp) *| ticks_per_tock;
            const snapped_elapsed_ticks: u64 = inline for (snap_frame_rates) |snap_frame_rate| {
                const target_ticks: u64 = @divExact(ticks_per_s, snap_frame_rate);
                const abs_diff = @max(elapsed_ticks, target_ticks) - @min(elapsed_ticks, target_ticks);
                if (abs_diff *| us_per_s <= snap_tolerance_us *| ticks_per_s) {
                    break target_ticks;
                }
            } else elapsed_ticks;
            const ticks_per_update: u64 = @divExact(ticks_per_s, updates_per_s);
            const max_accumulated_ticks: u64 = max_accumulated_updates * ticks_per_update;
            timekeeper_.accumulated_ticks = @min(timekeeper_.accumulated_ticks +| snapped_elapsed_ticks, max_accumulated_ticks);
        }
        timekeeper_.previous_timestamp = current_timestamp;
    }
};

const best_score_storage_org = "zig-examples";
const best_score_storage_app = "breakout";
const best_score_storage_path = "best_score";

fn loadBestScore(state: *GameState) !void {
    const storage: *c.SDL_Storage = try errify(c.SDL_OpenUserStorage(best_score_storage_org, best_score_storage_app, 0));
    defer errify(c.SDL_CloseStorage(storage)) catch {};

    std.debug.assert(c.SDL_StorageReady(storage));

    const default_score = 100 * Timekeeper.updates_per_s;

    var best_score_le: u32 = undefined;
    errify(c.SDL_ReadStorageFile(storage, best_score_storage_path, &best_score_le, @sizeOf(u32))) catch {
        app_log.debug("failed to load best score: SDL error: {s}", .{c.SDL_GetError()});
        state.best_score = default_score;
        return;
    };
    state.best_score = @min(std.mem.littleToNative(u32, best_score_le), default_score);

    app_log.debug("loaded best score: {}", .{state.best_score});
}

fn saveBestScore(state: *GameState) !void {
    const storage: *c.SDL_Storage = try errify(c.SDL_OpenUserStorage(best_score_storage_org, best_score_storage_app, 0));
    defer errify(c.SDL_CloseStorage(storage)) catch {};

    std.debug.assert(c.SDL_StorageReady(storage));

    const best_score_le = std.mem.nativeToLittle(u32, state.best_score);
    try errify(c.SDL_WriteStorageFile(storage, best_score_storage_path, &best_score_le, @sizeOf(u32)));

    app_log.debug("saved best score: {}", .{state.best_score});
}

fn fmtSdlDrivers(
    current_driver: [*:0]const u8,
    num_drivers: c_int,
    getDriver: *const fn (c_int) callconv(.c) ?[*:0]const u8,
) FormatSdlDrivers {
    return .{
        .current_driver = current_driver,
        .num_drivers = num_drivers,
        .getDriver = getDriver,
    };
}

const FormatSdlDrivers = struct {
    current_driver: [*:0]const u8,
    num_drivers: c_int,
    getDriver: *const fn (c_int) callconv(.c) ?[*:0]const u8,

    pub fn format(context: FormatSdlDrivers, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var i: c_int = 0;
        while (i < context.num_drivers) : (i += 1) {
            if (i != 0) {
                try writer.writeAll(", ");
            }
            const driver = context.getDriver(i).?;
            try writer.writeAll(std.mem.span(driver));
            if (std.mem.orderZ(u8, context.current_driver, driver) == .eq) {
                try writer.writeAll(" (current)");
            }
        }
    }
};

/// Converts the return value of an SDL function to an error union.
inline fn errify(value: anytype) error{SdlError}!switch (@typeInfo(@TypeOf(value))) {
    .bool => void,
    .pointer, .optional => @TypeOf(value.?),
    .int => |info| switch (info.signedness) {
        .signed => @TypeOf(@max(0, value)),
        .unsigned => @TypeOf(value),
    },
    else => @compileError("unerrifiable type: " ++ @typeName(@TypeOf(value))),
} {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => if (!value) error.SdlError,
        .pointer, .optional => value orelse error.SdlError,
        .int => |info| switch (info.signedness) {
            .signed => if (value >= 0) @max(0, value) else error.SdlError,
            .unsigned => if (value != 0) value else error.SdlError,
        },
        else => comptime unreachable,
    };
}

fn logGameError(comptime where: []const u8, err: anyerror) void {
    if (err == error.SdlError) {
        sdl_log.err(where ++ ": {s}", .{c.SDL_GetError()});
    } else {
        app_log.err(where ++ ": {s}", .{@errorName(err)});
    }
}

//#region Exported C ABI

export fn gameStateSize() usize {
    return @sizeOf(GameState);
}

export fn gameStateAlign() usize {
    return @alignOf(GameState);
}

export fn gameInit(state_opaque: *anyopaque) callconv(.c) bool {
    const state: *GameState = @ptrCast(@alignCast(state_opaque));
    gameInitImpl(state) catch |err| {
        logGameError("gameInit", err);
        return false;
    };
    return true;
}

export fn gameEvent(state_opaque: *anyopaque, event: *c.SDL_Event) callconv(.c) bool {
    const state: *GameState = @ptrCast(@alignCast(state_opaque));
    return gameEventImpl(state, event) catch |err| {
        logGameError("gameEvent", err);
        return false;
    };
}

export fn gameIterate(state_opaque: *anyopaque) callconv(.c) bool {
    const state: *GameState = @ptrCast(@alignCast(state_opaque));
    return gameIterateImpl(state) catch |err| {
        logGameError("gameIterate", err);
        return false;
    };
}

export fn gameQuit(state_opaque: *anyopaque) callconv(.c) void {
    const state: *GameState = @ptrCast(@alignCast(state_opaque));
    gameQuitImpl(state);
}

export fn gameReloaded(state_opaque: *anyopaque) callconv(.c) void {
    _ = state_opaque;
    app_log.debug("game module reloaded", .{});
}

//#endregion Exported C ABI
