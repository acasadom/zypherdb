//! KvStore: envoltorio RAII minimo sobre LMDB.
//!
//! Deliberadamente NO hay jerarquia de clases: un unico tipo concreto, movible
//! (a traves de punteros a opacos de LMDB) y no copiable, con errores modelados
//! como valores (`error union`, el analogo a `std::expected`) en vez de
//! excepciones. Es el primer ladrillo de la capa de storage sobre la que luego
//! se construira la codificacion de claves para nodos, aristas y propiedades.

const std = @import("std");

const c = @import("lmdb.zig");

pub const KvError = error{
    OpenFailed,
    WriteFailed,
    ReadFailed,
    DeleteFailed,
    IteratorFailed,
    OutOfMemory,
};

pub const KvStore = struct {
    env: *c.MDB_env,
    dbi: c.MDB_dbi,
    allocator: std.mem.Allocator,

    /// Abre (o crea) un entorno LMDB en `path`. El directorio debe existir.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) KvError!KvStore {
        var env: ?*c.MDB_env = null;
        if (c.mdb_env_create(&env) != 0) return error.OpenFailed;
        errdefer c.mdb_env_close(env.?);

        // LMDB exige fijar un tamano maximo de mapa (reserva virtual, no RAM).
        if (c.mdb_env_set_mapsize(env.?, 1 << 30) != 0) return error.OpenFailed;

        const c_path = allocator.dupeSentinel(u8, path, 0) catch return error.OutOfMemory;
        defer allocator.free(c_path);

        if (c.mdb_env_open(env.?, c_path.ptr, 0, 0o644) != 0) return error.OpenFailed;

        // Abre la base de datos por defecto (sin nombre) en una transaccion.
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(env.?, null, 0, &txn) != 0) return error.OpenFailed;
        errdefer _ = c.mdb_txn_abort(txn.?);

        var dbi: c.MDB_dbi = 0;
        if (c.mdb_dbi_open(txn.?, null, 0, &dbi) != 0) return error.OpenFailed;
        if (c.mdb_txn_commit(txn.?) != 0) {
            _ = c.mdb_txn_abort(txn.?);
            return error.OpenFailed;
        }

        return .{ .env = env.?, .dbi = dbi, .allocator = allocator };
    }

    pub fn deinit(self: *KvStore) void {
        c.mdb_env_close(self.env);
    }

    pub fn put(self: *KvStore, key: []const u8, value: []const u8) KvError!void {
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, 0, &txn) != 0) return error.WriteFailed;

        var key_val = makeVal(key);
        var data_val = makeVal(value);
        if (c.mdb_put(txn.?, self.dbi, &key_val, &data_val, 0) != 0) {
            _ = c.mdb_txn_abort(txn.?);
            return error.WriteFailed;
        }
        if (c.mdb_txn_commit(txn.?) != 0) {
            _ = c.mdb_txn_abort(txn.?);
            return error.WriteFailed;
        }
    }

    /// Una clave ausente es un resultado normal: `null`, no un error.
    /// El valor devuelto es una copia propiedad del llamante (liberar con
    /// `self.allocator.free`).
    pub fn get(self: *KvStore, key: []const u8) KvError!?[]u8 {
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, c.MDB_RDONLY, &txn) != 0) return error.ReadFailed;
        defer _ = c.mdb_txn_abort(txn.?);

        var key_val = makeVal(key);
        var data_val = c.MDB_val{ .mv_size = 0, .mv_data = null };
        const rc = c.mdb_get(txn.?, self.dbi, &key_val, &data_val);
        if (rc == c.MDB_NOTFOUND) return null;
        if (rc != 0) return error.ReadFailed;

        const bytes = valSlice(data_val);
        return self.allocator.dupe(u8, bytes) catch error.OutOfMemory;
    }

    pub fn exists(self: *KvStore, key: []const u8) KvError!bool {
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, c.MDB_RDONLY, &txn) != 0) return error.ReadFailed;
        defer _ = c.mdb_txn_abort(txn.?);

        var key_val = makeVal(key);
        var data_val = c.MDB_val{ .mv_size = 0, .mv_data = null };
        const rc = c.mdb_get(txn.?, self.dbi, &key_val, &data_val);
        if (rc == c.MDB_NOTFOUND) return false;
        if (rc != 0) return error.ReadFailed;
        return true;
    }

    /// Idempotente: borrar una clave inexistente es un exito.
    pub fn del(self: *KvStore, key: []const u8) KvError!void {
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, 0, &txn) != 0) return error.DeleteFailed;

        var key_val = makeVal(key);
        const rc = c.mdb_del(txn.?, self.dbi, &key_val, null);
        if (rc != 0 and rc != c.MDB_NOTFOUND) {
            _ = c.mdb_txn_abort(txn.?);
            return error.DeleteFailed;
        }
        if (c.mdb_txn_commit(txn.?) != 0) {
            _ = c.mdb_txn_abort(txn.?);
            return error.DeleteFailed;
        }
    }

    /// Iterador sobre todos los pares clave/valor cuya clave empieza por
    /// `prefix`, en orden lexicografico (que es el orden natural de LMDB).
    pub fn scanPrefix(self: *KvStore, prefix: []const u8) KvError!PrefixIterator {
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, c.MDB_RDONLY, &txn) != 0) return error.IteratorFailed;
        errdefer _ = c.mdb_txn_abort(txn.?);

        var cursor: ?*c.MDB_cursor = null;
        if (c.mdb_cursor_open(txn.?, self.dbi, &cursor) != 0) return error.IteratorFailed;
        errdefer c.mdb_cursor_close(cursor.?);

        const owned_prefix = self.allocator.dupe(u8, prefix) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_prefix);

        var key_val = makeVal(prefix);
        var data_val = c.MDB_val{ .mv_size = 0, .mv_data = null };
        const rc = c.mdb_cursor_get(cursor.?, &key_val, &data_val, c.MDB_SET_RANGE);
        const finished = rc == c.MDB_NOTFOUND;
        if (rc != 0 and rc != c.MDB_NOTFOUND) return error.IteratorFailed;

        return .{
            .store = self,
            .txn = txn.?,
            .cursor = cursor.?,
            .prefix = owned_prefix,
            .key = key_val,
            .data = data_val,
            .finished = finished,
        };
    }

    pub fn countPrefix(self: *KvStore, prefix: []const u8) KvError!usize {
        var it = try self.scanPrefix(prefix);
        defer it.deinit();

        var count: usize = 0;
        while (try it.next()) |_| count += 1;
        return count;
    }
};

/// Iterador de una sola pasada sobre un escaneo por prefijo. Propietario de la
/// transaccion y el cursor de LMDB; `deinit` los libera.
pub const PrefixIterator = struct {
    store: *KvStore,
    txn: *c.MDB_txn,
    cursor: *c.MDB_cursor,
    prefix: []u8,
    key: c.MDB_val,
    data: c.MDB_val,
    finished: bool,

    pub const Entry = struct { key: []const u8, value: []const u8 };

    pub fn deinit(self: *PrefixIterator) void {
        c.mdb_cursor_close(self.cursor);
        _ = c.mdb_txn_abort(self.txn);
        self.store.allocator.free(self.prefix);
    }

    fn inRange(self: *const PrefixIterator) bool {
        if (self.finished or self.key.mv_data == null) return false;
        const k: [*]const u8 = @ptrCast(self.key.mv_data.?);
        if (self.key.mv_size < self.prefix.len) return false;
        return std.mem.eql(u8, k[0..self.prefix.len], self.prefix);
    }

    /// Devuelve el siguiente par clave/valor, o `null` al final. Las vistas
    /// devueltas apuntan a memoria de LMDB y solo son validas hasta la
    /// siguiente llamada a `next`.
    pub fn next(self: *PrefixIterator) KvError!?Entry {
        if (!self.inRange()) {
            self.finished = true;
            return null;
        }
        const k: [*]const u8 = @ptrCast(self.key.mv_data.?);
        const v: [*]const u8 = @ptrCast(self.data.mv_data.?);
        const entry = Entry{ .key = k[0..self.key.mv_size], .value = v[0..self.data.mv_size] };

        const rc = c.mdb_cursor_get(self.cursor, &self.key, &self.data, c.MDB_NEXT);
        if (rc == c.MDB_NOTFOUND) {
            self.finished = true;
        } else if (rc != 0) {
            return error.IteratorFailed;
        }
        return entry;
    }
};

fn makeVal(bytes: []const u8) c.MDB_val {
    const ptr: *anyopaque = @ptrCast(@constCast(bytes.ptr));
    return .{ .mv_size = bytes.len, .mv_data = ptr };
}

fn valSlice(v: c.MDB_val) []const u8 {
    if (v.mv_size == 0) return &.{};
    const p: [*]const u8 = @ptrCast(v.mv_data.?);
    return p[0..v.mv_size];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testPath(tmp: *testing.TmpDir, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;
}

test "KvStore abre, escribe y lee una clave" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = testPath(&tmp, &path_buf);

    var store = try KvStore.open(testing.allocator, path);
    defer store.deinit();

    try store.put("saludo", "hola acmedb");

    const got = try store.get("saludo");
    defer if (got) |g| testing.allocator.free(g);
    try testing.expect(got != null);
    try testing.expectEqualStrings("hola acmedb", got.?);
}

test "get de una clave inexistente devuelve null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = testPath(&tmp, &path_buf);

    var store = try KvStore.open(testing.allocator, path);
    defer store.deinit();

    const got = try store.get("no_existe");
    defer if (got) |g| testing.allocator.free(g);
    try testing.expect(got == null);
}

test "exists distingue presente de ausente" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = testPath(&tmp, &path_buf);

    var store = try KvStore.open(testing.allocator, path);
    defer store.deinit();

    try store.put("a", "1");

    try testing.expect(try store.exists("a"));
    try testing.expect(!try store.exists("b"));
}

test "del borra una clave y es idempotente" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = testPath(&tmp, &path_buf);

    var store = try KvStore.open(testing.allocator, path);
    defer store.deinit();

    try store.put("k", "v");
    try store.del("k");

    const got = try store.get("k");
    defer if (got) |g| testing.allocator.free(g);
    try testing.expect(got == null);

    // Borrar una clave ausente sigue siendo un exito.
    try store.del("k");
}

test "scanPrefix devuelve solo las claves del prefijo, en orden" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = testPath(&tmp, &path_buf);

    var store = try KvStore.open(testing.allocator, path);
    defer store.deinit();

    const pairs = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "n:a", .v = "1" },
        .{ .k = "n:b", .v = "2" },
        .{ .k = "n:c", .v = "3" },
        .{ .k = "x:z", .v = "9" },
    };
    for (pairs) |p| try store.put(p.k, p.v);

    var it = try store.scanPrefix("n:");
    defer it.deinit();

    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(testing.allocator);

    while (try it.next()) |entry| {
        try seen.append(testing.allocator, entry.key);
    }

    try testing.expectEqual(@as(usize, 3), seen.items.len);
    try testing.expectEqualStrings("n:a", seen.items[0]);
    try testing.expectEqualStrings("n:b", seen.items[1]);
    try testing.expectEqualStrings("n:c", seen.items[2]);
}

test "countPrefix cuenta las claves de un prefijo" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = testPath(&tmp, &path_buf);

    var store = try KvStore.open(testing.allocator, path);
    defer store.deinit();

    for ([_][]const u8{ "n:a", "n:b", "x:z" }) |k| try store.put(k, "v");

    try testing.expectEqual(@as(usize, 2), try store.countPrefix("n:"));
    try testing.expectEqual(@as(usize, 0), try store.countPrefix("q:"));
}
