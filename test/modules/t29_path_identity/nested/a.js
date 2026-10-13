import { AppError, state } from "../shared.js";
export function visit() { state.visits++; return new AppError("shared"); }
