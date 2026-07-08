type Cfg = { host: string; port: number };
let c = { host: "localhost", port: 80 } satisfies Cfg;
print(c.host);
print(c.port);
