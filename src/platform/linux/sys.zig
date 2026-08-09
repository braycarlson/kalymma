const std = @import("std");

const assert = std.debug.assert;

const linux = std.os.linux;
const posix = std.posix;

pub const Fd = linux.fd_t;

pub const Error = error{
    Failed,
    Interrupted,
    WouldBlock,
};

pub const environ_bytes_max: u32 = 8 * 1024;
pub const environ_entries_max: u32 = 1024;
pub const environ_path = "/proc/self/environ";
pub const interrupt_retry_max: u32 = 64;
pub const path_bytes_max: u32 = 256;
pub const transfer_attempts_max: u32 = 4096;

comptime {
    assert(environ_bytes_max > 0);
    assert(environ_entries_max > 0);
    assert(environ_path.len > 0);
    assert(interrupt_retry_max > 0);
    assert(path_bytes_max > 0);
    assert(transfer_attempts_max > 0);
}

var environ_length: u32 = 0;
var environ_loaded: bool = false;
var environ_storage: [environ_bytes_max]u8 = undefined;

pub fn ok(raw: usize) bool {
    return posix.errno(raw) == .SUCCESS;
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

pub fn shutdown(fd: Fd) void {
    _ = linux.shutdown(fd, linux.SHUT.RDWR);
}

pub fn read(fd: Fd, buffer: []u8) Error!usize {
    assert(buffer.len > 0);

    var retries: u32 = 0;

    while (retries < interrupt_retry_max) : (retries += 1) {
        const raw = linux.read(fd, buffer.ptr, buffer.len);
        const status = posix.errno(raw);

        if (status == .SUCCESS) {
            assert(raw <= buffer.len);

            return raw;
        }

        if (status == .AGAIN) {
            return Error.WouldBlock;
        }

        if (status != .INTR) {
            return Error.Failed;
        }
    }

    return Error.Interrupted;
}

pub fn read_all(fd: Fd, buffer: []u8) Error!void {
    var filled: usize = 0;
    var attempts: u32 = 0;

    while (filled < buffer.len and attempts < transfer_attempts_max) : (attempts += 1) {
        const count = try read(fd, buffer[filled..]);

        if (count == 0) {
            return Error.Failed;
        }

        filled += count;
    }

    if (filled < buffer.len) {
        return Error.Failed;
    }
}

pub fn write(fd: Fd, bytes: []const u8) Error!usize {
    assert(bytes.len > 0);

    var retries: u32 = 0;

    while (retries < interrupt_retry_max) : (retries += 1) {
        const raw = linux.write(fd, bytes.ptr, bytes.len);
        const status = posix.errno(raw);

        if (status == .SUCCESS) {
            assert(raw <= bytes.len);

            return raw;
        }

        if (status != .INTR) {
            return Error.Failed;
        }
    }

    return Error.Interrupted;
}

pub fn write_all(fd: Fd, bytes: []const u8) Error!void {
    if (bytes.len == 0) {
        return;
    }

    var sent: usize = 0;
    var attempts: u32 = 0;

    while (sent < bytes.len and attempts < transfer_attempts_max) : (attempts += 1) {
        const count = try write(fd, bytes[sent..]);

        if (count == 0) {
            return Error.Failed;
        }

        sent += count;
    }

    if (sent < bytes.len) {
        return Error.Failed;
    }
}

pub fn unix_socket() Error!Fd {
    const raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);

    if (!ok(raw)) {
        return Error.Failed;
    }

    const result: Fd = @intCast(raw);

    return result;
}

pub fn connect_path(fd: Fd, path: []const u8) Error!void {
    if (path.len == 0 or path.len >= path_bytes_max) {
        return Error.Failed;
    }

    var address = linux.sockaddr.un{ .family = linux.AF.UNIX, .path = @splat(0) };

    if (path.len >= address.path.len) {
        return Error.Failed;
    }

    @memcpy(address.path[0..path.len], path);

    const length: u32 = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);

    const raw = linux.connect(fd, @ptrCast(&address), length);

    if (!ok(raw)) {
        return Error.Failed;
    }
}

pub fn open_read(path: [*:0]const u8) Error!Fd {
    const raw = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);

    if (!ok(raw)) {
        return Error.Failed;
    }

    const result: Fd = @intCast(raw);

    return result;
}

pub fn memfd(name: [*:0]const u8, size: usize) Error!Fd {
    assert(size > 0);

    const raw = linux.memfd_create(name, linux.MFD.CLOEXEC);

    if (!ok(raw)) {
        return Error.Failed;
    }

    const result: Fd = @intCast(raw);

    const sized = linux.ftruncate(result, @intCast(size));

    if (!ok(sized)) {
        close(result);

        return Error.Failed;
    }

    return result;
}

pub fn map_shared(fd: Fd, size: usize) Error![]align(std.heap.page_size_min) u8 {
    assert(size > 0);

    const raw = linux.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    if (!ok(raw)) {
        return Error.Failed;
    }

    const pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(raw);

    return pointer[0..size];
}

pub fn unmap(memory: []align(std.heap.page_size_min) u8) void {
    _ = linux.munmap(memory.ptr, memory.len);
}

pub fn event_fd() Error!Fd {
    const raw = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);

    if (!ok(raw)) {
        return Error.Failed;
    }

    const result: Fd = @intCast(raw);

    return result;
}

pub fn signal(fd: Fd) void {
    const value: u64 = 1;
    const bytes = std.mem.asBytes(&value);

    write_all(fd, bytes) catch {
        return;
    };
}

pub fn consume(fd: Fd) void {
    var value: u64 = 0;
    const bytes = std.mem.asBytes(&value);

    _ = read(fd, bytes) catch {
        return;
    };
}

pub fn wait(fds: []linux.pollfd, timeout_ms: i32) Error!u32 {
    assert(fds.len > 0);

    var retries: u32 = 0;

    while (retries < interrupt_retry_max) : (retries += 1) {
        const raw = linux.poll(fds.ptr, @intCast(fds.len), timeout_ms);
        const status = posix.errno(raw);

        if (status == .SUCCESS) {
            return @intCast(raw);
        }

        if (status != .INTR) {
            return Error.Failed;
        }
    }

    return Error.Interrupted;
}

pub fn send_with_fd(fd: Fd, bytes: []const u8, payload: Fd) Error!void {
    assert(bytes.len > 0);

    var vector = [_]posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};

    var control: [control_bytes]u8 align(@alignOf(cmsghdr)) = @splat(0);

    const header: *cmsghdr = @ptrCast(&control);

    header.* = .{
        .len = @sizeOf(cmsghdr) + @sizeOf(Fd),
        .level = linux.SOL.SOCKET,
        .type = scm_rights,
    };

    const slot: *align(1) Fd = @ptrCast(&control[@sizeOf(cmsghdr)]);

    slot.* = payload;

    var message = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &vector,
        .iovlen = 1,
        .control = &control,
        .controllen = header.len,
        .flags = 0,
    };

    var retries: u32 = 0;

    while (retries < interrupt_retry_max) : (retries += 1) {
        const raw = linux.sendmsg(fd, &message, 0);
        const status = posix.errno(raw);

        if (status == .SUCCESS) {
            if (raw != bytes.len) {
                return Error.Failed;
            }

            return;
        }

        if (status != .INTR) {
            return Error.Failed;
        }
    }

    return Error.Interrupted;
}

pub fn recv_discarding_fds(fd: Fd, buffer: []u8) Error!usize {
    assert(buffer.len > 0);

    var vector = [_]posix.iovec{.{ .base = buffer.ptr, .len = buffer.len }};

    var control: [control_bytes]u8 align(@alignOf(cmsghdr)) = @splat(0);

    var message = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &vector,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };

    var retries: u32 = 0;

    while (retries < interrupt_retry_max) : (retries += 1) {
        const raw = linux.recvmsg(fd, &message, 0);
        const status = posix.errno(raw);

        if (status == .SUCCESS) {
            close_control(&control, message.controllen);

            assert(raw <= buffer.len);

            return raw;
        }

        if (status == .AGAIN) {
            return Error.WouldBlock;
        }

        if (status != .INTR) {
            return Error.Failed;
        }
    }

    return Error.Interrupted;
}

fn close_control(control: []align(@alignOf(cmsghdr)) u8, length: usize) void {
    if (length < @sizeOf(cmsghdr) or length > control.len) {
        return;
    }

    const header: *const cmsghdr = @ptrCast(control);

    if (header.level != linux.SOL.SOCKET or header.type != scm_rights) {
        return;
    }

    if (header.len < @sizeOf(cmsghdr) or header.len > length) {
        return;
    }

    const payload = header.len - @sizeOf(cmsghdr);
    const total = payload / @sizeOf(Fd);

    var index: usize = 0;

    while (index < total) : (index += 1) {
        assert(index < total);

        const offset = @sizeOf(cmsghdr) + index * @sizeOf(Fd);
        const slot: *align(1) const Fd = @ptrCast(&control[offset]);

        close(slot.*);
    }
}

pub const cmsghdr = extern struct {
    len: usize,
    level: i32,
    type: i32,
};

pub const scm_rights: i32 = 1;
pub const control_bytes: usize = @sizeOf(cmsghdr) + 16;

pub fn getenv(key: []const u8) ?[]const u8 {
    assert(key.len > 0);

    load_environ();

    if (environ_length == 0) {
        return null;
    }

    var start: u32 = 0;
    var visited: u32 = 0;

    while (start < environ_length and visited < environ_entries_max) : (visited += 1) {
        const end = find_terminator(start);
        const entry = environ_storage[start..end];

        if (entry.len > key.len and entry[key.len] == '=') {
            if (std.mem.eql(u8, entry[0..key.len], key)) {
                return entry[key.len + 1 ..];
            }
        }

        start = end + 1;
    }

    return null;
}

fn find_terminator(start: u32) u32 {
    var index = start;

    while (index < environ_length) : (index += 1) {
        assert(index < environ_bytes_max);

        if (environ_storage[index] == 0) return index;
    }

    return environ_length;
}

fn load_environ() void {
    if (environ_loaded) {
        return;
    }

    environ_loaded = true;
    environ_length = 0;

    const fd = open_read(environ_path) catch {
        return;
    };

    defer close(fd);

    var filled: usize = 0;
    var attempts: u32 = 0;

    while (filled < environ_bytes_max and attempts < transfer_attempts_max) : (attempts += 1) {
        const count = read(fd, environ_storage[filled..]) catch {
            break;
        };

        if (count == 0) {
            break;
        }

        filled += count;
    }

    environ_length = @intCast(filled);

    assert(environ_length <= environ_bytes_max);
}

pub const Mutex = struct {
    const unlocked: u32 = 0;
    const locked: u32 = 1;
    const contended: u32 = 2;

    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(unlocked),

    pub fn try_lock(mutex: *Mutex) bool {
        return mutex.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null;
    }

    pub fn lock(mutex: *Mutex) void {
        if (mutex.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null) {
            return;
        }

        while (mutex.state.swap(contended, .acquire) != unlocked) {
            futex_wait(&mutex.state.raw);
        }
    }

    pub fn unlock(mutex: *Mutex) void {
        const previous = mutex.state.swap(unlocked, .release);

        assert(previous != unlocked);

        if (previous == contended) {
            futex_wake(&mutex.state.raw);
        }
    }
};

fn futex_wait(address: *const u32) void {
    _ = linux.futex_3arg(address, .{ .cmd = .WAIT, .private = true }, Mutex.contended);
}

fn futex_wake(address: *const u32) void {
    _ = linux.futex_3arg(address, .{ .cmd = .WAKE, .private = true }, 1);
}

const testing = std.testing;

test "a mutex locks, refuses a second acquire, and releases" {
    var mutex = Mutex{};

    try testing.expect(mutex.try_lock());
    try testing.expect(!mutex.try_lock());

    mutex.unlock();

    mutex.lock();
    mutex.unlock();

    try testing.expect(mutex.try_lock());

    mutex.unlock();
}

test "getenv finds a variable the kernel exported" {
    const path = getenv("PATH");
    const missing = getenv("KALYMMA_DEFINITELY_NOT_SET_1234");

    try testing.expect(path != null);
    try testing.expect(path.?.len > 0);
    try testing.expect(missing == null);
}

test "getenv rejects a prefix that is not a whole key" {
    const partial = getenv("PAT");

    try testing.expect(partial == null);
}

test "writing nothing is inert" {
    try write_all(-1, &.{});
}

test "an event fd signals and drains" {
    const fd = try event_fd();
    defer close(fd);

    signal(fd);
    consume(fd);

    var fds = [_]std.os.linux.pollfd{
        .{ .fd = fd, .events = 1, .revents = 0 },
    };

    try testing.expectEqual(@as(u32, 0), try wait(&fds, 0));
}

test "a shared mapping round trips through the descriptor" {
    const fd = try memfd("kalymma-test", 4096);
    defer close(fd);

    const memory = try map_shared(fd, 4096);
    defer unmap(memory);

    memory[0] = 0x5A;

    try testing.expectEqual(@as(u8, 0x5A), memory[0]);
}

test "a socket path longer than the address is refused" {
    const fd = try unix_socket();
    defer close(fd);

    const long = "x" ** path_bytes_max;

    try testing.expectError(Error.Failed, connect_path(fd, long));
    try testing.expectError(Error.Failed, connect_path(fd, ""));
}
