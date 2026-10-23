#!/usr/bin/env python3
"""Rebuild exact committed stages into isolated temporary worktrees; no suites."""
import argparse,hashlib,json,shutil,subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--worktrees',type=Path,default=Path('/private/tmp/boomkat-flat-mini-stages'))
 a=p.parse_args();rows=json.loads((HERE/'stages.json').read_text());(HERE/'bin').mkdir(exist_ok=True)
 for row in rows:
  worktree=a.worktrees/row['name'];revision=row['source_revision']
  if not worktree.exists():subprocess.run(['git','worktree','add','--detach',str(worktree),revision],cwd=ROOT,check=True)
  actual=subprocess.check_output(['git','rev-parse','HEAD'],cwd=worktree,text=True).strip()
  if actual!=revision:raise RuntimeError('unexpected worktree revision: '+str(worktree))
  subprocess.run(['git','diff','--exit-code','HEAD','--','src','cli','project.json','Makefile','scripts/build.py'],cwd=worktree,check=True,stdout=subprocess.DEVNULL)
  subprocess.run(['make','out/boomkat'],cwd=worktree,check=True)
  dest=HERE/'bin'/row['name'];shutil.copy2(worktree/'out/boomkat',dest)
  row.update(worktree=str(worktree),binary=str(dest),binary_bytes=dest.stat().st_size,binary_sha256=hashlib.sha256(dest.read_bytes()).hexdigest(),build_command='make -C '+str(worktree)+' out/boomkat')
 (HERE/'stages.json').write_text(json.dumps(rows,indent=2)+'\n')
if __name__=='__main__':main()
