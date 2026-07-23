const std = @import("std");
const Program = @import("common").program.Program;
const ColoredGraph = @import("middle").color.ColoredGraph;
const CpuAbi = @import("cpu_abi.zig").CpuAbi;
const GpuAbi = @import("gpu_abi.zig").GpuAbi;
const ArmAbi = @import("arm/reg.zig").ArmAbi;
const arm_emit = @import("arm/codegen.zig").emit;
const X86Abi = @import("x86/reg.zig").X86Abi;
const x86_emit = @import("x86/codegen.zig").emit;
const Rnda3Abi = @import("rdna3/reg.zig").Rdna3Abi;
const rdna3_emit = @import("rdna3/codegen.zig").emit;

pub const Host = union(enum) {
    ARM,
    X86,
    RDNA3,
    UNKNOWN,

    pub fn toString(self: @This()) ![]const u8 {
        return switch (self) {
            .ARM => "arm",
            .X86 => "x86",
            .RDNA3 => "rdna3",
            else => return error.InvalidTarget,
        };
    }
    pub fn getPlatform(self: @This()) HostPlatform {
        return switch (self) {
            .ARM => .{
                .abi = ArmAbi,
                .emit = arm_emit,
            },
            .X86 => .{
                .abi = X86Abi,
                .emit = x86_emit,
            },
            else => unreachable,
        };
    }
};

pub const Device = union(enum) {
    host,
    gfx1103,
    pub fn getPlatform(self: @This()) DevicePlatform {
        return switch (self) {
            .gfx1103 => .{
                .abi = Rnda3Abi,
                .emit = rdna3_emit,
            },
            else => unreachable,
        };
    }
};

pub const Target = struct {
    host: Host,
    device: Device,
};

/// the contract which each platform will need to define
pub const HostPlatform = struct {
    abi: CpuAbi,
    emit: *const fn (
        program: *const Program,
        colors: *const ColoredGraph,
        abi: CpuAbi,
        alloc: std.mem.Allocator,
    ) anyerror![]u8,
};

pub const DevicePlatform = struct {
    abi: GpuAbi,
    emit: *const fn (
        program: *const Program,
        colors: *const ColoredGraph,
        abi: GpuAbi,
        alloc: std.mem.Allocator,
    ) anyerror![]u8,
};

pub const CompilationArifacts = struct {
    host_asm: []const u8,
    device_asm: ?[]const u8,

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.host_asm);
        if (self.device_asm) |device_asm| {
            alloc.free(device_asm);
        }
    }
};

pub const CompileRequest = struct {
    program: *const Program,
    target: Target,
    host_colors: *const ColoredGraph,
    device_colors: *const ColoredGraph,

    pub fn compile(self: @This(), alloc: std.mem.Allocator) !CompilationArifacts {
        const host_platform = self.target.host.getPlatform();

        const host_asm = try host_platform.emit(
            self.program,
            self.host_colors,
            host_platform.abi,
            alloc,
        );
        errdefer alloc.free(host_asm);

        const device_asm: ?[]const u8 = switch (self.target.device) {
            .host => null,
            .gfx1103 => blk: {
                const device_platform = self.target.device.getPlatform();
                break :blk try device_platform.emit(
                    self.program,
                    self.device_colors,
                    device_platform.abi,
                    alloc,
                );
            },
        };

        return .{
            .host_asm = host_asm,
            .device_asm = device_asm,
        };
    }
};
