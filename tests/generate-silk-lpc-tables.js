'use strict';
const {rows}=require('./asm-data');
const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..'),ref=path.resolve(process.argv[2]||path.join(__dirname,'reference','opus-rfc6716'));
let output='# Normative RFC6716 SILK LPC data, IETF Trust/Skype2006-2012.\n# Generated data only; BSD conditions in THIRD_PARTY_NOTICES.\n';
for(const [file,symbol,name,count,type]of[
 ['table_LSF_cos.c','silk_LSFCosTab_FIX_Q12','sl_cos',129,'dw'],
 ['NLSF2A.c','ordering10','sl_order10',10,'db'],
 ['NLSF2A.c','ordering16','sl_order16',16,'db']
]){
 const source=fs.readFileSync(path.join(ref,'silk',file),'utf8');
 const at=source.search(new RegExp('\\b'+symbol+'\\s*\\['));
 if(at<0)throw Error('Missing '+symbol);
 const begin=source.indexOf('{',at),end=source.indexOf('};',begin);
 const values=source.slice(begin,end).replace(/\/\*[\s\S]*?\*\//g,'').match(/-?\d+/g).map(Number);
 if(values.length!==count||values.some(n=>n<(type==='db'?0:-32768)||n>(type==='db'?255:32767)))throw Error('Invalid '+symbol);
 output+=rows(name,type,values);
}
const destination=path.join(root,'src','opus_silk_lpc_tables.inc');
if(process.argv.includes('--check')){
 if(fs.readFileSync(destination,'utf8').replace(/\r\n/g,'\n')!==output)throw Error('SILK LPC tables differ from normative source');
 console.log('Verified three normative SILK LPC tables.');
}else{fs.writeFileSync(destination,output);console.log('Extracted three normative SILK LPC tables.');}
