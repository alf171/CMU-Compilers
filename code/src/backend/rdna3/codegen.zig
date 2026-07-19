const std = @import("std");
const ArrayList = std.ArrayList;

const common = @import("common");
const Operand = common.alloc.Operand;
const Program = common.program.Program;
const TypeInfo = common.types.TypeInfo;
const Block = common.ir.BasicBlock;
const ConstValue = common.ir.ConstValue;
const Function = common.ir.Function;
const ValueRef = common.ir.ValueRef;
const getElementType = common.types.getElementType;
const ColoredGraph = @import("middle").color.ColoredGraph;
// TODO: change to gpu_abi
const Abi = @import("../cpu_abi.zig").CpuAbi;

pub fn emit(program: *const Program, alloc: std.mem.Allocator) ![]u8 {
    var out = ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    try emitHeader(&out, alloc);
    for (program.functions.items) |function| {
        if (function.kind == .gpu_kernel) {
            try emitKernelHeader(&out, function.name, alloc);
            for (function.blocks.items) |block| {
                for (block.instructions.items) |instruction| {
                    switch (instruction) {
                        .function_param => |fp| {
                            const dst = try vgprForOperand(fp.dst.operand);
                            switch (fp.index) {
                                0 => {
                                    try out.appendSlice(alloc, "\ts_load_b64 s[2:3], s[0:1], 0x0\n");
                                    // load is async so place a barrier
                                    try out.appendSlice(alloc, "\ts_waitcnt lgkmcnt(0)\n");
                                    try out.print(alloc, "\tv_mov_b32_e32 v{d}, s2\n", .{dst});
                                    try out.print(alloc, "\tv_mov_b32_e32 v{d}, s3\n", .{dst + 1});
                                },
                                1 => {
                                    try out.appendSlice(alloc, "\ts_load_b64 s[4:5], s[0:1], 0x8\n");
                                    // load is async so place a barrier
                                    try out.appendSlice(alloc, "\ts_waitcnt lgkmcnt(0)\n");
                                    try out.print(alloc, "\tv_mov_b32_e32 v{d}, s4\n", .{dst});
                                    try out.print(alloc, "\tv_mov_b32_e32 v{d}, s5\n", .{dst + 1});
                                },
                                else => return error.TooManyGpuArgs,
                            }
                        },
                        .global_idx => |gi| {
                            const dst = try vgprForOperand(gi.dst.operand);
                            try out.print(alloc, "\tv_mov_b32_e32 v{d}, v0\n", .{dst});
                            try out.print(alloc, "\tv_mov_b32_e32 v{d}, 0\n", .{dst + 1});
                        },
                        .lir => |lir| switch (lir) {
                            .move => |m| {
                                const dst = try vgprForOperand(m.dst.operand);
                                switch (m.src) {
                                    .constant => |c| switch (c) {
                                        .i64 => |i| {
                                            const bits: u64 = @bitCast(i);
                                            const low: u32 = @truncate(bits);
                                            const high: u32 = @truncate(bits >> 32);

                                            try out.print(alloc, "\tv_mov_b32_e32 v{d}, {d}\n", .{ dst, low });
                                            try out.print(alloc, "\tv_mov_b32_e32 v{d}, {d}\n", .{ dst + 1, high });
                                        },
                                        else => return error.NotImpl,
                                    },
                                    .top => return error.NotImpl,
                                }
                            },
                            .binop => |bop| {
                                const dst = try vgprForOperand(bop.dst.operand);
                                const lhs = try vgprForOperand(bop.lhs.operand);
                                const rhs = try vgprForOperand(bop.rhs.operand);
                                // HACK: 0 out bits 32-64
                                switch (bop.op) {
                                    .add => {
                                        try out.print(alloc, "\tv_add_u32 v{d}, v{d}, v{d}\n", .{ dst, lhs, rhs });
                                        try out.print(alloc, "\tv_mov_b32_e32 v{d}, 0\n", .{dst + 1});
                                    },
                                    .mul => {
                                        try out.print(alloc, "\tv_mul_lo_u32 v{d}, v{d}, v{d}\n", .{ dst, lhs, rhs });
                                        try out.print(alloc, "\tv_mov_b32_e32 v{d}, 0\n", .{dst + 1});
                                    },
                                    else => return error.NotImpl,
                                }
                            },
                            .store_offset => |so| {
                                const base = try vgprForOperand(so.dst.operand);
                                const offset = switch (so.offset) {
                                    .constant => return error.NotImpl,
                                    .top => |top| try vgprForOperand(top.operand),
                                };
                                const src = try vgprForOperand(so.src.operand);
                                // offset += base
                                try out.print(alloc, "\tv_add_co_u32 v{d}, vcc_lo, v{d}, v{d}\n", .{ offset, base, offset });
                                try out.print(alloc, "\tv_add_co_ci_u32 v{d}, vcc_lo, v{d}, v{d}, vcc_lo\n", .{ offset + 1, base + 1, offset + 1 });
                                // *(base + offset) = src
                                try out.print(alloc, "\tglobal_store_b64 v[{d}:{d}], v[{d}:{d}], off\n", .{ offset, offset + 1, src, src + 1 });
                            },
                            else => |e| {
                                std.debug.print("cant handle {s}\n", .{@tagName(e)});
                                return error.NotImpl;
                            },
                        },
                        .function_return => |fr| {
                            if (fr.value != null)
                                return error.UnsupportedGpu;
                            try out.appendSlice(alloc, "\ts_waitcnt vmcnt(0) lgkmcnt(0)\n");
                            try out.appendSlice(alloc, "\ts_endpgm\n");
                        },
                        else => return error.NotImpl,
                    }
                }
            }
            try emitKernelFooter(&out, function.name, alloc);
            try emitKernelDescriptor(&out, function.name, alloc);
        }
    }

    // try createFooter(&out, alloc);

    return out.toOwnedSlice(alloc);
}

// FIXME: remove this soon
fn vgprForOperand(operand: Operand) !usize {
    return switch (operand) {
        .temp => |t| 1 + (@as(usize, t.id) * 2),
        else => error.NotSupported,
    };
}

fn emitHeader(out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    try out.appendSlice(alloc, ".amdgcn_target \"amdgcn-amd-amdhsa--gfx1103\"\n");
    try out.appendSlice(alloc, ".amdhsa_code_object_version 6\n");
    try out.appendSlice(alloc, ".text\n");
}

fn emitKernelHeader(out: *std.ArrayList(u8), name: []const u8, alloc: std.mem.Allocator) !void {
    try out.print(alloc, ".protected {s}\n", .{name});
    try out.print(alloc, ".globl {s}\n", .{name});
    try out.appendSlice(alloc, ".p2align 8\n");
    // entry point
    try out.print(alloc, ".type {s},@function\n", .{name});
    try out.print(alloc, "{s}:\n", .{name});
}

fn emitKernelFooter(out: *std.ArrayList(u8), name: []const u8, alloc: std.mem.Allocator) !void {
    // record ELF size
    try out.print(alloc, ".L{s}_end:\n", .{name});
    try out.print(alloc, ".size {s}, .L{s}_end-{s}\n", .{ name, name, name });
}

fn emitKernelDescriptor(out: *std.ArrayList(u8), name: []const u8, alloc: std.mem.Allocator) !void {
    try out.appendSlice(alloc, "\t.p2align 6\n");
    try out.print(alloc, ".amdhsa_kernel {s}\n", .{name});
    try out.appendSlice(alloc, "\t.amdhsa_group_segment_fixed_size 0\n");
    try out.appendSlice(alloc, "\t.amdhsa_private_segment_fixed_size 0\n");
    try out.print(alloc, "\t.amdhsa_kernarg_size {d}\n", .{16});
    try out.appendSlice(alloc, "\t.amdhsa_user_sgpr_kernarg_segment_ptr 1\n");
    try out.appendSlice(alloc, "\t.amdhsa_system_sgpr_workgroup_id_x 1\n");
    // we are placing global_idx in v0
    try out.appendSlice(alloc, "\t.amdhsa_system_vgpr_workitem_id 0\n");
    // HACK: hard coding reg usage
    try out.appendSlice(alloc, "\t.amdhsa_next_free_vgpr 17\n");
    try out.appendSlice(alloc, "\t.amdhsa_next_free_sgpr 6\n");
    try out.appendSlice(alloc, "\t.amdhsa_wavefront_size32 1\n");
    try out.appendSlice(alloc, ".end_amdhsa_kernel\n");
}

test "testing" {}
