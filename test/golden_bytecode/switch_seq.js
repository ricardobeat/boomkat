// switch case dispatch uses SEQ+IF_TRUE → JMP_SEQ (the compaction-remap regression case)
function pick(x){ switch(x){ case 1: return "a"; case 2: return "b"; default: return "d"; } }
print(pick(1), pick(2), pick(3));
