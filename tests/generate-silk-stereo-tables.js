'use strict';
const {rows}=require('./asm-data');
const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..'),ref=path.resolve(process.argv[2]||path.join(__dirname,'reference','opus-rfc6716'));
let output='# RFC6716 SILK stereo data, IETF Trust/Skype2006-2012.\n# Generated data only; BSD conditions in THIRD_PARTY_NOTICES.\n';
const source=fs.readFileSync(path.join(ref,'silk','tables_other.c'),'utf8');
for(const [symbol,name,count,type] of [['silk_stereo_pred_quant_Q13','st_quant',16,'dw'],['silk_stereo_pred_joint_iCDF','st_joint',25,'db'],['silk_stereo_only_code_mid_iCDF','st_mid',2,'db'],['silk_uniform3_iCDF','st_uniform3',3,'db'],['silk_uniform5_iCDF','st_uniform5',5,'db']]){
 const at=source.search(new RegExp('\\b'+symbol+'\\s*\\['));if(at<0)throw Error('Missing '+symbol);
 const begin=source.indexOf('{',at),end=source.indexOf('};',begin);
 const values=source.slice(begin,end).replace(/\/\*[\s\S]*?\*\//g,'').match(/-?\d+/g).map(Number);
 if(values.length!==count||values.some(n=>n<(type==='db'?0:-32768)||n>(type==='db'?255:32767)))throw Error('Invalid '+symbol);
 output+=rows(name,type,values);
}
const destination=path.join(root,'src','opus_silk_stereo_tables.inc');
if(process.argv.includes('--check')){if(fs.readFileSync(destination,'utf8').replace(/\r\n/g,'\n')!==output)throw Error('SILK stereo tables differ');console.log('Verified five normative SILK stereo tables.');}
else {fs.writeFileSync(destination,output);console.log('Extracted five normative SILK stereo tables.');}
