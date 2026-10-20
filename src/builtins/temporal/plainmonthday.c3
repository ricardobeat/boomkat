// Temporal.PlainMonthDay. Its operations are the ones plainyearmonth.c3 shares between the two.
module boomkat::builtins @feat(TEMPORAL);

import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::lib::temporal;

fn void builtin_temporal_plain_monthday_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainMonthDay requires new");
        return;
    }
    temporal::CivilDate iso = { .y = 1972 };
    temporal::CalendarId cal;
    if (!to_integer_field(ctx, arg_at(ctx, 0), &iso.m) || !to_integer_field(ctx, arg_at(ctx, 1), &iso.d)
        || !calendar_ctor_arg(ctx, arg_at(ctx, 2), &cal)
        || (!arg_at(ctx, 3).is_undefined() && !to_integer_field(ctx, arg_at(ctx, 3), &iso.y))) return;
    construct_partial_date(ctx, MONTH_DAY, iso, cal);
}

fn void builtin_temporal_plain_monthday_from(BuiltinContext* ctx) => partial_date_from(ctx, MONTH_DAY);
fn void builtin_temporal_plain_monthday_proto_valueOf(BuiltinContext* ctx) => partial_date_value_of(ctx, MONTH_DAY);
fn void builtin_temporal_plain_monthday_proto_toString(BuiltinContext* ctx) => partial_date_to_string(ctx, MONTH_DAY);
fn void builtin_temporal_plain_monthday_proto_toJSON(BuiltinContext* ctx) => partial_date_to_string_default(ctx, MONTH_DAY, false);
fn void builtin_temporal_plain_monthday_proto_toLocaleString(BuiltinContext* ctx) => partial_date_to_string_default(ctx, MONTH_DAY, true);
fn void builtin_temporal_plain_monthday_proto_equals(BuiltinContext* ctx) => partial_date_equals(ctx, MONTH_DAY);
fn void builtin_temporal_plain_monthday_proto_with(BuiltinContext* ctx) => partial_date_with(ctx, MONTH_DAY);
fn void builtin_temporal_plain_monthday_proto_toPlainDate(BuiltinContext* ctx) => partial_date_to_plain_date(ctx, MONTH_DAY);
