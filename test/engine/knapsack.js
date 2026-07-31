// Knapsack problem (0/1)
// Branch-and-bound DP solution.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function knapsack01(capacity, weights, values, n) {
    var dp = [];
    for (var i = 0; i <= n; i++) {
        dp.push(new Array(capacity + 1));
        for (var w = 0; w <= capacity; w++) dp[i][w] = 0;
    }
    for (var i = 1; i <= n; i++) {
        for (var w = 0; w <= capacity; w++) {
            var prev = dp[i - 1][w];
            if (weights[i - 1] <= w) {
                var take = values[i - 1] + dp[i - 1][w - weights[i - 1]];
                dp[i][w] = prev > take ? prev : take;
            } else {
                dp[i][w] = prev;
            }
        }
    }
    return dp[n][capacity];
}

var w1 = [2, 3, 4, 5];
var v1 = [3, 4, 5, 6];
assert(knapsack01(5, w1, v1, 4) === 7, "knapsack(5) = 7");

var w2 = [1, 3, 4, 5];
var v2 = [1, 4, 5, 7];
assert(knapsack01(7, w2, v2, 4) === 9, "knapsack(7) = 9");

var w3 = [10, 20, 30];
var v3 = [60, 100, 120];
assert(knapsack01(50, w3, v3, 3) === 220, "knapsack(50) = 220");

// Unbounded knapsack: items can be reused
function knapsackUnbounded(capacity, weights, values, n) {
    var dp = new Array(capacity + 1);
    for (var i = 0; i <= capacity; i++) dp[i] = 0;
    for (var w = 1; w <= capacity; w++) {
        for (var i = 0; i < n; i++) {
            if (weights[i] <= w) {
                var cand = dp[w - weights[i]] + values[i];
                if (cand > dp[w]) dp[w] = cand;
            }
        }
    }
    return dp[capacity];
}

assert(knapsackUnbounded(10, [1, 3, 4, 5], [1, 4, 5, 7], 4) === 14, "unbounded(10) = 14");

print("engine/knapsack: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");