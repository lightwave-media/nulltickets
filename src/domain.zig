const std = @import("std");

pub const PipelineDefinition = struct {
    initial: []const u8,
    states: std.json.ArrayHashMap(StateDef),
    transitions: []const TransitionDef,
};

pub const ParsedPipeline = std.json.Parsed(PipelineDefinition);

pub const StateDef = struct {
    agent_role: ?[]const u8 = null,
    description: ?[]const u8 = null,
    terminal: ?bool = null,
    workflow_id: ?[]const u8 = null,
};

pub const TransitionDef = struct {
    from: []const u8,
    to: []const u8,
    trigger: []const u8,
    instructions: ?[]const u8 = null,
    required_gates: ?[]const []const u8 = null,
};

pub const ValidationError = error{
    InvalidJson,
    MissingInitial,
    MissingStates,
    MissingTransitions,
    InitialStateNotFound,
    TransitionReferencesUnknownState,
    NoTerminalState,
    NonTerminalStateHasNoOutgoingTransition,
};

pub fn parseAndValidate(allocator: std.mem.Allocator, json_str: []const u8) ValidationError!ParsedPipeline {
    var parsed = std.json.parseFromSlice(PipelineDefinition, allocator, json_str, .{
        .ignore_unknown_fields = true,
    }) catch return ValidationError.InvalidJson;
    errdefer parsed.deinit();

    try validateDefinition(parsed.value);
    return parsed;
}

pub fn validatePipeline(allocator: std.mem.Allocator, json_str: []const u8) ValidationError!void {
    var parsed = try parseAndValidate(allocator, json_str);
    defer parsed.deinit();
}

fn validateDefinition(def: PipelineDefinition) ValidationError!void {
    if (def.initial.len == 0) return ValidationError.MissingInitial;
    if (def.states.map.count() == 0) return ValidationError.MissingStates;
    if (def.transitions.len == 0) return ValidationError.MissingTransitions;
    if (!def.states.map.contains(def.initial)) return ValidationError.InitialStateNotFound;

    for (def.transitions) |t| {
        if (!def.states.map.contains(t.from)) return ValidationError.TransitionReferencesUnknownState;
        if (!def.states.map.contains(t.to)) return ValidationError.TransitionReferencesUnknownState;
    }

    var has_terminal = false;
    var states_iter = def.states.map.iterator();
    while (states_iter.next()) |entry| {
        if (entry.value_ptr.terminal orelse false) {
            has_terminal = true;
            break;
        }
    }
    if (!has_terminal) return ValidationError.NoTerminalState;

    var states_iter2 = def.states.map.iterator();
    while (states_iter2.next()) |entry| {
        const is_terminal = entry.value_ptr.terminal orelse false;
        if (is_terminal) continue;

        var has_outgoing = false;
        for (def.transitions) |t| {
            if (std.mem.eql(u8, t.from, entry.key_ptr.*)) {
                has_outgoing = true;
                break;
            }
        }
        if (!has_outgoing) return ValidationError.NonTerminalStateHasNoOutgoingTransition;
    }
}

pub fn isTerminal(def: PipelineDefinition, stage: []const u8) bool {
    if (def.states.map.get(stage)) |state| {
        return state.terminal orelse false;
    }
    return false;
}

pub fn findTransition(def: PipelineDefinition, from_stage: []const u8, trigger: []const u8) ?TransitionDef {
    for (def.transitions) |t| {
        if (std.mem.eql(u8, t.from, from_stage) and std.mem.eql(u8, t.trigger, trigger)) {
            return t;
        }
    }
    return null;
}

pub fn getAvailableTransitions(allocator: std.mem.Allocator, def: PipelineDefinition, stage: []const u8) ![]const TransitionDef {
    var results: std.ArrayListUnmanaged(TransitionDef) = .empty;
    for (def.transitions) |t| {
        if (std.mem.eql(u8, t.from, stage)) {
            try results.append(allocator, t);
        }
    }
    return results.toOwnedSlice(allocator);
}

pub fn validationErrorMessage(err: ValidationError) []const u8 {
    return switch (err) {
        ValidationError.InvalidJson => "Invalid JSON in pipeline definition",
        ValidationError.MissingInitial => "Missing 'initial' field",
        ValidationError.MissingStates => "Missing or empty 'states' field",
        ValidationError.MissingTransitions => "Missing or empty 'transitions' field",
        ValidationError.InitialStateNotFound => "Initial state not found in states",
        ValidationError.TransitionReferencesUnknownState => "Transition references unknown state",
        ValidationError.NoTerminalState => "No terminal state defined",
        ValidationError.NonTerminalStateHasNoOutgoingTransition => "Non-terminal state has no outgoing transition",
    };
}

// Conformance: the shipped examples/agile-board.pipeline.json must parse,
// validate, and faithfully encode the canonical Agile board (lightwave-core
// task_statuses v3.0.0). This pins the runtime pipeline to the stamp so the
// example cannot bit-rot away from the board it claims to mirror.
test "agile-board example pipeline conforms to the canonical board" {
    const json = @embedFile("pipelines/agile-board.pipeline.json");
    var parsed = try parseAndValidate(std.testing.allocator, json);
    defer parsed.deinit();
    const def = parsed.value;

    try std.testing.expectEqualStrings("open", def.initial);
    // 15 board statuses (10 delivery/shared + 5 bug-lane).
    try std.testing.expectEqual(@as(usize, 15), def.states.map.count());

    // The four terminals are terminal; an in-flight state is not.
    for ([_][]const u8{ "closed", "not_doing", "not_a_bug", "cannot_reproduce" }) |term| {
        try std.testing.expect(isTerminal(def, term));
    }
    try std.testing.expect(!isTerminal(def, "in_review"));

    // The converge gate rides on in_review --approve--> ready_for_deployment.
    const approve = findTransition(def, "in_review", "approve") orelse return error.MissingApprove;
    try std.testing.expectEqualStrings("ready_for_deployment", approve.to);
    const gates = approve.required_gates orelse return error.MissingGate;
    try std.testing.expectEqual(@as(usize, 1), gates.len);
    try std.testing.expectEqualStrings("no-blockers", gates[0]);

    // The bug lane converges back into the delivery lane at prioritized.
    const rejoin = findTransition(def, "awaiting_prioritization", "prioritize") orelse return error.MissingRejoin;
    try std.testing.expectEqualStrings("prioritized", rejoin.to);

    // Triage fans out to exactly four outcomes (confirm / need-info / not-a-bug
    // / cannot-reproduce) — the diagram's triage diamonds.
    const triage_outs = try getAvailableTransitions(std.testing.allocator, def, "triage");
    defer std.testing.allocator.free(triage_outs);
    try std.testing.expectEqual(@as(usize, 4), triage_outs.len);
}
