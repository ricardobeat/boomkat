import { AppError, state } from "./shared.js";
import { visit } from "./nested/a.js";
import { AppError as Other, state as otherState } from "./nested/../nested//b.js";
const error = visit();
if (Other !== AppError || !(error instanceof Other) || state !== otherState || state.visits !== 1)
    throw new Error("relative paths duplicated module state or class identity");
const dynamic = await import("./nested/../shared.js");
if (dynamic.AppError !== AppError || dynamic.state !== state)
    throw new Error("dynamic import duplicated module");
// Parent traversal preserves the entry point's relative prefix.
const parent = await import("../t29_path_identity/./shared.js");
if (parent.state !== state) throw new Error("parent traversal duplicated module");
