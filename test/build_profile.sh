#!/usr/bin/env bash
# Assert the public API and locale coverage selected by the build options.
set -euo pipefail

ENGINE="${1:-./out/boomkat}"
INTL="${2:-small}"
TEMPORAL="${3:-false}"
case "$INTL" in none|small|full) ;; *) echo "invalid Intl profile: $INTL" >&2; exit 2;; esac
case "$TEMPORAL" in true|false) ;; *) echo "invalid Temporal setting: $TEMPORAL" >&2; exit 2;; esac

probe=$(mktemp "${TMPDIR:-/tmp}/boomkat-profile-XXXXXX")
trap 'rm -f "$probe"' EXIT
cat > "$probe" <<JS
function check(ok, name) { if (!ok) throw new Error(name); }
check((typeof Temporal === 'object') === $TEMPORAL, 'Temporal availability');
check((typeof Intl === 'object') === ('$INTL' !== 'none'), 'Intl availability');
if (typeof Intl === 'object') {
    check(new Intl.NumberFormat('en').format(1234) === '1,234', 'English formatting');
    check((new Intl.NumberFormat('de').resolvedOptions().locale === 'de') === ('$INTL' === 'full'), 'locale data coverage');
    var names = ['NumberFormat', 'DateTimeFormat', 'PluralRules', 'ListFormat',
                 'RelativeTimeFormat', 'DisplayNames', 'DurationFormat', 'Segmenter', 'Collator'];
    for (var i = 0; i < names.length; i++) check(typeof Intl[names[i]] === 'function', names[i]);
    check(new Intl.Collator('en').compare('a', 'b') < 0, 'root collation');
    var duration = new Intl.DurationFormat('en', { style: 'digital' });
    check(duration.format({ hours: 1, minutes: 2, seconds: 3 }) === '1:02:03', 'duration object formatting');
    check(duration.format('PT1H2M3S') === '1:02:03', 'duration string formatting');
}
console.log('Build profile: intl=$INTL temporal=$TEMPORAL PASS');
JS
"$ENGINE" --script "$probe"
