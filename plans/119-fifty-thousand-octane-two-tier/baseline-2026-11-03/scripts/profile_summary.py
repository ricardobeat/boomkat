import re, sys
exec(open(__file__.replace('profile_summary.py', 'classify.py')).read().split('for path in sys.argv[1:]:')[0])
# Percentages are of all main-thread samples. Symbols below sample's
# five-sample listing threshold are unlisted; they are counted as generated
# code, which overstates that bucket by the small-symbol C tail (2-6% in the
# interpreter-only profiles).
for path in sys.argv[1:]:
    text = open(path, errors='replace').read()
    total = int(re.search(r'Call graph:\n\s+(\d+) Thread_', text).group(1))
    listed, b, top = buckets(path)
    b['jit-code'] += total - listed
    print(f"== {path.split('/')[-1]}  samples={total}")
    print('   ' + '  '.join(f'{k} {100*v/total:.0f}%' for k, v in b.most_common()))
    for (k, s), n in top.most_common(10):
        if k == 'jit-code': continue
        print(f'   {100*n/total:5.1f}%  {s[:80]}')
