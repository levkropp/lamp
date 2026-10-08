/* Extract integer probability data only. No compiler-generated codec code. */
'use strict';
const fs=require('fs'),path=require('path');
const {rows}=require('./asm-data');
const root=path.resolve(__dirname,'..');
const ref=path.resolve(process.argv[2]||path.join(__dirname,'reference','opus-rfc6716'));
const tables=[
 ['silk/tables_pulses_per_block.c','silk_pulses_per_block_iCDF','op_silk_sum_pdf',180],
 ['silk/tables_pulses_per_block.c','silk_rate_levels_iCDF','op_silk_rate_pdf',18],
 ...[0,1,2,3].map(i=>['silk/tables_pulses_per_block.c','silk_shell_code_table'+i,'op_silk_shell'+i,152]),
 ['silk/tables_pulses_per_block.c','silk_shell_code_table_offsets','op_silk_shell_offsets',17],
 ['silk/tables_pulses_per_block.c','silk_sign_iCDF','op_silk_sign_pdf',42],
 ['silk/tables_other.c','silk_lsb_iCDF','op_silk_lsb_pdf',2]
];
let output='# Probability data from the normative BSD-licensed RFC6716 reference.\n# Automatically extracted; see THIRD_PARTY_NOTICES.\n';
for(const [file,symbol,label,count]of tables){
 const text=fs.readFileSync(path.join(ref,file),'utf8');
 const at=text.indexOf(symbol+'[')>=0?text.indexOf(symbol+'['):text.indexOf(symbol+' [');
 if(at<0)throw Error('Missing symbol '+symbol);
 const begin=text.indexOf('{',at),end=text.indexOf('};',begin);
 const body=text.slice(begin,end).replace(/\/\*[\s\S]*?\*\//g,'');
 const values=body.match(/\b\d+\b/g).map(Number);
 if(values.length!==count||values.some(x=>x>255))throw Error('Invalid table '+symbol);
 output+=rows(label,'db',values);
}
output+='.p2align 3\nop_silk_shell_ptr: .quad op_silk_shell0, op_silk_shell1, op_silk_shell2, op_silk_shell3\n';
fs.writeFileSync(path.join(root,'src','opus_silk_tables.inc'),output);
console.log('Extracted nine normative SILK probability tables.');
