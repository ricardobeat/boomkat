// Rosetta-style async/await pipeline example
// Demonstrates chained async functions, await on Promise.resolve,
// and .then() resolution callbacks.

async function loadUser(id) {
    var name = await Promise.resolve("user_" + id);
    var roles = await Promise.resolve(["reader", "writer"]);
    var perms = [];
    for (var i = 0; i < roles.length; i++) {
        perms[i] = await Promise.resolve(roles[i] + "_perm");
    }
    return { id: id, name: name, roles: roles, perms: perms };
}

var result = loadUser(42);
print("is Promise: " + (result instanceof Promise));

result.then(function(user) {
    print("id: " + user.id);
    print("name: " + user.name);
    print("roles: " + user.roles.join(","));
    print("perms: " + user.perms.join(","));
    print("pipeline complete");
});
