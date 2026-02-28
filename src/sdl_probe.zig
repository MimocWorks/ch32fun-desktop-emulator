const std = @import("std");

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_main.h");
    @cInclude("stdlib.h");
});

pub fn main() !void {
    preferX11VideoDriver();
    if (c.SDL_getenv("SDL_VIDEODRIVER")) |driver| {
        std.log.info("probe:env SDL_VIDEODRIVER={s}", .{std.mem.span(driver)});
    } else {
        std.log.info("probe:env SDL_VIDEODRIVER=<unset>", .{});
    }
    c.SDL_SetMainReady();
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInitFailed;
    defer c.SDL_Quit();
    if (c.SDL_GetCurrentVideoDriver()) |driver| {
        std.log.info("probe:current video driver={s}", .{std.mem.span(driver)});
    } else {
        std.log.info("probe:current video driver=<null>", .{});
    }

    const window = c.SDL_CreateWindow("SDL Probe", 640, 360, 0) orelse {
        std.log.err("SDL_CreateWindow failed: {s}", .{std.mem.span(c.SDL_GetError())});
        return error.SdlWindowFailed;
    };
    defer c.SDL_DestroyWindow(window);

    _ = c.SDL_SetWindowPosition(window, c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED);
    _ = c.SDL_ShowWindow(window);
    _ = c.SDL_RaiseWindow(window);
    c.SDL_PumpEvents();
    _ = c.SDL_SyncWindow(window);
    std.log.info("probe:window flags=0x{x}", .{c.SDL_GetWindowFlags(window)});
    var x: i32 = 0;
    var y: i32 = 0;
    _ = c.SDL_GetWindowPosition(window, &x, &y);
    std.log.info("probe:window position={},{}", .{ x, y });

    const start = std.time.nanoTimestamp();
    while (std.time.nanoTimestamp() - start < 5 * std.time.ns_per_s) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) return;
        }
        c.SDL_Delay(16);
    }
}

fn preferX11VideoDriver() void {
    if (c.SDL_getenv("SDL_VIDEODRIVER") != null) return;
    if (c.SDL_getenv("DISPLAY") == null) return;
    _ = c.setenv("SDL_VIDEODRIVER", "x11", 1);
}
