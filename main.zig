const std = @import("std");

/// Example tagged-union which we want to store in a "packed" way.
///
/// Doing just `[]Animal` wastes a lot of space.
/// There is padding of the tag in the tagged-union.
///
/// Even if we store it in a `std.MultiArrayList(Animal)`,
/// which separates the tags and paylods into two separate
/// arrays, we still waste a space of the individual payloads.
///
/// For example `Bird` needs only a single byte. If we stored
/// the union of payloads in an array (inside the `std.MultiArrayList`),
/// every single `Bird` in this array would waste `64 - 8 = 56` bits.
///
/// ... therefore, we are going to do the stuff that is done below.
pub const Animal = union(enum(u8)) {
    cat: Cat,
    dog: Dog,
    bird: Bird,
    snake: Snake,

    // NOTE: All payloads (`Cat`, `Dog`, `Bird`, and `Snake`) are `packed` structs.
    //       This means they are only a simple integer under the hood.
    //
    //       This is not required, but makes it easier (and potentially faster)
    //       to serialize and deserialize the structs into an array of bytes
    //       We can just cast the struct into the underlying integer (also called a "backing" integer).
    //
    //       Then we just write/read that integer into the bytes.

    pub const Cat = packed struct(u64) {
        jump_height: u32,
        meow_count: u32,
    };

    pub const Dog = packed struct(u32) {
        bark_volume: u32,
    };

    pub const Bird = packed struct(u8) {
        fly_speed: u8,
    };

    pub const Snake = packed struct(u64) {
        length: u32,
        sssss_volume: u32,
    };

    pub const Tag = std.meta.Tag(@This());
};

/// Writes an `animal` into `data` at position `writing_index` and increments `writing_index` so that
/// another animal can be written after it.
///
/// The write is done in a "packed" way - we store the tag first and then the payload
/// casted into its backing integer.
fn write_animal(animal: Animal, data: []u8, writing_index: *usize) void {
    switch (animal) {
        inline else => |payload, tag| {
            const Payload: type = @TypeOf(payload);
            const PayloadAsInteger: type = @typeInfo(Payload).@"struct".backing_integer.?;
            const payload_as_integer: PayloadAsInteger = @bitCast(payload);

            // Write the tag.
            data[writing_index.*] = @intFromEnum(tag);
            writing_index.* += 1;

            // Write payload (which is casted to an integer).
            std.mem.writeInt(
                PayloadAsInteger,
                data[(writing_index.*)..][0..@sizeOf(PayloadAsInteger)],
                payload_as_integer,
                .little, // Endianness of the `PayloadAsInteger`.
            );
            writing_index.* += @sizeOf(PayloadAsInteger);
        },
    }
}

/// Zero-sized helper struct with no data.
/// It acts just as a wrapper around its inner method `get`,
/// which reads the payload of an animal.
fn Accessor(comptime tag: Animal.Tag) type {
    const Payload = @FieldType(Animal, @tagName(tag));
    const PayloadAsInteger = @typeInfo(Payload).@"struct".backing_integer.?;

    return struct {
        /// Reads a payload of an animal variant from `data` at the position `reading_index` points to.
        /// Increments the `reading_index` accordingly.
        pub fn get(_: @This(), data: []const u8, reading_index: *usize) Payload {
            // Read the payload as an integer
            const payload_as_bytes = data[(reading_index.*)..][0..@sizeOf(PayloadAsInteger)];
            const payload_as_integer: PayloadAsInteger = std.mem.readInt(PayloadAsInteger, payload_as_bytes, .little);
            reading_index.* += @sizeOf(PayloadAsInteger);

            // Cast the payload from the integer into the actual type
            const payload: Payload = @bitCast(payload_as_integer);

            return payload;
        }
    };
}

/// Tagged-union with all payloads being zero-sized (`Accessor` does not carry any additional data).
/// Represents an `Animal` where only the tag has been read. The payload is still left to be read
/// by the corresponding `Accessor`.
///
/// For more information, see the `fetch_animal` function.
///
/// NOTE: This type can be generated completely in comptime, but it is explicitely listed here for clarity.
const AnimalFetch = union(Animal.Tag) {
    cat: Accessor(.cat),
    dog: Accessor(.dog),
    bird: Accessor(.bird),
    snake: Accessor(.snake),
};

/// Reads an animal from the `data` buffer.
/// Returns `null` if there are no more animals in the buffer.
///
/// If the `reading_index` is not at the end of `data`, this function
/// advances the `reading_index` only by a single byte, containing the `Animal.Tag`.
/// The actual reading of the payload of the animal is done later by the returned `AnimalFetch`.
///
/// ========== THE MAIN POINT OF DOING THIS ==========
/// The reading of the payload is postoned like this, because we don't want to return an `Animal` from this function.
/// That would require switching on the `tag` (the variable inside this function) and doing an `switch(tag) { inline else => |t| {...} } `.
/// Which would be fine, but that means that **the callee would have to do this switch again**, thus impacting the performance.
///
/// If the callee wants to convert the `AnimalFetch` into an `Animal`, they can do so by:
/// ```zig
/// const fetch: AnimalFetch = fetch_animal(...).?;
/// const animal: Animal = sw: switch (fetch) {
///     inline else => |accessor, tag|  {
///         const animal_payload = accessor.get(...);
///         break :sw @unionInit(Animal, @tagName(tag), animal_payload);
///     },
/// };
/// ```
fn fetch_animal(data: []const u8, reading_index: *usize) ?AnimalFetch {
    if (reading_index.* >= data.len) return null;

    // Read the tag.
    const tag_raw: u8 = data[reading_index.*];
    reading_index.* += 1;
    const tag: Animal.Tag = @enumFromInt(tag_raw);

    // Cast the tag into `AnimalFetch` (implicitly!!).
    // NOTE: This is actually amazing, that Zig supports this.
    //       If you think about it, we are casting an `enum` into a tagged-union.
    //       Zig let's us do this, since the payloads of all variants of `AnimalFetch` are zero-sized.
    //       Therefore the payloads cannot carry any additional data and the cast is possible.
    const fetch: AnimalFetch = tag; // No-op

    return fetch;
}

pub fn main() void {
    var buffer: [4096]u8 = undefined;

    // Write some animals into the `buffer`.
    var write_index: usize = 0;
    write_animal(.{ .snake = .{ .length = 10, .sssss_volume = 100 } }, &buffer, &write_index);
    write_animal(.{ .snake = .{ .length = 22, .sssss_volume = 222 } }, &buffer, &write_index);
    write_animal(.{ .cat = .{ .jump_height = 33, .meow_count = 3333 } }, &buffer, &write_index);
    write_animal(.{ .bird = .{ .fly_speed = 4 } }, &buffer, &write_index);
    write_animal(.{ .bird = .{ .fly_speed = 5 } }, &buffer, &write_index);
    write_animal(.{ .bird = .{ .fly_speed = 6 } }, &buffer, &write_index);
    const animals_compressed: []const u8 = buffer[0..write_index];

    // Read back the animals back (this could be completely elsewhere).
    // Notice how this usage is nice and almost the same as a naive way
    // of reading the animals as the tagged-union.
    var read_index: usize = 0;
    while (fetch_animal(animals_compressed, &read_index)) |fetched_animal| {
        switch (fetched_animal) {
            .bird => |accessor| {
                const bird: Animal.Bird = accessor.get(animals_compressed, &read_index);
                std.debug.print("Read BIRD:  {any}.\n", .{bird});
            },
            .snake => |accessor| {
                const snake: Animal.Snake = accessor.get(animals_compressed, &read_index);
                std.debug.print("Read SNAKE: {any}.\n", .{snake});
            },
            .dog => |accessor| {
                const dog: Animal.Dog = accessor.get(animals_compressed, &read_index);
                std.debug.print("Read DOG:   {any}.\n", .{dog});
            },
            .cat => |accessor| {
                const cat: Animal.Cat = accessor.get(animals_compressed, &read_index);
                std.debug.print("Read CAT:   {any}.\n", .{cat});
            },
        }
    }
}
