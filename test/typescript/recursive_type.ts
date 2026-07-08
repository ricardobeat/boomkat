type Node = { value: number; next: Node | null };
let list: Node = { value: 1, next: { value: 2, next: { value: 3, next: null } } };
let cur: Node | null = list;
let sum = 0;
while (cur !== null) {
    sum += cur.value;
    cur = cur.next;
}
print(sum);
