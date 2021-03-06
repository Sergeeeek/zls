const std = @import("std");
const build_options = @import("build_options");

const Config = @import("config.zig");
const DocumentStore = @import("document_store.zig");
const DebugAllocator = @import("debug_allocator.zig");
const readRequestHeader = @import("header.zig").readRequestHeader;
const data = @import("data/" ++ build_options.data_version ++ ".zig");
const types = @import("types.zig");
const analysis = @import("analysis.zig");

// Code is largely based off of https://github.com/andersfr/zig-lsp/blob/master/server.zig

var stdout: std.io.BufferedOutStream(4096, std.fs.File.OutStream) = undefined;
var allocator: *std.mem.Allocator = undefined;

var document_store: DocumentStore = undefined;

const initialize_response =
    \\,"result":{"capabilities":{"signatureHelpProvider":{"triggerCharacters":["(",","]},"textDocumentSync":1,"completionProvider":{"resolveProvider":false,"triggerCharacters":[".",":","@"]},"documentHighlightProvider":false,"codeActionProvider":false,"declarationProvider":true,"definitionProvider":true,"typeDefinitionProvider":true,"workspace":{"workspaceFolders":{"supported":true}}}}}
;

const not_implemented_response =
    \\,"error":{"code":-32601,"message":"NotImplemented"}}
;

const null_result_response =
    \\,"result":null}
;
const empty_result_response =
    \\,"result":{}}
;
const empty_array_response =
    \\,"result":[]}
;
const edit_not_applied_response =
    \\,"result":{"applied":false,"failureReason":"feature not implemented"}}
;
const no_completions_response =
    \\,"result":{"isIncomplete":false,"items":[]}}
;

/// Sends a request or response
fn send(reqOrRes: var) !void {
    // The most memory we'll probably need
    var mem_buffer: [1024 * 128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&mem_buffer);
    try std.json.stringify(reqOrRes, std.json.StringifyOptions{}, fbs.outStream());

    const stdout_stream = stdout.outStream();
    try stdout_stream.print("Content-Length: {}\r\n\r\n", .{fbs.pos});
    try stdout_stream.writeAll(fbs.getWritten());
    try stdout.flush();
}

fn respondGeneric(id: i64, response: []const u8) !void {
    const id_digits = blk: {
        if (id == 0) break :blk 1;
        var digits: usize = 1;
        var value = @divTrunc(id, 10);
        while (value != 0) : (value = @divTrunc(value, 10)) {
            digits += 1;
        }
        break :blk digits;
    };

    // Numbers of character that will be printed from this string: len - 3 brackets
    // 1 from the beginning (escaped) and the 2 from the arg {}
    const json_fmt = "{{\"jsonrpc\":\"2.0\",\"id\":{}";

    const stdout_stream = stdout.outStream();
    try stdout_stream.print("Content-Length: {}\r\n\r\n" ++ json_fmt, .{ response.len + id_digits + json_fmt.len - 3, id });
    try stdout_stream.writeAll(response);
    try stdout.flush();
}

// TODO: Is this correct or can we get a better end?
fn astLocationToRange(loc: std.zig.ast.Tree.Location) types.Range {
    return .{
        .start = .{
            .line = @intCast(i64, loc.line),
            .character = @intCast(i64, loc.column),
        },
        .end = .{
            .line = @intCast(i64, loc.line),
            .character = @intCast(i64, loc.column),
        },
    };
}

fn publishDiagnostics(handle: DocumentStore.Handle, config: Config) !void {
    const tree = try handle.tree(allocator);
    defer tree.deinit();

    // Use an arena for our local memory allocations.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var diagnostics = std.ArrayList(types.Diagnostic).init(&arena.allocator);

    var error_it = tree.errors.iterator(0);
    while (error_it.next()) |err| {
        const loc = tree.tokenLocation(0, err.loc());

        var mem_buffer: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&mem_buffer);
        try tree.renderError(err, fbs.outStream());

        try diagnostics.append(.{
            .range = astLocationToRange(loc),
            .severity = .Error,
            .code = @tagName(err.*),
            .source = "zls",
            .message = try std.mem.dupe(&arena.allocator, u8, fbs.getWritten()),
            // .relatedInformation = undefined
        });
    }

    if (tree.errors.len == 0) {
        var decls = tree.root_node.decls.iterator(0);
        while (decls.next()) |decl_ptr| {
            var decl = decl_ptr.*;
            switch (decl.id) {
                .FnProto => blk: {
                    const func = decl.cast(std.zig.ast.Node.FnProto).?;
                    const is_extern = func.extern_export_inline_token != null;
                    if (is_extern)
                        break :blk;

                    if (config.warn_style) {
                        if (func.name_token) |name_token| {
                            const loc = tree.tokenLocation(0, name_token);

                            const is_type_function = analysis.isTypeFunction(tree, func);

                            const func_name = tree.tokenSlice(name_token);
                            if (!is_type_function and !analysis.isCamelCase(func_name)) {
                                try diagnostics.append(.{
                                    .range = astLocationToRange(loc),
                                    .severity = .Information,
                                    .code = "BadStyle",
                                    .source = "zls",
                                    .message = "Functions should be camelCase",
                                });
                            } else if (is_type_function and !analysis.isPascalCase(func_name)) {
                                try diagnostics.append(.{
                                    .range = astLocationToRange(loc),
                                    .severity = .Information,
                                    .code = "BadStyle",
                                    .source = "zls",
                                    .message = "Type functions should be PascalCase",
                                });
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    try send(types.Notification{
        .method = "textDocument/publishDiagnostics",
        .params = .{
            .PublishDiagnosticsParams = .{
                .uri = handle.uri(),
                .diagnostics = diagnostics.items,
            },
        },
    });
}

fn containerToCompletion(list: *std.ArrayList(types.CompletionItem), analysis_ctx: *DocumentStore.AnalysisContext, container: *std.zig.ast.Node, config: Config) !void {
    var index: usize = 0;
    while (container.iterate(index)) |child_node| : (index += 1) {
        if (analysis.isNodePublic(analysis_ctx.tree, child_node)) {
            try nodeToCompletion(list, analysis_ctx, child_node, config);
        }
    }
}

fn nodeToCompletion(list: *std.ArrayList(types.CompletionItem), analysis_ctx: *DocumentStore.AnalysisContext, node: *std.zig.ast.Node, config: Config) error{OutOfMemory}!void {
    var doc = if (try analysis.getDocComments(list.allocator, analysis_ctx.tree, node)) |doc_comments|
        types.MarkupContent{
            .kind = .Markdown,
            .value = doc_comments,
        }
    else
        null;

    switch (node.id) {
        .ErrorSetDecl, .Root, .ContainerDecl => {
            try containerToCompletion(list, analysis_ctx, node, config);
        },
        .FnProto => {
            const func = node.cast(std.zig.ast.Node.FnProto).?;
            if (func.name_token) |name_token| {
                const insert_text = if (config.enable_snippets)
                    try analysis.getFunctionSnippet(list.allocator, analysis_ctx.tree, func)
                else
                    null;

                const is_type_function = analysis.isTypeFunction(analysis_ctx.tree, func);

                try list.append(.{
                    .label = analysis_ctx.tree.tokenSlice(name_token),
                    .kind = if (is_type_function) .Struct else .Function,
                    .documentation = doc,
                    .detail = analysis.getFunctionSignature(analysis_ctx.tree, func),
                    .insertText = insert_text,
                    .insertTextFormat = if (config.enable_snippets) .Snippet else .PlainText,
                });
            }
        },
        .VarDecl => {
            const var_decl = node.cast(std.zig.ast.Node.VarDecl).?;
            const is_const = analysis_ctx.tree.tokens.at(var_decl.mut_token).id == .Keyword_const;

            var child_analysis_context = try analysis_ctx.clone();
            defer child_analysis_context.deinit();

            const child_node = var_decl.type_node orelse var_decl.init_node.?;
            const maybe_resolved_node = analysis.resolveTypeOfNode(&child_analysis_context, child_node);

            if (maybe_resolved_node) |resolved_node| {
                // Special case for function aliases
                // In the future it might be used to print types of values instead of their declarations
                if (resolved_node.id == .FnProto) {
                    try nodeToCompletion(list, &child_analysis_context, resolved_node, config);
                    return;
                }
            }
            try list.append(.{
                .label = analysis_ctx.tree.tokenSlice(var_decl.name_token),
                .kind = if (is_const) .Constant else .Variable,
                .documentation = doc,
                .detail = analysis.getVariableSignature(analysis_ctx.tree, var_decl),
            });
        },
        .ParamDecl => {
            const param = node.cast(std.zig.ast.Node.ParamDecl).?;
            if (param.name_token) |name_token|
                try list.append(.{
                    .label = analysis_ctx.tree.tokenSlice(name_token),
                    .kind = .Constant,
                    .documentation = doc,
                    .detail = analysis.getParamSignature(analysis_ctx.tree, param),
                });
        },
        .PrefixOp => {
            try list.append(.{
                .label = "len",
                .kind = .Field,
            });
            try list.append(.{
                .label = "ptr",
                .kind = .Field,
            });
        },
        .StringLiteral => {
            try list.append(.{
                .label = "len",
                .kind = .Field,
            });
        },
        else => if (analysis.nodeToString(analysis_ctx.tree, node)) |string| {
            try list.append(.{
                .label = string,
                .kind = .Field,
                .documentation = doc,
            });
        },
    }
}

fn identifierFromPosition(pos_index: usize, handle: DocumentStore.Handle) []const u8 {
    var start_idx = pos_index;
    while (start_idx > 0 and
        (std.ascii.isAlNum(handle.document.text[start_idx]) or handle.document.text[start_idx] == '_')) : (start_idx -= 1)
    {}

    var end_idx = pos_index;
    while (end_idx < handle.document.text.len and
        (std.ascii.isAlNum(handle.document.text[end_idx]) or handle.document.text[end_idx] == '_')) : (end_idx += 1)
    {}

    return handle.document.text[start_idx + 1 .. end_idx];
}

fn gotoDefinitionGlobal(id: i64, pos_index: usize, handle: DocumentStore.Handle) !void {
    var tree = try handle.tree(allocator);
    defer tree.deinit();

    const name = identifierFromPosition(pos_index, handle);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var decl_nodes = std.ArrayList(*std.zig.ast.Node).init(&arena.allocator);
    try analysis.declsFromIndex(&decl_nodes, tree, pos_index);

    const decl = analysis.getChildOfSlice(tree, decl_nodes.items, name) orelse return try respondGeneric(id, null_result_response);
    const name_token = analysis.getDeclNameToken(tree, decl) orelse unreachable;

    try send(types.Response{
        .id = .{ .Integer = id },
        .result = .{
            .Location = .{
                .uri = handle.document.uri,
                .range = astLocationToRange(tree.tokenLocation(0, name_token)),
            },
        },
    });
}

fn gotoDefinitionFieldAccess(id: i64, handle: *DocumentStore.Handle, position: types.Position, line_start_idx: usize) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var analysis_ctx = try document_store.analysisContext(handle, &arena, position);
    defer analysis_ctx.deinit();

    const pos_index = try handle.document.positionToIndex(position);
    var name = identifierFromPosition(pos_index, handle.*);

    const line = try handle.document.getLine(@intCast(usize, position.line));
    var tokenizer = std.zig.Tokenizer.init(line[line_start_idx..]);

    const line_length = @ptrToInt(name.ptr) - @ptrToInt(line.ptr) + name.len - line_start_idx;
    name = try std.mem.dupe(&arena.allocator, u8, name);

    if (analysis.getFieldAccessTypeNode(&analysis_ctx, &tokenizer, line_length)) |container| {
        const decl = analysis.getChild(analysis_ctx.tree, container, name) orelse return try respondGeneric(id, null_result_response);
        const name_token = analysis.getDeclNameToken(analysis_ctx.tree, decl) orelse unreachable;
        return try send(types.Response{
            .id = .{ .Integer = id },
            .result = .{
                .Location = .{
                    .uri = analysis_ctx.handle.document.uri,
                    .range = astLocationToRange(analysis_ctx.tree.tokenLocation(0, name_token)),
                },
            },
        });
    }

    try respondGeneric(id, null_result_response);
}

fn completeGlobal(id: i64, pos_index: usize, handle: *DocumentStore.Handle, config: Config) !void {
    var tree = try handle.tree(allocator);
    defer tree.deinit();

    // We use a local arena allocator to deallocate all temporary data without iterating
    var arena = std.heap.ArenaAllocator.init(allocator);
    var completions = std.ArrayList(types.CompletionItem).init(&arena.allocator);
    // Deallocate all temporary data.
    defer arena.deinit();

    var analysis_ctx = try document_store.analysisContext(handle, &arena, types.Position{
        .line = 0,
        .character = 0,
    });
    defer analysis_ctx.deinit();

    var decl_nodes = std.ArrayList(*std.zig.ast.Node).init(&arena.allocator);
    try analysis.declsFromIndex(&decl_nodes, tree, pos_index);
    for (decl_nodes.items) |decl_ptr| {
        var decl = decl_ptr.*;
        try nodeToCompletion(&completions, &analysis_ctx, decl_ptr, config);
    }

    try send(types.Response{
        .id = .{ .Integer = id },
        .result = .{
            .CompletionList = .{
                .isIncomplete = false,
                .items = completions.items,
            },
        },
    });
}

fn completeFieldAccess(id: i64, handle: *DocumentStore.Handle, position: types.Position, line_start_idx: usize, config: Config) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var analysis_ctx = try document_store.analysisContext(handle, &arena, position);
    defer analysis_ctx.deinit();

    var completions = std.ArrayList(types.CompletionItem).init(&arena.allocator);

    const line = try handle.document.getLine(@intCast(usize, position.line));
    var tokenizer = std.zig.Tokenizer.init(line[line_start_idx..]);
    const line_length = line.len - line_start_idx;

    if (analysis.getFieldAccessTypeNode(&analysis_ctx, &tokenizer, line_length)) |node| {
        try nodeToCompletion(&completions, &analysis_ctx, node, config);
    }
    try send(types.Response{
        .id = .{ .Integer = id },
        .result = .{
            .CompletionList = .{
                .isIncomplete = false,
                .items = completions.items,
            },
        },
    });
}

// Compute builtin completions at comptime.
const builtin_completions = block: {
    @setEvalBranchQuota(3_500);
    const CompletionList = [data.builtins.len]types.CompletionItem;
    var with_snippets: CompletionList = undefined;
    var without_snippets: CompletionList = undefined;

    for (data.builtins) |builtin, i| {
        const cutoff = std.mem.indexOf(u8, builtin, "(") orelse builtin.len;

        const base_completion = types.CompletionItem{
            .label = builtin[0..cutoff],
            .kind = .Function,

            .filterText = builtin[1..cutoff],
            .detail = data.builtin_details[i],
            .documentation = .{
                .kind = .Markdown,
                .value = data.builtin_docs[i],
            },
        };

        with_snippets[i] = base_completion;
        with_snippets[i].insertText = builtin[1..];
        with_snippets[i].insertTextFormat = .Snippet;

        without_snippets[i] = base_completion;
        without_snippets[i].insertText = builtin[1..cutoff];
    }

    break :block [2]CompletionList{
        without_snippets, with_snippets,
    };
};

const PositionContext = union(enum) {
    builtin,
    comment,
    string_literal,
    field_access: usize,
    var_access,
    other,
    empty,
};

const token_separators = [_]u8{
    ' ', '\t', '(', ')', '[', ']',
    '{', '}',  '|', '=', '!', ';',
    ',', '?',  ':', '%', '+', '*',
    '>', '<',  '~', '-', '/', '&',
};

fn documentPositionContext(doc: types.TextDocument, pos_index: usize) PositionContext {
    // First extract the whole current line up to the cursor.
    var curr_position = pos_index;
    while (curr_position > 0) : (curr_position -= 1) {
        if (doc.text[curr_position - 1] == '\n') break;
    }

    var line = doc.text[curr_position .. pos_index + 1];
    // Strip any leading whitespace.
    var skipped_ws: usize = 0;
    while (skipped_ws < line.len and (line[skipped_ws] == ' ' or line[skipped_ws] == '\t')) : (skipped_ws += 1) {}
    if (skipped_ws >= line.len) return .empty;
    line = line[skipped_ws..];

    // Quick exit for comment lines and multi line string literals.
    if (line.len >= 2 and line[0] == '/' and line[1] == '/')
        return .comment;
    if (line.len >= 2 and line[0] == '\\' and line[1] == '\\')
        return .string_literal;

    // TODO: This does not detect if we are in a string literal over multiple lines.
    // Find out what context we are in.
    // Go over the current line character by character
    // and determine the context.
    curr_position = 0;
    var expr_start: usize = skipped_ws;

    var new_token = true;
    var context: PositionContext = .other;
    var string_pop_ctx: PositionContext = .other;
    while (curr_position < line.len) : (curr_position += 1) {
        const c = line[curr_position];
        const next_char = if (curr_position < line.len - 1) line[curr_position + 1] else null;

        if (context != .string_literal and c == '"') {
            expr_start = curr_position + skipped_ws;
            context = .string_literal;
            continue;
        }

        if (context == .string_literal) {
            // Skip over escaped quotes
            if (c == '\\' and next_char != null and next_char.? == '"') {
                curr_position += 1;
            } else if (c == '"') {
                context = string_pop_ctx;
                string_pop_ctx = .other;
                new_token = true;
            }

            continue;
        }

        if (c == '/' and next_char != null and next_char.? == '/') {
            context = .comment;
            break;
        }

        if (std.mem.indexOfScalar(u8, &token_separators, c) != null) {
            expr_start = curr_position + skipped_ws + 1;
            new_token = true;
            context = .other;
            continue;
        }

        if (c == '.' and (!new_token or context == .string_literal)) {
            new_token = true;
            if (next_char != null and next_char.? == '.') continue;
            context = .{ .field_access = expr_start };
            continue;
        }

        if (new_token) {
            const access_ctx: PositionContext = if (context == .field_access)
                .{ .field_access = expr_start }
            else
                .var_access;

            new_token = false;

            if (c == '_' or std.ascii.isAlpha(c)) {
                context = access_ctx;
            } else if (c == '@') {
                // This checks for @"..." identifiers by controlling
                // the context the string will set after it is over.
                if (next_char != null and next_char.? == '"') {
                    string_pop_ctx = access_ctx;
                }
                context = .builtin;
            } else {
                context = .other;
            }
            continue;
        }

        if (context == .field_access or context == .var_access or context == .builtin) {
            if (c != '_' and !std.ascii.isAlNum(c)) {
                context = .other;
            }
            continue;
        }

        context = .other;
    }

    return context;
}

fn processJsonRpc(parser: *std.json.Parser, json: []const u8, config: Config) !void {
    var tree = try parser.parse(json);
    defer tree.deinit();

    const root = tree.root;

    std.debug.assert(root.Object.getValue("method") != null);

    const method = root.Object.getValue("method").?.String;
    const id = if (root.Object.getValue("id")) |id| id.Integer else 0;

    const params = root.Object.getValue("params").?.Object;

    // Core
    if (std.mem.eql(u8, method, "initialize")) {
        try respondGeneric(id, initialize_response);
    } else if (std.mem.eql(u8, method, "initialized")) {
        // noop
    } else if (std.mem.eql(u8, method, "$/cancelRequest")) {
        // noop
    }
    // File changes
    else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        const document = params.getValue("textDocument").?.Object;
        const uri = document.getValue("uri").?.String;
        const text = document.getValue("text").?.String;

        const handle = try document_store.openDocument(uri, text);
        try publishDiagnostics(handle.*, config);
    } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
        const text_document = params.getValue("textDocument").?.Object;
        const uri = text_document.getValue("uri").?.String;
        const content_changes = params.getValue("contentChanges").?.Array;

        const handle = document_store.getHandle(uri) orelse {
            std.debug.warn("Trying to change non existent document {}", .{uri});
            return;
        };

        try document_store.applyChanges(handle, content_changes);
        try publishDiagnostics(handle.*, config);
    } else if (std.mem.eql(u8, method, "textDocument/didSave")) {
        // noop
    } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
        const document = params.getValue("textDocument").?.Object;
        const uri = document.getValue("uri").?.String;

        document_store.closeDocument(uri);
    }
    // Autocomplete / Signatures
    else if (std.mem.eql(u8, method, "textDocument/completion")) {
        const text_document = params.getValue("textDocument").?.Object;
        const uri = text_document.getValue("uri").?.String;
        const position = params.getValue("position").?.Object;

        const handle = document_store.getHandle(uri) orelse {
            std.debug.warn("Trying to complete in non existent document {}", .{uri});
            return try respondGeneric(id, no_completions_response);
        };

        const pos = types.Position{
            .line = position.getValue("line").?.Integer,
            .character = position.getValue("character").?.Integer - 1,
        };
        if (pos.character >= 0) {
            const pos_index = try handle.document.positionToIndex(pos);
            const pos_context = documentPositionContext(handle.document, pos_index);

            switch (pos_context) {
                .builtin => try send(types.Response{
                    .id = .{ .Integer = id },
                    .result = .{
                        .CompletionList = .{
                            .isIncomplete = false,
                            .items = builtin_completions[@boolToInt(config.enable_snippets)][0..],
                        },
                    },
                }),
                .var_access, .empty => try completeGlobal(id, pos_index, handle, config),
                .field_access => |start_idx| try completeFieldAccess(id, handle, pos, start_idx, config),
                else => try respondGeneric(id, no_completions_response),
            }
        } else {
            try respondGeneric(id, no_completions_response);
        }
    } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
        try respondGeneric(id,
            \\,"result":{"signatures":[]}}
        );
    } else if (std.mem.eql(u8, method, "textDocument/definition") or
        std.mem.eql(u8, method, "textDocument/declaration") or
        std.mem.eql(u8, method, "textDocument/typeDefinition"))
    {
        const document = params.getValue("textDocument").?.Object;
        const uri = document.getValue("uri").?.String;
        const position = params.getValue("position").?.Object;

        const handle = document_store.getHandle(uri) orelse {
            std.debug.warn("Trying to got to definition in non existent document {}", .{uri});
            return try respondGeneric(id, null_result_response);
        };

        const pos = types.Position{
            .line = position.getValue("line").?.Integer,
            .character = position.getValue("character").?.Integer - 1,
        };
        if (pos.character >= 0) {
            const pos_index = try handle.document.positionToIndex(pos);
            const pos_context = documentPositionContext(handle.document, pos_index);

            switch (pos_context) {
                .var_access => try gotoDefinitionGlobal(id, pos_index, handle.*),
                .field_access => |start_idx| try gotoDefinitionFieldAccess(id, handle, pos, start_idx),
                else => try respondGeneric(id, null_result_response),
            }
        }
    } else if (root.Object.getValue("id")) |_| {
        std.debug.warn("Method with return value not implemented: {}", .{method});
        try respondGeneric(id, not_implemented_response);
    } else {
        std.debug.warn("Method without return value not implemented: {}", .{method});
    }
}

var debug_alloc_state: DebugAllocator = undefined;
// We can now use if(leak_count_alloc) |alloc| { ... } as a comptime check.
const debug_alloc: ?*DebugAllocator = if (build_options.allocation_info) &debug_alloc_state else null;

pub fn main() anyerror!void {
    // TODO: Use a better purpose general allocator once std has one.
    // Probably after the generic composable allocators PR?
    // This is not too bad for now since most allocations happen in local arenas.
    allocator = std.heap.page_allocator;

    if (build_options.allocation_info) {
        // TODO: Use a better debugging allocator, track size in bytes, memory reserved etc..
        // Initialize the leak counting allocator.
        debug_alloc_state = DebugAllocator.init(allocator);
        allocator = &debug_alloc_state.allocator;
    }

    // Init global vars
    const in_stream = std.io.getStdIn().inStream();
    stdout = std.io.bufferedOutStream(std.io.getStdOut().outStream());

    // Read the configuration, if any.
    const config_parse_options = std.json.ParseOptions{ .allocator = allocator };
    var config = Config{};
    defer std.json.parseFree(Config, config, config_parse_options);

    // TODO: Investigate using std.fs.Watch to detect writes to the config and reload it.
    config_read: {
        var exec_dir_bytes: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const exec_dir_path = std.fs.selfExeDirPath(&exec_dir_bytes) catch break :config_read;

        var exec_dir = std.fs.cwd().openDir(exec_dir_path, .{}) catch break :config_read;
        defer exec_dir.close();

        const conf_file = exec_dir.openFile("zls.json", .{}) catch break :config_read;
        defer conf_file.close();

        // Max 1MB
        const file_buf = conf_file.inStream().readAllAlloc(allocator, 0x1000000) catch break :config_read;
        defer allocator.free(file_buf);

        // TODO: Better errors? Doesn't seem like std.json can provide us positions or context.
        config = std.json.parse(Config, &std.json.TokenStream.init(file_buf), config_parse_options) catch |err| {
            std.debug.warn("Error while parsing configuration file: {}\nUsing default config.\n", .{err});
            break :config_read;
        };
    }

    if (config.zig_lib_path) |zig_lib_path| {
        if (!std.fs.path.isAbsolute(zig_lib_path)) {
            std.debug.warn("zig library path is not absolute, defaulting to null.\n", .{});
            allocator.free(zig_lib_path);
            config.zig_lib_path = null;
        }
    }

    try document_store.init(allocator, config.zig_lib_path);
    defer document_store.deinit();

    // This JSON parser is passed to processJsonRpc and reset.
    var json_parser = std.json.Parser.init(allocator, false);
    defer json_parser.deinit();

    while (true) {
        const headers = readRequestHeader(allocator, in_stream) catch |err| {
            std.debug.warn("{}; exiting!", .{@errorName(err)});
            return;
        };
        defer headers.deinit(allocator);
        const buf = try allocator.alloc(u8, headers.content_length);
        defer allocator.free(buf);
        try in_stream.readNoEof(buf);
        try processJsonRpc(&json_parser, buf, config);
        json_parser.reset();

        if (debug_alloc) |dbg| {
            std.debug.warn("{}\n", .{dbg.info});
        }
    }
}
