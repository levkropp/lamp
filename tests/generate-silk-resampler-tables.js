'use strict';
const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..'),ref=path.resolve(process.argv[2]||path.join(__dirname,'reference','opus-rfc6716'));
let output='; Normative RFC6716 SILK decoder resampling data, IETF Trust/Skype2006-2012.\n; Generated data only; BSD conditions in THIRD_PARTY_NOTICES.\n';
for(const [file,symbol,label,count,type]of[
 ['resampler_rom.c','silk_resampler_up2_hq_0','sr_up0',3,'dw'],
 ['resampler_rom.c','silk_resampler_up2_hq_1','sr_up1',3,'dw'],
 ['resampler_rom.c','silk_Resampler_3_4_COEFS','sr_down34',29,'dw'],
 ['resampler_rom.c','silk_Resampler_2_3_COEFS','sr_down23',20,'dw'],
 ['resampler_rom.c','silk_Resampler_1_2_COEFS','sr_down12',14,'dw'],
 ['resampler_rom.c','silk_resampler_frac_FIR_12','sr_frac',48,'dw'],
 ['resampler.c','delay_matrix_dec','sr_delay',15,'db']
]){
 const source=fs.readFileSync(path.join(ref,'silk',file),'utf8');
 const at=source.search(new RegExp('\\b'+symbol+'\\s*\\['));if(at<0)throw Error('Missing '+symbol);
 const start=source.indexOf('{',at),end=source.indexOf('};',start);
 const terms=source.slice(start+1,end).replace(/\/\*[\s\S]*?\*\//g,'').replace(/[{}]/g,'').split(',').map(s=>s.trim()).filter(Boolean);
 const values=terms.map(term=>{
  if(!/^-?\d+(?:\s*-\s*\d+)?$/.test(term))throw Error('Unrecognized integer expression '+term);
  const m=term.match(/^(-?\d+)(?:\s*-\s*(\d+))?$/);return Number(m[1])-Number(m[2]||0);
 });
 if(values.length!==count||values.some(n=>n<(type==='db'?0:-32768)||n>(type==='db'?255:32767)))throw Error('Invalid '+symbol);
 for(let i=0;i<count;i+=16)output+=(i===0?label+' ':'    ')+type+' '+values.slice(i,i+16).join(',')+'\n';
}
const destination=path.join(root,'src','opus_silk_resampler_tables.inc');
if(process.argv.includes('--check')){
 if(fs.readFileSync(destination,'utf8').replace(/\r\n/g,'\n')!==output)throw Error('SILK resampling tables differ from normative source');
 console.log('Verified seven normative SILK decoder resampling tables.');
}else{fs.writeFileSync(destination,output);console.log('Extracted seven normative SILK decoder resampling tables.');}
