const std = @import("std");
const vaxis = @import("vaxis");
const app_module = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var io_buffer: [1024]u8 = undefined;
    var app: vaxis.vxfw.App = try .init(init.io, allocator, init.environ_map, &io_buffer);
    defer app.deinit();

    const model = try allocator.create(app_module.Model);
    defer allocator.destroy(model);
    model.* = .{};

    try app.run(model.widget(), .{});
}

test {
    std.testing.refAllDecls(@This());
}
