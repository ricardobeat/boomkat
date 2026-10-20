// Virtual DOM simulation — 60fps allocation churn.
// Each frame allocates a full component tree (the expensive part in real
// virtual DOM frameworks). Measures peak RSS under sustained object churn.

var FRAMES = typeof VDOM_FRAMES_OVERRIDE === "number" ? VDOM_FRAMES_OVERRIDE : 60;
var COMPONENTS = typeof VDOM_COMPONENTS_OVERRIDE === "number" ? VDOM_COMPONENTS_OVERRIDE : 15;
var LIST_SIZE = typeof VDOM_LIST_SIZE_OVERRIDE === "number" ? VDOM_LIST_SIZE_OVERRIDE : 8;

function renderItem(compId, idx, frame) {
    return {
        type: "li",
        id: "item-" + compId + "-" + idx,
        cls: "item active-" + (frame % 3),
        text: "Item " + idx + " v" + frame,
        checked: (idx % 2) === 0
    };
}

function renderList(compId, frame) {
    var items = [];
    var i = 0;
    while (i < LIST_SIZE) {
        items.push(renderItem(compId, i, frame));
        i = i + 1;
    }
    return { type: "ul", id: "list-" + compId, cls: "list", children: items };
}

function renderHeader(compId, frame) {
    return {
        type: "h2",
        id: "hdr-" + compId,
        cls: "header variant-" + (frame % 4),
        text: "Component " + compId
    };
}

function renderComponent(id, frame) {
    return {
        type: "div",
        id: "comp-" + id,
        cls: "component frame-" + (frame % 4),
        frame: frame,
        header: renderHeader(id, frame),
        list: renderList(id, frame)
    };
}

// Simple diff: count how many nodes changed cls vs previous frame
function countChanges(prev, curr) {
    var n = 0;
    if (prev.cls !== curr.cls) n = n + 1;
    if (prev.header.cls !== curr.header.cls) n = n + 1;
    if (prev.list.cls !== curr.list.cls) n = n + 1;
    var len = prev.list.children.length;
    var i = 0;
    while (i < len) {
        if (prev.list.children[i].cls !== curr.list.children[i].cls) n = n + 1;
        i = i + 1;
    }
    return n;
}

// Simulate an event queue
var eventQueue = [];
function enqueueEvent(frame, compId) {
    var kinds = ["click", "focus", "blur", "input", "change"];
    eventQueue.push({ kind: kinds[compId % 5], target: "comp-" + compId, frame: frame });
    if (eventQueue.length > 20) {
        var trimmed = [];
        var i = eventQueue.length - 20;
        while (i < eventQueue.length) {
            trimmed.push(eventQueue[i]);
            i = i + 1;
        }
        eventQueue = trimmed;
    }
}

// Frame loop
var totalChanges = 0;
var prev = [];
var i = 0;
while (i < COMPONENTS) {
    prev.push(renderComponent(i, 0));
    i = i + 1;
}

var measureFrames = typeof VDOM_TIMING_OVERRIDE !== "undefined" && VDOM_TIMING_OVERRIDE;
var frameStart = measureFrames ? Date.now() : 0;
var worstFrame = 0;
var frame = 1;
while (frame <= FRAMES) {
    var frameTime = measureFrames ? Date.now() : 0;
    var j = 0;
    while (j < COMPONENTS) {
        var curr = renderComponent(j, frame);
        totalChanges = totalChanges + countChanges(prev[j], curr);
        prev[j] = curr;
        enqueueEvent(frame, j);
        j = j + 1;
    }
    if (measureFrames) {
        var frameElapsed = Date.now() - frameTime;
        if (frameElapsed > worstFrame) worstFrame = frameElapsed;
    }
    frame = frame + 1;
}
if (measureFrames) print("vdom_churn: total=" + (Date.now() - frameStart)
    + "ms worst_frame=" + worstFrame + "ms");

print("frames: " + FRAMES);
print("components: " + COMPONENTS);
print("total changes: " + totalChanges);
print("event queue: " + eventQueue.length);
