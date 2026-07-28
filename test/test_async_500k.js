async function step(n) {
    return await Promise.resolve(n);
}

async function run(count) {
    for (let i = 0; i < count; i++) {
        await step(i);
    }
    print("FINISHED " + count + " ASYNC CALLS SUCCESSFULLY");
}

run(500000);
