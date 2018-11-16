const std = @import("std");
const math = std.math;
const assert = std.debug.assert;

pub const RoundMode = enum {
    NearestEven,
    NearestAwayFromZero,
    ToZero,
    ToPosInf,
    ToNegInf,
};

pub fn Parser(comptime Float: type) type {
    return struct {
        round_mode: RoundMode,
        state: State,
        is_negative: bool,
        whole_part: WholeInt,
        frac_part: FracInt,

        const Self = @This();

        const State = enum {
            Start,
            WholePart, // Same as Start, but we saw a minus sign.
            Decimal,
            DecimalStart,
        };

        // 112, 53, etc
        const mantissa_bits = math.floatMantissaBits(Float);

        // 15, 11, etc
        const exp_bits = math.floatExponentBits(Float);

        const whole_int_bits = 1 << (exp_bits - 1);
        const WholeInt = @IntType(false, whole_int_bits);

        const frac_int_bits = mantissa_bits + 1;
        const FracInt = @IntType(false, frac_int_bits);

        const Int = @IntType(false, Float.bit_count);

        pub fn init(round_mode: RoundMode) Self {
            return Self{
                .round_mode = round_mode,
                .state = State.Start,
                .is_negative = false,
                .whole_part = 0,
                .frac_part = 0,
            };
        }

        fn feedWholeByte(self: *Self, byte: u8) !void {
            const digit = try std.fmt.charToDigit(byte, 10);
            self.whole_part = try math.mul(WholeInt, self.whole_part, 10);
            self.whole_part = try math.add(WholeInt, self.whole_part, digit);
        }

        fn feedDecimal(self: *Self, byte: u8) void {
            const digit = try std.fmt.charToDigit(byte, 10);
            self.frac_part = math.mul(FracInt, self.frac_part, 10) catch |e| switch (e) {
                error.Overflow => state = State.IgnoreDecimal,
            };
            self.frac_part = math.add(FracInt, self.frac_part, digit) catch |e| switch (e) {
                error.Overflow => state = State.IgnoreDecimal,
            };
        }

        pub fn feed(self: *Self, in_bytes: []const u8) !void {
            for (in_bytes) |byte| {
                switch (self.state) {
                    State.Start => switch (byte) {
                        '0'...'9' => {
                            try self.feedWholeByte(byte);
                            self.state = State.WholePart;
                        },
                        '-' => {
                            self.is_negative = true;
                            self.state = State.WholePartStart;
                        },
                        '+' => {
                            self.state = State.WholePartStart;
                        },
                        '.' => {
                            self.state = State.DecimalStart;
                        },
                        else => return error.InvalidCharacter,
                    },
                    State.WholePart, State.WholePartStart => switch (byte) {
                        '0'...'9' => {
                            try self.feedWholeByte(byte);
                        },
                        'e', 'E' => @panic("TODO"),
                        'x' => @panic("TODO"),
                        '.' => self.state = State.DecimalStart,
                        else => return error.InvalidCharacter,
                    },
                    State.DecimalStart => switch (byte) {
                        '0'...'9' => {
                            self.feedDecimal(byte);
                            self.state = State.Decimal;
                        },
                        else => return error.InvalidCharacter,
                    },
                    State.Decimal => switch (byte) {
                        '0'...'9' => {
                            self.feedDecimal(byte);
                        },
                        'e', 'E' => @panic("TODO"),
                        else => return error.InvalidCharacter,
                    },
                }
            }
        }

        pub fn end(self: *Self) !Float {
            switch (self.state) {
                State.Start => return 0,
                State.WholePartStart => return error.InvalidFloat,
                State.DecimalStart => return error.InvalidFloat,
                State.WholePart => @panic("TODO"),
                State.Decimal => {
                    var result_int: Int = 0;
                    if (self.is_negative) {
                        result_int |= 1 << (Int.bit_count - 1);
                    }
                    const exp = math.log2(self.whole_part);

                    const leftover = self.whole_part - (1 << exp);
                },
            }
        }
    };
}

pub fn parseFloatRoundMode(
    comptime Float: type,
    buf: []const u8,
    round_mode: RoundMode,
) !Float {
    var parser = Parser(Float).init(round_mode);
    try parser.feed(buf);
    return parser.end();
}

/// buf contains UTF-8 encoded text representation of a floating
/// point number, in decimal or hex notation.
pub fn parseFloat(
    comptime Float: type,
    buf: []const u8,
) !Float {
    return parseFloatRoundMode(Float, buf, RoundMode.NearestEven);
}

test "parseFloat" {
    const result = try parseFloat(f32, "-1.2");
    assert(result == -1.2);
}

// 1230.0000000000000
// 12300.000000000000
// 123000.00000000000
// 1.0
// 0.156250000000
// 0.15625
// -1.2
// +1.2
// 1.2E5
// 1.2e5
// 1.2e-5
// 1.2e+5
// 1e10
// 0x0.000003fcp-1022 // 1.5
// -0x0.000003fcp-1022 // -1.5
// .42
