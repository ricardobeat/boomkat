#!/usr/bin/env bash
# Assert the public API and locale coverage selected by the build options.
set -euo pipefail

ENGINE="${1:-./out/boomkat}"
INTL="${2:-none}"
TEMPORAL="${3:-false}"
COLLATOR="${4:-$(if [ "$INTL" = full ]; then echo true; else echo false; fi)}"
case "$INTL" in none|small|full) ;; *) echo "invalid Intl profile: $INTL" >&2; exit 2;; esac
case "$TEMPORAL" in true|false) ;; *) echo "invalid Temporal setting: $TEMPORAL" >&2; exit 2;; esac
case "$COLLATOR" in true|false) ;; *) echo "invalid Collator setting: $COLLATOR" >&2; exit 2;; esac
if [ "$INTL" = none ] && [ "$COLLATOR" = true ]; then
    echo "Collator requires Intl" >&2; exit 2
fi

probe=$(mktemp "${TMPDIR:-/tmp}/boomkat-profile-XXXXXX")
trap 'rm -f "$probe"' EXIT
cat > "$probe" <<JS
function check(ok, name) { if (!ok) throw new Error(name); }
check(typeof Temporal === ($TEMPORAL ? 'object' : 'undefined'), 'Temporal availability');
check(typeof Intl === ('$INTL' !== 'none' ? 'object' : 'undefined'), 'Intl availability');
if (typeof Intl === 'object') {
    check(new Intl.NumberFormat('en').format(1234) === '1,234', 'English formatting');
    check((new Intl.NumberFormat('de').resolvedOptions().locale === 'de') === ('$INTL' === 'full'), 'locale data coverage');
    var names = ['NumberFormat', 'DateTimeFormat', 'PluralRules', 'ListFormat',
                 'RelativeTimeFormat', 'DisplayNames', 'DurationFormat', 'Segmenter'];
    for (var i = 0; i < names.length; i++) check(typeof Intl[names[i]] === 'function', names[i]);
    check((typeof Intl.Collator === 'function') === $COLLATOR, 'Collator availability');
    if ($COLLATOR) {
        check(new Intl.Collator('en').compare('a', 'b') < 0, 'root collation');
        check(new Intl.Collator('en', { numeric: true }).compare('2', '10') < 0, 'numeric collation');
        check('2'.localeCompare('10', 'en', { numeric: true }) < 0, 'localeCompare numeric collation');
    }
    var duration = new Intl.DurationFormat('en', { style: 'digital' });
    check(duration.format({ hours: 1, minutes: 2, seconds: 3 }) === '1:02:03', 'duration object formatting');
    check(duration.format('PT1H2M3S') === '1:02:03', 'duration string formatting');
}
check('a'.localeCompare('b') < 0, 'localeCompare order');
check('o\\u0308'.localeCompare('ö') === 0, 'localeCompare canonical equivalence');
if (!$COLLATOR) {
    check('a'.localeCompare('B') > 0, 'localeCompare lexical fallback');
    check('2'.localeCompare('10', 'en', { numeric: true }) > 0, 'localeCompare fallback ignores collation options');
}
console.log('Build profile: intl=$INTL temporal=$TEMPORAL collator=$COLLATOR PASS');
JS
"$ENGINE" --script "$probe"
