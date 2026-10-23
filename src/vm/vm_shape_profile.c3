// Bounded, sampled property-site diagnostics. No shipping-build work.
module boomkat::vm;

import boomkat::bytecode;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::heap;
import boomkat::types;
import boomkat::pagepool;
import std::io;

struct ShapeProfileSite {
    void* function;
    uint pc;
    uint line;
    uint column;
    uint[4] shapes;
    uint shape_count;
    bool overflow_shapes;
    char[64] name;
    uint name_len;
    char[160] filename;
    uint filename_len;
    char[64] key;
    uint key_len;
    uint[8] sequence;
    uint sequence_count;
    ulong[11] counts;
    ulong[4] key_fingerprints;
    uint[4] key_kinds;
    uint key_count;
    bool overflow_keys;
    ulong key_changes;
    ulong previous_key;
    uint previous_key_kind;
    ulong computed_samples;
    ulong receiver_classes;
    ulong[4] input_kinds;
    ulong samples;
    ulong replaced;
}
tlocal ShapeProfileSite[512] shape_profile_sites @feat(OP_PROFILE);
tlocal ulong[11] shape_profile_totals @feat(OP_PROFILE);
tlocal ulong shape_profile_sample_state @feat(OP_PROFILE) = 1;
tlocal ulong shape_profile_replacements @feat(OP_PROFILE);

// Event counts are exact globally, not mutually exclusive access outcomes.
// A threaded refusal and its switch retry are separate attempts. Source sites
// are sampled 1/64 with eight bounded probes and approximate hot-site retention.
fn void shape_profile(CompiledFunction* function, Instruction* pc, hobject::HObject* receiver,
                       void* key, uint reason, TVal* computed_key = null) @feat(OP_PROFILE) {
    if (function == null || pc == null || receiver == null) return;
    shape_profile_totals[reason]++;
    shape_profile_sample_state = shape_profile_sample_state * 6364136223846793005UL + 1442695040888963407UL;
    if ((shape_profile_sample_state >> 58) != 0) return;
    uint offset = (uint)(pc - function.code);
    uint bucket = (uint)(((uptr)function >> 4) ^ ((uptr)offset * 2654435761u)) & 511;
    ShapeProfileSite* site = null;
    for (uint probe = 0; probe < 8; probe++) {
        ShapeProfileSite* slot = &shape_profile_sites[(bucket + probe) & 511];
        if (slot.function == (void*)function && slot.pc == offset) { site = slot; break; }
        if (slot.function == null) { site = slot; break; }
        if (site == null || slot.samples < site.samples) site = slot;
    }
    if (site.function != (void*)function || site.pc != offset) {
        ulong replaced = site.samples;
        if (site.function != null) shape_profile_replacements++;
        *site = {};
        site.function = (void*)function;
        site.pc = offset;
        site.replaced = replaced;
        SourcePosition position = function.get_source_position(offset);
        site.line = position.line;
        site.column = position.column;
        char[] name = function.get_name();
        site.name_len = (uint)min(name.len, site.name.len);
        if (site.name_len != 0) mem::copy(&site.name, name.ptr, site.name_len);
        char[] filename = function.get_filename();
        site.filename_len = (uint)min(filename.len, site.filename.len);
        if (site.filename_len != 0) mem::copy(&site.filename, filename.ptr, site.filename_len);
        if (key != null) {
            hstring::HString* text = (hstring::HString*)key;
            site.key_len = min(text.blen, (uint)site.key.len);
            if (site.key_len != 0) mem::copy(&site.key, text.get_data().ptr, site.key_len);
        }
    }
    site.samples++;
    site.counts[reason]++;
    site.receiver_classes |= 1UL << (uint)receiver.get_class().ordinal;
    if (computed_key != null) {
        uint kind = 3;
        ulong fingerprint = (ulong)computed_key.get_tag();
        if (computed_key.is_string()) {
            hstring::HString* text = (hstring::HString*)computed_key.get_heapptr();
            if (text.is_symbol()) {
                kind = 1;
                fingerprint = (ulong)(uptr)text;
            } else {
                kind = 0;
                // Pure hashing does not force the engine's deferred hash state.
                fingerprint = ((ulong)hstring::hash_string(text.get_data()) << 32) | text.blen;
            }
        } else if (computed_key.is_fastint() || computed_key.is_number()) {
            kind = 2;
            double number = computed_key.get_number_or_fastint();
            fingerprint = *(ulong*)&number;
        }
        site.input_kinds[kind]++;
        if (site.computed_samples != 0
            && (site.previous_key != fingerprint || site.previous_key_kind != kind)) site.key_changes++;
        site.computed_samples++;
        site.previous_key = fingerprint;
        site.previous_key_kind = kind;
        bool known_key = false;
        for (uint i = 0; i < site.key_count; i++) {
            if (site.key_fingerprints[i] == fingerprint && site.key_kinds[i] == kind) known_key = true;
        }
        if (!known_key) {
            if (site.key_count < 4) {
                site.key_fingerprints[site.key_count] = fingerprint;
                site.key_kinds[site.key_count++] = kind;
            } else {
                site.overflow_keys = true;
            }
        }
    }
    if (site.sequence_count < 8
        && (site.sequence_count == 0 || site.sequence[site.sequence_count - 1] != receiver.shape_id)) {
        site.sequence[site.sequence_count++] = receiver.shape_id;
    }
    bool seen = false;
    for (uint i = 0; i < site.shape_count; i++) if (site.shapes[i] == receiver.shape_id) seen = true;
    if (!seen) {
        if (site.shape_count < 4) {
            site.shapes[site.shape_count++] = receiver.shape_id;
        } else {
            site.overflow_shapes = true;
        }
    }
}

fn void shape_profile_hex(char[] text) @feat(OP_PROFILE) {
    foreach (byte : text) io::eprintf("%02x", (uint)byte);
}

// Successful cache-array allocations and explicit clear traffic.
tlocal ulong[4] shape_profile_cache_alloc @feat(OP_PROFILE);

// Called with the heap census before teardown changes current/free counts.
fn void shape_profile_allocation_dump() @feat(OP_PROFILE) {
    io::eprintfn("# CACHE_ALLOC successful=%d property_requested=%d variable_requested=%d explicit_clear_bytes=%d current_requested_bytes=%d highwater_requested_bytes=%d", shape_profile_cache_alloc[0], shape_profile_cache_alloc[1], shape_profile_cache_alloc[2], shape_profile_cache_alloc[3], hobject::opprof_cache_bytes[0], hobject::opprof_cache_bytes[1]);
    io::eprintfn("# OBJECT_ALLOC classes=%s initial_capacities=%s header_requested_bytes=%d fallback_header_clear_bytes=%d freed_classes=%s", hobject::opprof_alloc_classes, hobject::opprof_alloc_capacities, hobject::opprof_storage[0], hobject::opprof_storage[1], hobject::opprof_freed_classes);
    io::eprintfn("# STORAGE_REQUESTS shape_properties=%s reserve_capacities=%s grown_capacities=%s", hobject::opprof_shape_properties, hobject::opprof_reserve_capacities, hobject::opprof_grown_capacities);
    io::eprintfn("# EXTERNAL_STORAGE prop_grows=%d prop_requested=%d prop_copied=%d array_grows=%d array_requested=%d array_copied=%d reserve_requested=%d explicit_clear=%d selected_undefined_slot_bytes=%d shaped_blocks=%d shaped_requested=%d", hobject::opprof_storage[2], hobject::opprof_storage[3], hobject::opprof_storage[4], hobject::opprof_storage[5], hobject::opprof_storage[6], hobject::opprof_storage[7], hobject::opprof_storage[8], hobject::opprof_storage[9], hobject::opprof_storage[10], hobject::opprof_storage[11], hobject::opprof_storage[12]);
    io::eprintfn("# PAGEPOOL_TRAFFIC freelist_allocs=%d fresh_zeroed_bumps=%d recycled_page_bumps=%d freelist_clear_bytes=%d recycled_bump_clear_bytes=%d new_pages=%d calloc_requested_bytes=%d reserved_page_reuses=%d", pagepool::opprof_pool[0], pagepool::opprof_pool[1], pagepool::opprof_pool[2], pagepool::opprof_pool[3], pagepool::opprof_pool[4], pagepool::opprof_pool[5], pagepool::opprof_pool[6], pagepool::opprof_pool[7]);
    io::eprintn("# Capacity/property buckets are 0..16,17+; requested bytes exclude allocator rounding; PagePool totals cover all users; calloc bytes are logical zero requests, not measured physical writes");
}

fn void shape_profile_dump() @feat(OP_PROFILE) {
    io::eprintfn("# SHAPE_PROFILE totals=%s replacements=%d sample_period=64", shape_profile_totals, shape_profile_replacements);
    io::eprintn("# counts: own_guard inherited_guard shape_miss generation_miss chain_miss shared_hit generic missing key_miss computed_thread_attempt computed_switch_attempt");
    io::eprintn("# key_miss is an IC key-guard miss, including cold/unfilled/refused entries; only the separate sampled input fingerprints describe observed input-key diversity");
    io::eprintn("# computed keys are sampled input fingerprints: string symbol number other; hash collisions and symbol-address reuse can merge keys, other inputs are grouped by tag, no coercion is performed");
    foreach (&site : shape_profile_sites) {
        if (site.samples < 32) continue;
        io::eprintf("SHAPE_SITE samples=%d shapes=%s sequence=%s counts=%s overflow=%s line=%d column=%d pc=%d function_hex=", site.samples,
            site.shapes[:site.shape_count], site.sequence[:site.sequence_count], site.counts,
            site.overflow_shapes, site.line, site.column, site.pc);
        shape_profile_hex(site.name[:site.name_len]);
        io::eprint(" file_hex=");
        shape_profile_hex(site.filename[:site.filename_len]);
        io::eprint(" key_hex=");
        shape_profile_hex(site.key[:site.key_len]);
        io::eprintn("");
        // Keep the original SHAPE_SITE line stable for existing report readers.
        if (site.computed_samples != 0) {
            io::eprintf("SHAPE_KEYS pc=%d computed_samples=%d fingerprints=%s kinds=%s input_kinds=%s sampled_input_changes=%d overflow=%s receiver_class_mask=%d function_hex=",
                site.pc, site.computed_samples, site.key_fingerprints[:site.key_count],
                site.key_kinds[:site.key_count], site.input_kinds, site.key_changes,
                site.overflow_keys, site.receiver_classes);
            shape_profile_hex(site.name[:site.name_len]);
            io::eprint(" file_hex=");
            shape_profile_hex(site.filename[:site.filename_len]);
            io::eprintn("");
        }
    }
}

// Own-position cache eligibility in the final in-memory stream. The inline
// read guard borrows the following GETPROPC record instead of its own slot.
// Unknown future opcodes remain explicit, not silently classified as unused.
fn uint shape_profile_cache_family(Opcode op) @feat(OP_PROFILE) {
    switch (op) {
        case Opcode.LDREG:
        case Opcode.LDCONST:
        case Opcode.SETCONST:
        case Opcode.LDINT:
        case Opcode.LDINTX:
        case Opcode.LDUNDEF:
        case Opcode.LDNULL:
        case Opcode.LDTRUE:
        case Opcode.LDFALSE:
        case Opcode.LDTHIS:
        case Opcode.ADD:
        case Opcode.SUB:
        case Opcode.MUL:
        case Opcode.DIV:
        case Opcode.MOD:
        case Opcode.EXP:
        case Opcode.ADDI:
        case Opcode.SUBI:
        case Opcode.MULI:
        case Opcode.BANDI:
        case Opcode.BORI:
        case Opcode.BXORI:
        case Opcode.SHLI:
        case Opcode.SHRI:
        case Opcode.USHRI:
        case Opcode.UNP:
        case Opcode.UNM:
        case Opcode.BNOT:
        case Opcode.LNOT:
        case Opcode.TYPEOF:
        case Opcode.VOID:
        case Opcode.BAND:
        case Opcode.BOR:
        case Opcode.BXOR:
        case Opcode.SHL:
        case Opcode.SHR:
        case Opcode.USHR:
        case Opcode.EQ:
        case Opcode.NEQ:
        case Opcode.SEQ:
        case Opcode.SNEQ:
        case Opcode.LT:
        case Opcode.LE:
        case Opcode.GT:
        case Opcode.GE:
        case Opcode.INSTANCEOF:
        case Opcode.IN:
        case Opcode.JUMP:
        case Opcode.IF_TRUE:
        case Opcode.IF_FALSE:
        case Opcode.PUTPROP_NE:
        case Opcode.DELPROP:
        case Opcode.NEWOBJ:
        case Opcode.NEWARR:
        case Opcode.NEWARR_CONST:
        case Opcode.SETALEN:
        case Opcode.FREEZEOBJ:
        case Opcode.CALL:
        case Opcode.CALL_PROP:
        case Opcode.TAILCALL:
        case Opcode.RET:
        case Opcode.RETUNDEF:
        case Opcode.THROW_UNRESOLVED:
        case Opcode.DECLGLOBALFUNC:
        case Opcode.DECLB33GLOBAL:
        case Opcode.DELVAR:
        case Opcode.WITH_START:
        case Opcode.WITH_END:
        case Opcode.WITHGET:
        case Opcode.WITHBASE:
        case Opcode.WTWR:
        case Opcode.CLOSURE:
        case Opcode.GETBOUND:
        case Opcode.INITFOR:
        case Opcode.NEXTFOR:
        case Opcode.TRY:
        case Opcode.ENDTRY:
        case Opcode.THROW:
        case Opcode.THROW_REF:
        case Opcode.THROW_SYNTAX:
        case Opcode.CATCH:
        case Opcode.FINALLY:
        case Opcode.ENDFINALLY:
        case Opcode.TOPROPKEY:
        case Opcode.TOSTR:
        case Opcode.NOP:
        case Opcode.DEBUGGER:
        case Opcode.BREAK:
        case Opcode.CONTINUE:
        case Opcode.INITSET:
        case Opcode.INITGET:
        case Opcode.INITSETI:
        case Opcode.INITPROP:
        case Opcode.INITPROPN:
        case Opcode.CLASS_INITGET:
        case Opcode.CLASS_INITSET:
        case Opcode.CLASS_INITPROP:
        case Opcode.CSVARI:
        case Opcode.PUSH_LEX:
        case Opcode.POP_LEX:
        case Opcode.PUSH_VAR:
        case Opcode.POP_VAR:
        case Opcode.PUTLEX:
        case Opcode.PUTLEX_C:
        case Opcode.INITTZ:
        case Opcode.CHKGLOBALLEX:
        case Opcode.CHKGLOBALVAR:
        case Opcode.CHKGLOBALFUNC:
        case Opcode.NEWREGEXP:
        case Opcode.RETEST:
        case Opcode.HOF_GUARD:
        case Opcode.HOF_ELEM:
        case Opcode.HOF_GET:
        case Opcode.HOF_NEWARR:
        case Opcode.HOF_PUT:
        case Opcode.ARRSPRD:
        case Opcode.SPREAD_ARG:
        case Opcode.FWD_ARGS:
        case Opcode.APPLY_ARGS:
        case Opcode.CALL_S:
        case Opcode.CALL_UNDEF_THIS:
        case Opcode.OBJSPRD:
        case Opcode.OBJREST:
        case Opcode.SETPROTO:
        case Opcode.GETPROTO:
        case Opcode.PUTPROP_SUPER:
        case Opcode.SUPER_CALL:
        case Opcode.SUPER_CALL_S:
        case Opcode.NEWTARGET:
        case Opcode.LOAD_RESUME:
        case Opcode.YIELD:
        case Opcode.YIELD_STAR:
        case Opcode.YIELD_STAR_ASYNC:
        case Opcode.RET_GEN:
        case Opcode.RETUNDEF_GEN:
        case Opcode.AWAIT:
        case Opcode.DYN_IMPORT:
        case Opcode.DYN_IMPORT_DEFER:
        case Opcode.DYN_IMPORT_SOURCE:
        case Opcode.GEN_START:
        case Opcode.INC:
        case Opcode.DEC:
        case Opcode.PUTARG:
        case Opcode.JMP_NLT:
        case Opcode.JMP_NLE:
        case Opcode.JMP_NGT:
        case Opcode.JMP_NGE:
        case Opcode.JMP_LT:
        case Opcode.JMP_LE:
        case Opcode.JMP_GT:
        case Opcode.JMP_GE:
        case Opcode.JMP_SEQ:
        case Opcode.JMP_SNEQ:
        case Opcode.JMP_EQ:
        case Opcode.JMP_NEQ:
        case Opcode.JMP_NULL:
        case Opcode.JMP_NNULL:
        case Opcode.JMP_NLTI:
        case Opcode.JMP_NLEI:
        case Opcode.JMP_NGTI:
        case Opcode.JMP_NGEI:
        case Opcode.JMP_LTI:
        case Opcode.JMP_LEI:
        case Opcode.JMP_GTI:
        case Opcode.JMP_GEI:
        case Opcode.JMP_SEQI:
        case Opcode.JMP_SNEQI:
        case Opcode.REQUIRE_OBJ:
        case Opcode.CHKOBJ:
        case Opcode.CHKITER:
        case Opcode.ITER_NEXT_FAST:
        case Opcode.ITER_ENTRY_FAST:
        case Opcode.ARRAY_PATTERN_GUARD:
        case Opcode.ITER_OPEN_FAST:
        case Opcode.DESTRUCT_ARRAY_FAST:
        case Opcode.DESTRUCT_ARRAY_REST_FAST:
        case Opcode.ITER_CLOSE:
        case Opcode.ITER_CLOSE_ESCAPE:
        case Opcode.GET_ITER_ASYNC:
        case Opcode.ITER_CLOSE_ASYNC:
        case Opcode.CHKCTOR:
        case Opcode.CHK_PROT:
        case Opcode.NEW_PRIV_SYM:
        case Opcode.ADD_BRAND:
        case Opcode.CHK_BRAND:
        case Opcode.HAS_BRAND:
        case Opcode.INITPROP_PRIV:
        case Opcode.GETPROP_PRIVATE:
        case Opcode.TONUMERIC:
        case Opcode.IMPORT_META:
        case Opcode.WIDE:
        case Opcode.TAILCALL_UNDEF_THIS:
        case Opcode.TAILCALL_CALL:
        case Opcode.TAILCALL_CALL_S:
        case Opcode.STRJOIN:
        case Opcode.NEWCELLS:
        case Opcode.GETCELL:
        case Opcode.SETCELL:
        case Opcode.MOVECELL:
        case Opcode.NEWOBJ_SHAPE:
        case Opcode.INIT_SLOT:
        case Opcode.INITELEM:
        case Opcode.ADD_FUSED:
        case Opcode.INC_LT:
        case Opcode.STRJOIN_LENGTH:
        case Opcode.SPREAD_PROJECTION:
        case Opcode.INLINE_GUARD:
        case Opcode.INLINE_READ_GUARD:
        case Opcode.INLINE_NUM_GUARD:
        case Opcode.INLINE_COMMIT:
        case Opcode.INLINE_GETCAP:
        case Opcode.INLINE_THIS:
            return 0;
        case Opcode.GETPROP:
        case Opcode.GETPROPC:
        case Opcode.GETPROP_CACHE:
        case Opcode.GETPROPC_CACHED:
        case Opcode.GETTHISC:
        case Opcode.PUTPROP:
        case Opcode.PUTPROPC:
        case Opcode.PUTTHISC:
        case Opcode.GETPROP_SUPER:
        case Opcode.NEW_OBJ:
        case Opcode.NEW_OBJ_S:
        case Opcode.CLASS_SCALAR_GUARD:
        case Opcode.DECLVAR_HOIST:
            return 1;
        case Opcode.GETVAR:
        case Opcode.GETCAP:
        case Opcode.GETGLOBAL:
        case Opcode.TYPEOFIDENT:
        case Opcode.RESOLVEVAR:
        case Opcode.PUTGLOBAL:
        case Opcode.PUTVAR:
        case Opcode.PUTVAR_ASSIGN:
        case Opcode.PUTCAP:
        case Opcode.PUTCAP_SNAP:
        case Opcode.PUTVAR_SNAP:
        case Opcode.CALL_VAR:
        case Opcode.CALL_GLOBAL:
        case Opcode.TAILCALL_VAR:
        case Opcode.TAILCALL_GLOBAL:
        case Opcode.INC_VAR:
        case Opcode.DEC_VAR:
        case Opcode.INC_GLOBAL:
        case Opcode.DEC_GLOBAL:
        case Opcode.INLINE_GETFREE:
            return 2;
        case Opcode.DECLVAR:
            return 3;
        default:
            return 4;
    }
}

struct ShapeProfileOwnership {
    uint users;
    uint out_degree;
    bool object_ancestor;
    bool pinned_dependency;
}
const uint SHAPE_PROFILE_CENSUS_LIMIT = 65536;

fn void shape_profile_mark_ancestors(heap::Heap* h, ShapeProfileOwnership* entries,
                                     uint count, uint id, bool pinned) @feat(OP_PROFILE) {
    uint steps = 0;
    while (id < h.shape_count && h.shape_slot_live(id) && steps++ < h.shape_count) {
        if (id < count) {
            if (pinned) {
                entries[id].pinned_dependency = true;
            } else {
                entries[id].object_ancestor = true;
            }
        }
        id = h.shapes[id].parent;
    }
}

// Temporary bounded scratch; counters describe the registered snapshot, not
// reachability. Parents of out-of-range shapes are still visited when valid.
fn void shape_profile_ownership(heap::Heap* h) @feat(OP_PROFILE) {
    uint count = min(h.shape_count, SHAPE_PROFILE_CENSUS_LIMIT);
    usz bytes = (usz)count * ShapeProfileOwnership::size;
    ShapeProfileOwnership* entries = (ShapeProfileOwnership*)h.alloc_func(h.heap_udata, bytes);
    if (entries == null) {
        io::eprintn("# SHAPE_OWNERSHIP unavailable=allocation_failure");
        return;
    }
    defer h.free_func(h.heap_udata, entries);
    mem::clear(entries, (sz)bytes);
    ulong untracked_objects = 0;
    heap::HeapObjectCursor cursor;
    for (HeapHeader* header = h.next_object(&cursor); header != null; header = h.next_object(&cursor)) {
        if (!header.is_object()) continue;
        hobject::HObject* object = (hobject::HObject*)header;
        if (object.shape_id >= h.shape_count || !h.shape_slot_live(object.shape_id)) continue;
        if (object.shape_id < count) {
            entries[object.shape_id].users++;
        } else {
            untracked_objects++;
        }
        shape_profile_mark_ancestors(h, entries, count, h.shapes[object.shape_id].parent, false);
    }
    for (uint id = 0; id < h.shape_count; id++) {
        if (h.shape_slot_live(id) && h.shapes[id].pinned) {
            shape_profile_mark_ancestors(h, entries, count, id, true);
        }
    }
    if (h.trans_table != null) {
        for (uint i = 0; i <= h.trans_mask; i++) {
            heap::TransitionEntry* transition = &h.trans_table[i];
            if (transition.parent_id < count) entries[transition.parent_id].out_degree++;
        }
    }
    ulong direct = 0;
    ulong ancestor_only = 0;
    ulong pinned_only = 0;
    ulong unexplained = 0;
    ulong[18] users;
    ulong[18] out_degree;
    for (uint id = 0; id < count; id++) {
        if (!h.shape_slot_live(id)) continue;
        ShapeProfileOwnership* entry = &entries[id];
        users[min(entry.users, 17u)]++;
        out_degree[min(entry.out_degree, 17u)]++;
        if (entry.users != 0) {
            direct++;
        } else if (entry.object_ancestor) {
            ancestor_only++;
        } else if (entry.pinned_dependency) {
            pinned_only++;
        } else {
            unexplained++;
        }
    }
    io::eprintfn("# SHAPE_OWNERSHIP tracked_ids=%d truncated=%s untracked_object_shapes=%d direct=%d object_ancestor_only=%d pinned_only=%d not_explained_by_registered_objects_or_pins=%d users=%s transition_out_degree=%s", count, h.shape_count > count, untracked_objects, direct, ancestor_only, pinned_only, unexplained, users, out_degree);
}

// End-of-run registered populations, not a peak or root-liveness claim.
fn void shape_profile_heap(heap::Heap* h) @feat(OP_PROFILE) {
    ulong instructions = 0;
    ulong cached_positions = 0;
    ulong property_bytes = 0;
    ulong variable_bytes = 0;
    ulong own = 0;
    ulong inherited = 0;
    ulong absent = 0;
    ulong variable_filled = 0;
    ulong[5] all_families;
    ulong[5] reserved_families;
    ulong[bytecode::Opcode::len] unknown_opcodes;
    ulong populated_known_none = 0;
    for (uint i = 0; i < h.compiled_func_count; i++) {
        CompiledFunction* f = (CompiledFunction*)h.compiled_funcs[i];
        if (f == null) continue;
        instructions += f.code_count;
        for (uint pc = 0; pc < f.code_count; pc++) {
            uint family = shape_profile_cache_family(f.code[pc].op);
            all_families[family]++;
            if (f.ic_entries != null || f.var_ic_entries != null) reserved_families[family]++;
            if (family == 4) unknown_opcodes[(uint)f.code[pc].op.ordinal]++;
        }
        if (f.ic_entries != null) {
            cached_positions += f.code_count;
            property_bytes += (ulong)f.ic_count * hobject::ICEntry::size;
            hobject::ICEntry* entries = (hobject::ICEntry*)f.ic_entries;
            for (uint j = 0; j < f.ic_count; j++) {
                if (entries[j].key.borrow() == null) continue;
                if (j < f.code_count && shape_profile_cache_family(f.code[j].op) == 0) populated_known_none++;
                if (entries[j].prop_idx == hobject::IC_PROP_ABSENT) {
                    absent++;
                } else if (entries[j].proto != null) {
                    inherited++;
                } else {
                    own++;
                }
            }
        }
        if (f.var_ic_entries != null) {
            variable_bytes += (ulong)f.var_ic_count * hobject::VarICEntry::size;
            hobject::VarICEntry* entries = (hobject::VarICEntry*)f.var_ic_entries;
            for (uint j = 0; j < f.var_ic_count; j++) if (entries[j].slot_ptr != null) variable_filled++;
        }
    }
    ulong[18] properties;
    ulong[64] classes;
    ulong overflow_objects = 0;
    ulong overflow_requested = 0;
    heap::HeapObjectCursor cursor;
    for (HeapHeader* header = h.next_object(&cursor); header != null; header = h.next_object(&cursor)) {
        if (!header.is_object()) continue;
        hobject::HObject* object = (hobject::HObject*)header;
        properties[min(object.prop_count, 17u)]++;
        classes[min((uint)object.get_class().ordinal, 63u)]++;
        if (object.prop_alloc != null) {
            overflow_objects++;
            overflow_requested += object.prop_alloc_size();
        }
    }
    ulong shapes = 0;
    ulong shape_bytes = 0;
    ulong hash_bytes = 0;
    ulong dict = 0;
    for (uint i = 0; i < h.shape_count; i++) {
        if (!h.shape_slot_live(i)) continue;
        hobject::Shape* shape = h.shapes[i];
        shapes++;
        shape_bytes += hobject::shape_alloc_size(shape.capacity);
        if (shape.dict) dict++;
        if (shape.hash_table != null) hash_bytes += (ulong)(hobject::prop_hash_mask_for(shape.offset + shape.own_count) + 1) * hobject::HashEntry::size;
    }
    io::eprintfn("# CACHE_ELIGIBILITY categories=known_none,property,variable,both,unclassified all=%s reserved_positions=%s populated_property_at_known_none=%d", all_families, reserved_families, populated_known_none);
    for (uint op = 0; op < unknown_opcodes.len; op++) {
        if (unknown_opcodes[op] != 0) io::eprintfn("# CACHE_UNCLASSIFIED opcode=%s positions=%d", (ZString)bytecode::get_opcode_name((bytecode::Opcode)op), unknown_opcodes[op]);
    }
    shape_profile_ownership(h);
    shape_profile_allocation_dump();
    io::eprintfn("# SHAPE_TYPES instruction=%d IC=%d VarIC=%d Shape=%d HObjectBase=%d PropValue=%d PagePool=%d", Instruction::size, hobject::ICEntry::size, hobject::VarICEntry::size, hobject::Shape::size, hobject::HObjectBase::size, hobject::PropValue::size, pagepool::PagePool::size);
    io::eprintfn("# SHAPE_CENSUS instructions=%d cached_positions=%d property_bytes=%d variable_bytes=%d own=%d inherited=%d absent=%d variable_filled=%d", instructions, cached_positions, property_bytes, variable_bytes, own, inherited, absent, variable_filled);
    io::eprintfn("# SHAPE_LAYOUTS shapes=%d dict=%d shape_bytes=%d hash_bytes=%d transitions=%d", shapes, dict, shape_bytes, hash_bytes, (ulong)(h.trans_mask + 1) * heap::TransitionEntry::size);
    io::eprintfn("# SHAPE_POPULATION properties=%s classes=%s overflow_objects=%d overflow_requested=%d", properties, classes, overflow_objects, overflow_requested);
}
