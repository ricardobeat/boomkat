// Intl.supportedValuesOf (ECMA-402 §8.3.2): the calendars, currencies,
// numbering systems, time zones and units the Intl services accept.
module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::lib::temporal;

const usz INTL_VALUES_UNIT_CAP = 64;

fn bool intl_values_push(BuiltinContext* ctx, HObject* list, uint* count, char[] name) {
    HString* s = builtin_intern_string(ctx.heap, name);
    if (s == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return false; }
    TVal v; v.set_string_borrowed(s);
    array_set_elem(list, (*count)++, v, ctx.heap);
    return true;
}

fn void builtin_intl_supported_values_of(BuiltinContext* ctx) {
    TVal key_arg = builtin_arg(ctx, 0);
    HString* key = builtin_to_string_vm(ctx, &key_arg);
    if (ctx.should_throw || key == null) return;
    char[] name = key.get_cstr()[:key.blen];
    HObject* list = intl_array(ctx);
    if (ctx.should_throw) return;
    uint count = 0;
    if (mem_eq_bytes(name, "calendar")) {
        $if !$feat(NO_INTL_DATE):
            // Sorted, as AvailableCalendars requires. Every name here resolves in DateTimeFormat.
            char[][16] calendars = {"buddhist", "chinese", "coptic", "dangi", "ethioaa", "ethiopic", "gregory", "hebrew", "indian", "islamic-civil", "islamic-tbla", "islamic-umalqura", "iso8601", "japanese", "persian", "roc"};
            foreach (calendar_name : calendars) {
                if (!intl_values_push(ctx, list, &count, calendar_name)) return;
            }
        $endif
    } else if (mem_eq_bytes(name, "collation")) {
        $if $feat(INTL_COLLATOR):
            for (usz i = 0; i < coll_selectable_type_count(); i++) {
                if (!intl_values_push(ctx, list, &count, coll_selectable_type_name(i))) return;
            }
        $endif
    } else if (mem_eq_bytes(name, "currency")) {
        foreach (packed : INTL_CURRENCY_CODES) {
            char[3] code = { (char)(((packed >> 10) & 31) + 64), (char)(((packed >> 5) & 31) + 64), (char)((packed & 31) + 64) };
            if (!intl_values_push(ctx, list, &count, code[..])) return;
        }
    } else if (mem_eq_bytes(name, "numberingSystem")) {
        for (usz i = 0; i < INTL_DIGIT_COUNT; i++) {
            if (!intl_values_push(ctx, list, &count, intl_digit_name(i))) return;
        }
    } else if (mem_eq_bytes(name, "timeZone")) {
        $if !$feat(NO_INTL_DATE):
            usz zones = temporal::tzdb_zone_count();
            for (usz i = 0; i < zones; i++) {
                char[64] buf;
                usz n = temporal::tzdb_zone_name((int)i, &buf[0]);
                char[128] canonical;
                usz m = intl_zone_canonical(buf[:n], canonical[..]);
                if (m != n || !mem_eq_bytes(canonical[:m], buf[:n])) continue;
                if (!intl_values_push(ctx, list, &count, buf[:n])) return;
            }
        $endif
    } else if (mem_eq_bytes(name, "unit")) {
        char[][INTL_VALUES_UNIT_CAP] units;
        usz n = 0;
        foreach (entry : INTL_UNIT_NAMES) {
            if (n == INTL_VALUES_UNIT_CAP) break;
            units[n++] = intl_data_string(entry);
        }
        for (usz i = 1; i < n; i++) {
            char[] held = units[i];
            usz j = i;
            while (j > 0 && locale_compare(units[j - 1], held) > 0) { units[j] = units[j - 1]; j--; }
            units[j] = held;
        }
        for (usz i = 0; i < n; i++) {
            if (!intl_values_push(ctx, list, &count, units[i])) return;
        }
    } else {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid key for supportedValuesOf");
        return;
    }
    array_set_length(list, count, ctx.heap);
    ctx.result_object(list);
}
