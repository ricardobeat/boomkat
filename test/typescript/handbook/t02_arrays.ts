// Array types in both spellings, element access, and readonly arrays.
const nums: number[] = [1, 2, 3];
const words: Array<string> = ["a", "b"];
const grid: number[][] = [[1, 2], [3, 4]];
const locked: readonly number[] = [7, 8, 9];
nums.push(4);
words.push("c");
console.log(nums.join(","), words.join("|"));
console.log(grid[1][0], locked[2], nums.length);
