#!/usr/bin/env python3
"""Render the supplied 15-benchmark snapshot as a dark PNG and SVG chart.

Run: python3 scripts/plot_benchmark_comparison.py
Dependencies: python3 -m pip install matplotlib numpy fonttools

Install Funnel Sans and JetBrains Mono in a user font directory, or pass
--font-dir, to reproduce the original typography. DejaVu fonts are the fallback.
SVG text is exported as paths so the chart displays without installed fonts.
Edit names/data below to update the timings; column order is Boomkat, QuickJS,
Node.js, and every value is milliseconds.
"""

from pathlib import Path
from glob import escape
import argparse
import os
import tempfile

os.environ.setdefault('MPLCONFIGDIR', str(Path(tempfile.gettempdir()) / 'boomkat-chart-mpl'))
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Patch
from matplotlib.font_manager import FontProperties
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--output-dir', type=Path,
    default=Path(__file__).resolve().parents[1] / 'out' / 'benchmark-comparison',
    help='Directory for the PNG and SVG exports',
)
parser.add_argument(
    '--font-dir', type=Path,
    help='Directory containing Funnel Sans and JetBrains Mono variable TTFs',
)
args = parser.parse_args()
font_roots = [args.font_dir] if args.font_dir else [
    Path.home() / 'Library' / 'Fonts',
    Path.home() / '.local' / 'share' / 'fonts',
    Path.home() / '.fonts',
    Path('/usr/local/share/fonts'),
    Path('/usr/share/fonts'),
]
# Keep instantiated fonts alive until both exports finish.
font_temp = tempfile.TemporaryDirectory(prefix='boomkat-chart-fonts-')
font_dir = Path(font_temp.name)

def chart_font(filename, source_name, weight, fallback):
    for root in font_roots:
        if not root.is_dir():
            continue
        for source in root.rglob(escape(source_name)):
            target = font_dir / filename
            font = TTFont(source)
            instantiateVariableFont(font, {'wght': weight}, inplace=True).save(target)
            font.close()
            return FontProperties(fname=str(target))
    return FontProperties(family=fallback, weight='bold' if weight == 700 else 'normal')

sans = chart_font('sans.ttf', 'FunnelSans-VariableFont_wght.ttf', 450, 'DejaVu Sans')
bold = chart_font('sans-bold.ttf', 'FunnelSans-VariableFont_wght.ttf', 700, 'DejaVu Sans')
mono = chart_font('mono.ttf', 'JetBrainsMono[wght].ttf', 400, 'DejaVu Sans Mono')
legend_font = sans.copy()
legend_font.set_size(11)

names = ['arithmetic', 'array', 'date', 'function_call', 'loop', 'memory_heavy',
         'object', 'property_lookup', 'recursion', 'recursion_deep', 'regexp',
         'scene_churn', 'shape_stress', 'string', 'valstack_copy']
data = np.array([
    [17.0,21.4,14.2], [4.8,4.4,4.6], [12.0,9.6,19.2], [21.4,28.8,5.0],
    [13.2,23.0,5.4], [32.8,36.8,14.0], [31.0,34.6,16.4], [23.6,24.0,11.0],
    [27.0,27.0,5.8], [113.0,113.6,17.0], [48.0,50.6,9.4],
    [136.6,147.2,34.8], [20.0,15.0,38.2], [19.8,19.2,8.6], [28.4,60.0,6.4]
])
colors = ['#F3BE5B', '#56CCBC', '#9CA9FF']
bg, ink, muted = '#10151D', '#F0F3F8', '#97A4B6'
plt.rcParams.update({'font.family':'DejaVu Sans', 'font.size':11,
                     'svg.fonttype':'path', 'axes.edgecolor':bg, 'text.color':ink})
fig, ax = plt.subplots(figsize=(14,12), dpi=180)
fig.patch.set_facecolor(bg)
ax.set_facecolor(bg)
fig.subplots_adjust(left=.20, right=.94, bottom=.105, top=.82)
y=np.arange(len(names))
for i in range(len(names)):
    if i % 2 == 0:
        ax.axhspan(i-.46, i+.46, color='#161D28', zorder=0)
for j, (engine,color) in enumerate(zip(['Boomkat','QuickJS','Node.js'],colors)):
    positions=y+(j-1)*.235
    ax.barh(positions, data[:,j], height=.185, color=color, zorder=3)
    for pos, val in zip(positions,data[:,j]):
        ax.text(val+1.2, pos, f'{val:.1f}', va='center', fontsize=8.8,
                color=color, fontproperties=mono, zorder=4)
ax.set_yticks(y, names)
for label in ax.get_yticklabels():
    label.set_fontproperties(mono)
    label.set_color('#D5DDE8')
for label in ax.get_xticklabels():
    label.set_fontproperties(mono)
ax.tick_params(axis='y', length=0, pad=12, labelsize=11)
ax.tick_params(axis='x', length=0, pad=10, colors=muted)
ax.set_ylim(len(names)-.6,-.6)
ax.set_xlim(0,162)
ax.set_xticks(np.arange(0,161,20))
ax.xaxis.grid(True, color='#2A3442', linewidth=.7, zorder=1)
ax.set_axisbelow(True)
for spine in ax.spines.values(): spine.set_visible(False)
ax.set_xlabel('Execution time (ms)', labelpad=16, color=muted, fontsize=11, fontproperties=sans)
fig.text(.065,.943,'JAVASCRIPT ENGINE BENCHMARKS',color=colors[0], fontsize=11, fontproperties=bold)
fig.text(.065,.899,'Boomkat / QuickJS / Node.js',color=ink,fontsize=29,fontproperties=bold)
fig.text(.065,.865,'Execution time in milliseconds  ·  Shorter bars are faster',color=muted,fontsize=12,fontproperties=sans)
fig.legend(handles=[Patch(facecolor=c,label=n) for c,n in zip(colors,['Boomkat','QuickJS','Node.js'])],
           loc='upper right',bbox_to_anchor=(.94,.861),ncol=3,frameon=False,
           prop=legend_font,labelcolor=ink,handlelength=1.2,handleheight=.8,columnspacing=1.8)
fig.text(.065,.033,'Source: supplied benchmark timings. Exact values shown beside each bar.',
         color=muted,fontsize=9,fontproperties=sans)
out=args.output_dir
out.mkdir(parents=True, exist_ok=True)
for ext in ['png','svg']:
    fig.savefig(out/f'benchmark-comparison-dark.{ext}',facecolor=bg,dpi=180)
plt.close(fig)
font_temp.cleanup()
print(out/'benchmark-comparison-dark.png')
print(out/'benchmark-comparison-dark.svg')
