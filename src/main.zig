const std = @import("std");
const testing = std.testing;

pub const Repo = struct {
    allocator: std.mem.Allocator,
    characters: std.ArrayListUnmanaged(Character),
    ops: std.AutoArrayHashMapUnmanaged(Op.Id, Op.Action),
    nextId: Op.Id,

    pub fn init(allocator: std.mem.Allocator, clientId: u64) !@This() {
        var characters = std.ArrayList(Character).init(allocator);
        try characters.append(.{
            .id = .{ .counter = 0, .client = 0 },
            .character = ' ',
            .deleted = true,
        });

        return @This(){
            .allocator = allocator,
            .characters = characters.moveToUnmanaged(),
            .ops = .{},
            .nextId = .{
                .counter = 1,
                .client = clientId,
            },
        };
    }

    pub fn deinit(this: *@This()) void {
        this.characters.deinit(this.allocator);
        this.ops.deinit(this.allocator);
    }

    pub fn getTextAlloc(this: @This(), allocator: std.mem.Allocator) ![]const u8 {
        var text_str = std.ArrayList(u8).init(allocator);
        defer text_str.deinit();
        for (this.characters.items) |character| {
            if (character.deleted) continue;
            try text_str.append(character.character);
        }
        return text_str.toOwnedSlice();
    }

    pub fn merge(this: *@This(), other: @This()) !void {
        var iter = other.ops.iterator();
        while (iter.next()) |other_entry| {
            const other_id = other_entry.key_ptr.*;
            const other_action = other_entry.value_ptr.*;

            if (this.ops.get(other_id)) |own_action| {
                std.debug.assert(own_action.eql(other_action));
                continue;
            }

            switch (other_action) {
                .insert => |data| {
                    // Find position of character to insert after
                    var pos: usize = 0;
                    for (this.characters.items) |char, idx| {
                        if (char.id.eql(data.after)) {
                            pos = idx;
                            break;
                        }
                    } else {
                        return error.InvalidIdForAfter;
                    }

                    try this.ops.put(this.allocator, other_id, other_action);
                    try this.characters.insert(this.allocator, pos + 1, .{
                        .id = other_id,
                        .character = data.character,
                        .deleted = false,
                    });
                },
            }
        }
    }

    pub fn insertText(this: *@This(), pos: u32, text: []const u8) !void {
        if (pos > this.characters.items.len) return error.OutOfBounds;
        var after_id = this.characters.items[pos].id;
        for (text) |c, i| {
            try this.ops.put(this.allocator, this.nextId, .{ .insert = .{ .after = after_id, .character = c } });
            try this.characters.insert(this.allocator, pos + i + 1, .{
                .id = this.nextId,
                .character = c,
                .deleted = false,
            });
            after_id = this.nextId;
            this.nextId.counter += 1;
        }
    }

    pub fn eql(a: @This(), b: @This()) bool {
        if (a.ops.count() != b.ops.count() or a.characters.items.len != b.characters.items.len) return false;

        var ops_iter = a.ops.iterator();
        while (ops_iter.next()) |a_entry| {
            const b_entry = b.ops.get(a_entry.key_ptr.*) orelse return false;
            if (!b_entry.eql(a_entry.value_ptr.*)) {
                return false;
            }
        }

        for (a.characters.items) |a_char, idx| {
            const b_char = b.characters.items[idx];
            if (!a_char.eql(b_char)) {
                return false;
            }
        }

        return true;
    }
};

const Character = struct {
    // The id of the Op that inserted this character
    id: Op.Id,
    character: u8,
    deleted: bool,

    pub fn eql(a: @This(), b: @This()) bool {
        return a.id.eql(b.id) and a.character == b.character and a.deleted == b.deleted;
    }
};

const Op = struct {
    id: Id,
    action: Action,

    const Id = packed struct {
        counter: u64,
        client: u64,

        pub fn eql(a: @This(), b: @This()) bool {
            return a.counter == b.counter and a.client == b.client;
        }
    };

    pub const Action = union(enum) {
        insert: struct { after: Op.Id, character: u8 },

        pub fn eql(a: @This(), b: @This()) bool {
            return switch (a) {
                .insert => b == .insert and a.insert.after.eql(b.insert.after) and a.insert.character == b.insert.character,
            };
        }
    };
};

test "plaintext insertion" {
    var alice = try Repo.init(std.testing.allocator, 1);
    defer alice.deinit();
    try alice.insertText(0, "The fox jumped.");

    var bob = try Repo.init(std.testing.allocator, 2);
    defer bob.deinit();
    try bob.merge(alice);

    try alice.insertText(4, "quick ");
    try bob.insertText(14, " over the dog");

    var merge = try Repo.init(std.testing.allocator, 3);
    defer merge.deinit();
    try merge.merge(alice);
    try merge.merge(bob);

    var other_merge = try Repo.init(std.testing.allocator, 4);
    defer other_merge.deinit();
    try other_merge.merge(bob);
    try other_merge.merge(alice);

    try testing.expect(merge.eql(other_merge));

    const text = try merge.getTextAlloc(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try testing.expectEqualStrings("The quick fox jumped over the dog.", text);
}
