try {
    throw new Error("boom");
} catch (e: unknown) {
    if (e instanceof Error) print(e.message);
}
