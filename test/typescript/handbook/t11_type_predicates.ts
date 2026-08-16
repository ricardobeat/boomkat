// Type predicates (`x is T`) in a standalone function and as an arrow,
// filtering a mixed array down to one element type.
interface Fish {
  swim(): string;
}
interface Bird {
  fly(): string;
}
function isFish(pet: Fish | Bird): pet is Fish {
  return "swim" in pet;
}
const isBird = (pet: Fish | Bird): pet is Bird => "fly" in pet;
const pond: (Fish | Bird)[] = [
  { fly: () => "flap" },
  { swim: () => "splash" },
  { fly: () => "glide" },
];
const swimmers = pond.filter(isFish);
const fliers = pond.filter(isBird);
console.log(isFish(pond[0]), isFish(pond[1]));
console.log(swimmers.length, fliers.length, fliers[1].fly());
