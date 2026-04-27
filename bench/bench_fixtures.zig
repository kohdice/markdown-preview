const std = @import("std");
const fixtures = @import("fixtures");

const cached_fixture_specs = [_]fixtures.Spec{
    fixtures.sample_ascii,
    fixtures.sample_cjk,
    fixtures.stress_ascii,
    fixtures.stress_cjk,
};

pub fn main(init: std.process.Init) !void {
    for (cached_fixture_specs) |spec| try fixtures.ensure(init.gpa, init.io, spec);
}
