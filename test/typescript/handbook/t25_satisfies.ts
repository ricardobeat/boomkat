// satisfies: constrains a literal to a type while keeping its inferred
// narrow shape, including nested satisfies and satisfies + as const.
type Routes = Record<string, { path: string; secure?: boolean }>;
const routes = {
  home: { path: "/", secure: false },
  admin: { path: "/admin", secure: true },
} satisfies Routes;
type Conf = {
  themes: readonly string[];
  port: number;
};
const conf = {
  themes: ["light", "dark"] as const,
  port: 8080,
} satisfies Conf;
const nested = { list: [1, 2] as const } satisfies { list: readonly number[] };
console.log(routes.home.path, routes.admin.secure);
console.log(conf.themes[1], conf.port, conf.themes.length);
console.log(nested.list[0] + nested.list[1]);
