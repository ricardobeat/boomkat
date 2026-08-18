class Ghost {
  haunt(...places) { return places.map(p => `👻 boo! haunting ${p}...`); }
}

console.log(new Ghost().haunt("the attic", "the basement") ?? "no ghosts here");
