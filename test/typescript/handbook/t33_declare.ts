// Ambient declarations: declare var/let/const, declare function, declare
// class, declare enum, and declare namespace. All erased at runtime; the
// declared names are provided by the host below each declaration.
declare var VERSION: string;
declare let counter: number;
declare const MAX: number;
declare function hostAdd(a: number, b: number): number;
declare class HostError extends Error {}
declare enum Mode { On, Off }
declare namespace Ambient {
  const name: string;
  function run(): number;
}
var VERSION = "1.2.3";
var counter = 9;
var MAX = 100;
function hostAdd(a: number, b: number): number {
  return a + b;
}
class HostError extends Error {}
var Mode;
(function (Mode) {
  Mode[(Mode["On"] = 0)] = "On";
  Mode[(Mode["Off"] = 1)] = "Off";
})(Mode || (Mode = {}));
var Ambient;
(function (Ambient) {
  Ambient.name = "amb";
  Ambient.run = () => 5;
})(Ambient || (Ambient = {}));
console.log(VERSION, counter, MAX, hostAdd(2, 3));
console.log(new HostError("x").message, Mode.Off, Ambient.name, Ambient.run());
