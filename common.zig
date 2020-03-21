const std = @import("std");
const mem = std.mem;
const os = std.os;

const logging = @import("./logging.zig");
const timing = @import("./timing.zig");

const panic = std.debug.panic;
const log = logging.log;
const fd_t = os.fd_t;
const Address = std.net.Address;

pub fn delaySeconds(seconds: u32, msg: []const u8) void {
    log("waiting {} seconds {}", .{seconds, msg});
    std.time.sleep(@intCast(u64, seconds) * std.time.ns_per_s);
}

pub fn makeListenSock(listenAddr: *Address) !fd_t {
    var flags : u32 = os.SOCK_STREAM;
    if (std.builtin.os.tag != .windows) {
        flags = flags | os.SOCK_NONBLOCK;
    }
    const sockfd = try os.socket(listenAddr.any.family, flags, os.IPPROTO_TCP);
    errdefer os.close(sockfd);
    if (std.builtin.os.tag != .windows) {
        try os.setsockopt(sockfd, os.SOL_SOCKET, os.SO_REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    }
    os.bind(sockfd, &listenAddr.any, listenAddr.getOsSockLen()) catch |e| {
        std.debug.warn("bind to address '{}' failed: {}\n", .{listenAddr, e});
        return error.AlreadyReported;
    };
    os.listen(sockfd, 8) catch |e| {
        std.debug.warn("listen failed: {}\n", .{e});
        return error.AlreadyReported;
    };
    return sockfd;
}

pub fn getsockerror(sockfd: fd_t) !c_int {
    var errorCode : c_int = undefined;
    var resultLen : os.socklen_t = @sizeOf(c_int);
    switch (os.errno(os.linux.getsockopt(sockfd, os.SOL_SOCKET, os.SO_ERROR, @ptrCast([*]u8, &errorCode), &resultLen))) {
        0 => return errorCode,
        os.EBADF => unreachable,
        os.EFAULT => unreachable,
        os.EINVAL => unreachable,
        os.ENOPROTOOPT => unreachable,
        os.ENOTSOCK => unreachable,
        else => |err| return os.unexpectedErrno(err),
    }
}

pub fn connect(sockfd: fd_t, addr: *const Address) os.ConnectError!void {
    return os.connect(sockfd, &addr.any, addr.getOsSockLen());
}
pub fn connectHost(host: []const u8, port: u16) !fd_t {
    // so far only ipv4 addresses supported
    const addr = Address.parseIp4(host, port) catch
        return error.DnsAndIPv6NotSupported;
    const sockfd = try os.socket(addr.any.family, os.SOCK_STREAM, os.IPPROTO_TCP);
    errdefer os.close(sockfd);
    try os.connect(sockfd, &addr.any, addr.getOsSockLen());
    return sockfd;
}

pub fn shutdown(sockfd: fd_t) !void {
    switch (os.errno(os.linux.shutdown(sockfd, os.SHUT_RDWR))) {
        0 => return,
        os.EBADF => return error.BadFileDescriptor,
        os.EINVAL => unreachable,
        os.ENOTCONN => return, // already shutdown
        os.ENOTSOCK => return error.BadFileDescriptor,
        os.ENOBUFS => return error.OutOfResources,
        else => |err| return os.unexpectedErrno(err),
    }
}

pub fn shutdownclose(sockfd: fd_t) void {
    shutdown(sockfd) catch { }; // ignore error
    os.close(sockfd);
}

pub fn sendfull(sockfd: fd_t, buf: []const u8, flags: u32) !void {
    var totalSent : usize = 0;
    while (totalSent < buf.len) {
        const lastSent = try os.send(sockfd, buf[totalSent..], flags);
        if (lastSent == 0)
            return error.SendReturnedZero;
        totalSent += lastSent;
    }
}
pub fn writeFull(fd: fd_t, buf: []const u8) !void {
    var totalSent : usize = 0;
    while (totalSent < buf.len) {
        const lastSent = try os.write(fd, buf[totalSent..]);
        if (lastSent == 0)
            return error.WriteReturnedZero;
        totalSent += lastSent;
    }
}

fn waitGenericTimeout(fd: fd_t, timeoutMillis: i32, events: i16) !bool {
    var pollfds = [1]os.linux.pollfd {
        os.linux.pollfd { .fd = fd, .events = events, .revents = undefined },
    };
    const result = os.poll(&pollfds, timeoutMillis) catch |e| switch (e) {
        error.SystemResources
        => {
            log("poll function failed with {}", .{e});
            return error.Retry;
        },
        error.Unexpected
        => panic("poll function failed with {}", .{e}),
    };
    if (result == 0) return false; // timeout
    if (result == 1) return true; // socket is readable
    panic("poll function with only 1 fd returned {}", .{result});
}

// returns: true if readable, false on timeout
pub fn waitReadableTimeout(fd: fd_t, timeoutMillis: i32) !bool {
    return waitGenericTimeout(fd, timeoutMillis, os.POLLIN);
}
pub fn waitReadable(fd: fd_t) !void {
    if (!try waitReadableTimeout(fd, -1))
        panic("poll function with infinite timeout returned 0", .{});
}

pub fn waitWriteableTimeout(fd: fd_t, timeoutMillis: i32) !bool {
    return waitGenericTimeout(fd, timeoutMillis, os.POLLOUT);
}

pub fn recvfull(sockfd: fd_t, buf: []u8) !void {
    var totalReceived : usize = 0;
    while (totalReceived < buf.len) {
        const lastReceived = try os.read(sockfd, buf[totalSent..]);
        //if (lastReceived == 0)
        //    return error.SendReturnedZero;
        //totalSent += lastSent;
        return error.NotImplemented;
    }
}
pub fn recvfullTimeout(sockfd: fd_t, buf: []u8, timeoutMillis: u32) !bool {
    var newTimeoutMillis = timeoutMillis;
    var totalReceived : usize = 0;
    while (newTimeoutMillis > @intCast(u32, std.math.maxInt(i32))) {
        const received = try recvfullTimeoutHelper(sockfd, buf[totalReceived..], std.math.maxInt(i32));
        totalReceived += received;
        if (totalReceived == buf.len) return true;
        newTimeoutMillis -= std.math.maxInt(i32);
    }
    totalReceived += try recvfullTimeoutHelper(sockfd, buf[totalReceived..], @intCast(i32, newTimeoutMillis));
    return totalReceived == buf.len;
}
fn recvfullTimeoutHelper(sockfd: fd_t, buf: []u8, timeoutMillis: i32) !usize {
    std.debug.assert(timeoutMillis >= 0); // code bug otherwise
    var totalReceived : usize = 0;
    if (buf.len > 0) {
        const startTime = std.time.milliTimestamp();
        while (true) {
            const readable = try waitReadableTimeout(sockfd, timeoutMillis);
            if (!readable) break;
            const result = try os.read(sockfd, buf[totalReceived..]);
            if (result <= 0) break;
            totalReceived += result;
            if (totalReceived == buf.len) break;
            const elapsed = timing.timestampDiff(std.time.milliTimestamp(), startTime);
            if (elapsed > timeoutMillis) break;
        }
        return totalReceived;
    }
    return totalReceived;
}

pub fn getOptArg(args: var, i: *usize) !@TypeOf(args[0]) {
    i.* += 1;
    if (i.* >= args.len) {
        std.debug.warn("Error: option '{}' requires an argument\n", .{args[i.* - 1]});
        return error.CommandLineOptionMissingArgument;
    }
    return args[i.*];
}

/// logs an error if it fails
pub fn parsePort(s: []const u8) !u16 {
    return std.fmt.parseInt(u16, s, 10) catch |e| {
        log("Error: failed to parse '{}' as a port: {}", .{s, e});
        return error.InvalidPortString;
    };
}
/// logs an error if it fails
pub fn parseIp4(s: []const u8, port: u16) !Address {
    return Address.parseIp4(s, port) catch |e| {
        log("Error: failed to parse '{}' as an IPv4 address: {}", .{s, e});
        return e;
    };
}

pub fn eventerAdd(comptime Eventer: type, eventer: *Eventer, fd: fd_t, flags: u32, callback: *Eventer.Callback) !void {
    eventer.add(fd, flags, callback) catch |e| switch (e) {
        error.SystemResources
        ,error.UserResourceLimitReached
        => {
            log("epoll add error {}", .{e});
            return error.Retry;
        },
        error.FileDescriptorAlreadyPresentInSet
        ,error.OperationCausesCircularLoop
        ,error.FileDescriptorNotRegistered
        ,error.FileDescriptorIncompatibleWithEpoll
        ,error.Unexpected
        => panic("epoll add failed with {}", .{e}),
    };
}

pub fn eventerInit(comptime Eventer: type, data: Eventer.EventerDataAlias) !Eventer {
    return Eventer.init(data) catch |e| switch (e) {
        error.ProcessFdQuotaExceeded
        ,error.SystemFdQuotaExceeded
        ,error.SystemResources
        => {
            log("epoll_create failed with {}", .{e});
            return error.Retry;
        },
        error.Unexpected
        => std.debug.panic("epoll_create failed with {}", .{e}),
    };
}