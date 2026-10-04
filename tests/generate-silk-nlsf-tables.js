'use strict';
const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..'),ref=path.resolve(process.argv[2]||path.join(__dirname,'reference','opus-rfc6716'));
let output='; Normative RFC6716 SILK NLSF data, IETF Trust/Skype2006-2012.\n; Generated data only; BSD conditions in THIRD_PARTY_NOTICES.\n';
for(const [tag,label,order]of[['NB_MB','nb',10],['WB','wb',16]]){
 const source=fs.readFileSync(path.join(ref,'silk','tables_NLSF_CB_'+tag+'.c'),'utf8');
 for(const [symbol,name,count,type]of[
  ['silk_NLSF_CB1_'+tag+'_Q8','sn_cb_'+label,32*order,'db'],
  ['silk_NLSF_DELTA_MIN_'+tag+'_Q15','sn_delta_'+label,order+1,'dw']
 ]){
  const at=source.search(new RegExp('\\b'+symbol+'\\s*\\['));
  if(at<0)throw Error('Missing '+symbol);
  const begin=source.indexOf('{',at),end=source.indexOf('};',begin);
  const values=source.slice(begin,end).replace(/\/\*[\s\S]*?\*\//g,'').match(/\b\d+\b/g).map(Number);
  if(values.length!==count||values.some(n=>n<0||n>(type==='db'?255:32767)))throw Error('Bad '+symbol);
  for(let i=0;i<count;i+=16)output+=(i===0?name+' ':'    ')+type+' '+values.slice(i,i+16).join(',')+'\n';
 }
 const quant=source.match(/SILK_FIX_CONST\(\s*([\d.]+)\s*,\s*16\s*\)/);
 if(!quant)throw Error('Missing quantization step '+tag);
 output+='sn_step_'+label+' EQU '+Math.floor(Number(quant[1])*65536+.5)+'\n';
}
const destination=path.join(root,'src','opus_silk_nlsf_tables.inc');
if(process.argv.includes('--check')){
 if(fs.readFileSync(destination,'utf8').replace(/\r\n/g,'\n')!==output)throw Error('SILK NLSF data differs from normative source');
 console.log('Verified four normative SILK NLSF tables and two quantization steps.');
}else{fs.writeFileSync(destination,output);console.log('Extracted four normative SILK NLSF tables and two quantization steps.');}
