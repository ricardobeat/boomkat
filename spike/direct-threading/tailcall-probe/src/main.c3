module tailtest;
import std::io;

alias HandlerFn = fn void(int*, int);

HandlerFn[2] handlers;

fn void handler_a(int* state, int n) {
    if (n <= 0) { io::printn("done a"); return; }
    *state += 1;
    handlers[1](state, n - 1);
}

fn void handler_b(int* state, int n) {
    if (n <= 0) { io::printn("done b"); return; }
    *state += 2;
    handlers[0](state, n - 1);
}

fn void main() {
    handlers[0] = &handler_a;
    handlers[1] = &handler_b;
    int state = 0;
    handler_a(&state, 100000000);
    io::printfn("state=%d", state);
}
