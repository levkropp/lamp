'use strict';
// GNU as data directives in the committed table style of src/*.inc.
const directives = {db: '.byte', dw: '.short', dd: '.long', dq: '.quad', real4: '.float', real8: '.double'};
function rows(label, type, values, width = 16) {
    let output = '';
    for (let i = 0; i < values.length; i += width)
        output += (i === 0 ? label + ': ' : '    ') + directives[type] + ' ' + values.slice(i, i + width).join(', ') + '\n';
    return output;
}
module.exports = {rows, directives};
