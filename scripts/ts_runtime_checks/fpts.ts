import { pipe } from "fp-ts/function";
import * as O from "fp-ts/Option";
import * as E from "fp-ts/Either";
import * as A from "fp-ts/Array";

const log: string[] = [];

// pipe + Option map / getOrElse
log.push("r1=" + pipe(
  O.some(10),
  O.map((n) => n * 2),
  O.getOrElse(() => 0),
));

// none flows through flatMap
log.push("r2=" + pipe(
  O.none,
  O.flatMap(() => O.some(1)),
  O.getOrElse(() => -1),
));

// nested some
log.push("r3=" + pipe(
  O.some(3),
  O.flatMap((n) => O.some(n + 4)),
  O.fold(() => 0, (v) => v),
));

// Either right/map
log.push("e1=" + pipe(
  E.right(5),
  E.map((n) => n + 1),
  E.getOrElse(() => -1),
));

// Either left short-circuits
log.push("e2=" + pipe(
  E.left("no"),
  E.flatMap(() => E.right(99)),
  E.getOrElse(() => 0),
));

// Array filter / head / init
const evens = pipe([1, 2, 3, 4, 5, 6], A.filter((n) => n % 2 === 0));
log.push("evens=" + evens.join(","));

log.push("head=" + pipe([7, 8, 9], A.head, O.getOrElse(() => 0)));
log.push("init=" + pipe([1, 2, 3], A.init, O.map((xs) => xs.join("+")), O.getOrElse(() => "empty")));

// Array traversal with an Option-returning function
const over = pipe([1, 2, 3, 4], A.traverse(O.Applicative)((n) => (n % 2 === 0 ? O.some(n * 10) : O.none)));
log.push("traverse=" + pipe(over, O.fold(() => "none", (xs) => xs.join(","))));

for (const line of log) console.log(line);