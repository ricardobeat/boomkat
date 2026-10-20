var rows = [{id:1, name:"one"}, {id:2, name:"two"}];
function render(items) {
    let html = "";
    for (let i = 0; i < items.length; i++) {
        const item = items[i];
        html += `<li>${item.id}:${item.name}</li>`;
    }
    return html;
}
