module duktape::vm;

import duktape::bytecode;
import std::io;
import std::core::dstring;
import std::time;

/// CPU profiler — periodic-check sampler (Approach A, simplified variant).
///
/// The VM's bytecode dispatch loop is single-threaded and unlocked, so a
/// genuinely concurrent sampling thread reading `vm.activations` while CALL/
/// RET mutate it in place would be a data race. Instead, the dispatch loop
/// itself checks a monotonic clock every `CHECK_INSTRUCTIONS` instructions
/// (cheap: one counter increment + compare, no syscall on most iterations)
/// and records a sample whenever at least `SAMPLE_INTERVAL_US` microseconds
/// have elapsed since the last one. This keeps the sampled call stack always
/// internally consistent and adds negligible overhead when disabled (a
/// single `if (@unlikely(vm.cpuprofile.enabled))` branch).
///
/// Each sample walks `Activation.parent` from the currently executing
/// activation up to the root, producing a leaf-to-root list of
/// `CompiledFunction*` pointers. After execution, `CpuProfiler.finish()`
/// merges these into a call tree (deduping by parent+function identity,
/// exactly like V8's cpuprofile "nodes" array) and serializes Chrome
/// DevTools / speedscope compatible JSON.

/// How often (in dispatch-loop instructions) to check the clock.
const uint CHECK_INSTRUCTIONS = 256;
/// Target sampling period, in microseconds (~1000 Hz).
const ulong SAMPLE_INTERVAL_US = 1000;

/// A deduped call-tree node, keyed by (parent node index, CompiledFunction*).
struct CpuNode {
    CompiledFunction* func;  // null only for the synthetic "(vm)" catch-all root child
    int parent;              // index into CpuProfiler.nodes, or -1 for the synthetic root
    uint hit_count;
    int* children;           // growable (malloc'd) list of child node indices
    usz children_len;
    usz children_cap;
}

struct CpuProfiler {
    bool enabled;
    char* out_path;

    // Sampling state (checked/updated from the dispatch loop).
    uint insn_counter;
    Clock last_sample_clock;
    Clock start_clock;
    Time start_time;

    // Per-sample data: microsecond delta since the previous sample, and the
    // interned call-tree node id representing the sampled leaf frame.
    ulong* sample_deltas_us;
    int* sample_node_ids;
    usz samples_len;
    usz samples_cap;

    // Call-tree nodes, built up during collect (root = index 0, a synthetic
    // "(root)" node matching V8's cpuprofile convention).
    CpuNode* nodes;
    usz nodes_len;
    usz nodes_cap;
}

/// Global profiler instance. A global (rather than a Vm field) keeps the
/// hot dispatch loop's check to a single predicted-not-taken load+branch,
/// and lets the CLI initialize/finalize it around `v.execute()` without
/// threading extra parameters through Vm creation.
CpuProfiler g_cpuprofile;

fn void CpuProfiler.init(&self, char* out_path) {
    self.enabled = true;
    self.out_path = out_path;
    self.insn_counter = 0;
    self.start_clock = clock::now();
    self.last_sample_clock = self.start_clock;
    self.start_time = time::now();

    self.sample_deltas_us = null;
    self.sample_node_ids = null;
    self.samples_len = 0;
    self.samples_cap = 0;

    self.nodes = null;
    self.nodes_len = 0;
    self.nodes_cap = 0;

    // Node 0: synthetic "(root)" node (V8 convention — always id 1 in the
    // final output; every top-level sample chain roots here).
    self.push_node(null, -1);
}

fn int CpuProfiler.push_node(&self, CompiledFunction* func, int parent) {
    if (self.nodes_len == self.nodes_cap) {
        usz new_cap = self.nodes_cap == 0 ? 64 : self.nodes_cap * 2;
        self.nodes = (CpuNode*)mem::realloc(self.nodes, (sz)(new_cap * CpuNode::size));
        self.nodes_cap = new_cap;
    }
    CpuNode* n = &self.nodes[self.nodes_len];
    n.func = func;
    n.parent = parent;
    n.hit_count = 0;
    n.children = null;
    n.children_len = 0;
    n.children_cap = 0;
    int id = (int)self.nodes_len;
    self.nodes_len++;
    return id;
}

fn void CpuNode.add_child(&self, int child_id) {
    if (self.children_len == self.children_cap) {
        usz new_cap = self.children_cap == 0 ? 4 : self.children_cap * 2;
        self.children = (int*)mem::realloc(self.children, (sz)(new_cap * int::size));
        self.children_cap = new_cap;
    }
    self.children[self.children_len] = child_id;
    self.children_len++;
}

/// Find (or create) the child of `parent_id` whose call frame is `func`.
fn int CpuProfiler.intern_frame(&self, int parent_id, CompiledFunction* func) {
    CpuNode* parent = &self.nodes[parent_id];
    for (usz i = 0; i < parent.children_len; i++) {
        int cid = parent.children[i];
        if (self.nodes[cid].func == func) return cid;
    }
    int new_id = self.push_node(func, parent_id);
    // Re-fetch: push_node may have realloc'd self.nodes, invalidating `parent`.
    self.nodes[parent_id].add_child(new_id);
    return new_id;
}

/// Called from the dispatch loop once every CHECK_INSTRUCTIONS instructions.
/// Walks the activation chain from `leaf` to the root, interning each frame
/// into the call tree, and records a sample (bumping the leaf node's hit
/// count) if enough wall time has elapsed since the last one.
fn void CpuProfiler.maybe_sample(&self, Activation* leaf) {
    Clock now = clock::now();
    NanoDuration elapsed = now.nano_diff(self.last_sample_clock);
    ulong elapsed_us = (ulong)(elapsed / 1000);
    if (elapsed_us < SAMPLE_INTERVAL_US) return;
    self.last_sample_clock = now;

    int node_id = 0; // synthetic root
    if (leaf == null) {
        node_id = self.intern_frame(0, null); // "(vm)" catch-all
    } else {
        // Collect leaf->root chain on the stack (call depth is bounded by
        // MAX_CALLS), then intern root->leaf so parent nodes exist first.
        CompiledFunction*[512] chain;
        uint depth = 0;
        Activation* a = leaf;
        while (a != null && depth < 512) {
            chain[depth] = (CompiledFunction*)a.func;
            depth++;
            a = a.parent;
        }
        node_id = 0;
        uint i = depth;
        while (i > 0) {
            i--;
            node_id = self.intern_frame(node_id, chain[i]);
        }
    }

    self.nodes[node_id].hit_count++;

    if (self.samples_len == self.samples_cap) {
        usz new_cap = self.samples_cap == 0 ? 1024 : self.samples_cap * 2;
        self.sample_deltas_us = (ulong*)mem::realloc(self.sample_deltas_us, (sz)(new_cap * ulong::size));
        self.sample_node_ids = (int*)mem::realloc(self.sample_node_ids, (sz)(new_cap * int::size));
        self.samples_cap = new_cap;
    }
    self.sample_deltas_us[self.samples_len] = self.samples_len == 0
        ? (ulong)(now.nano_diff(self.start_clock) / 1000)
        : elapsed_us;
    self.sample_node_ids[self.samples_len] = node_id;
    self.samples_len++;
}

fn void CpuProfiler.write_frame_name(&self, DString* out, CompiledFunction* func) {
    if (func == null) {
        out.append_string("(vm)");
        return;
    }
    char[] name = func.get_name();
    if (name.len == 0) {
        out.append_string("(anonymous)");
    } else {
        json_escape_append(out, name);
    }
}

fn void json_escape_append(DString* out, char[] s) {
    foreach (char c : s) {
        switch (c) {
            case '"':  out.append_string("\\\""); break;
            case '\\': out.append_string("\\\\"); break;
            case '\n': out.append_string("\\n"); break;
            case '\r': out.append_string("\\r"); break;
            case '\t': out.append_string("\\t"); break;
            default:
                if (c < 0x20) {
                    out.appendf("\\u%04x", (int)c);
                } else {
                    out.append_char(c);
                }
        }
    }
}

/// Serialize the collected profile to `.cpuprofile` JSON and write it to
/// `self.out_path`. Called once, after `v.execute()` returns.
fn void CpuProfiler.finish(&self, char* script_path) {
    if (!self.enabled) return;

    Clock end_clock = clock::now();
    ulong start_us = 0;
    ulong end_us = (ulong)(end_clock.nano_diff(self.start_clock) / 1000);

    DString out;
    out.tinit(64 * 1024);

    out.append_string("{\"nodes\":[");
    for (usz i = 0; i < self.nodes_len; i++) {
        if (i > 0) out.append_char(',');
        CpuNode* n = &self.nodes[i];
        out.appendf("{\"id\":%d,\"callFrame\":{\"functionName\":\"", (int)i + 1);
        if (i == 0) {
            out.append_string("(root)");
        } else {
            self.write_frame_name(&out, n.func);
        }
        out.append_string("\",\"scriptId\":\"1\",\"url\":\"");
        if (i != 0 && n.func != null) {
            char[] fname = n.func.get_filename();
            if (fname.len > 0) {
                json_escape_append(&out, fname);
            } else if (script_path != null) {
                out.append_string(((ZString)script_path).str_view());
            }
        }
        // No per-function line info is currently recorded by the compiler
        // (CompiledFunction.line_table is always null), so every frame
        // reports line 0 — DevTools/speedscope still render fine without it.
        out.appendf("\",\"lineNumber\":0,\"columnNumber\":0},\"hitCount\":%d,\"children\":[", n.hit_count);
        for (usz j = 0; j < n.children_len; j++) {
            if (j > 0) out.append_char(',');
            out.appendf("%d", n.children[j] + 1);
        }
        out.append_string("]}");
    }
    out.append_string("],");

    out.appendf("\"startTime\":%d,\"endTime\":%d,", start_us, end_us);

    out.append_string("\"samples\":[");
    for (usz i = 0; i < self.samples_len; i++) {
        if (i > 0) out.append_char(',');
        out.appendf("%d", self.sample_node_ids[i] + 1);
    }
    out.append_string("],\"timeDeltas\":[");
    for (usz i = 0; i < self.samples_len; i++) {
        if (i > 0) out.append_char(',');
        out.appendf("%d", self.sample_deltas_us[i]);
    }
    out.append_string("]}");

    String path_str = ((ZString)self.out_path).str_view();
    File? f = file::open(path_str, "w");
    if (catch err = f) {
        io::eprintfn("cpuprofile: failed to open %s for writing", path_str);
        return;
    }
    defer (void)f.close();
    String data = out.str_view();
    (void)f.write((char[])data);
    io::eprintfn("cpuprofile: wrote %s (%d samples, %d nodes)", path_str, (int)self.samples_len, (int)self.nodes_len);
}
