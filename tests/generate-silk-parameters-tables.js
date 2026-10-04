'use strict';
const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..'),ref=path.resolve(process.argv[2]||path.join(__dirname,'reference','opus-rfc6716'));
const entries=[
 ...[8,16,32].map((n,i)=>['tables_LTP.c','silk_LTP_gain_vq_'+i,'sp_ltp'+i,n*5,'db',-128,127]),
 ['tables_other.c','silk_LTPScales_table_Q14','sp_scales',3,'dw',0,32767],
 ['pitch_est_tables.c','silk_CB_lags_stage2_10_ms','sp_contour10_nb',6,'db',-128,127],
 ['pitch_est_tables.c','silk_CB_lags_stage3_10_ms','sp_contour10',24,'db',-128,127],
 ['pitch_est_tables.c','silk_CB_lags_stage2','sp_contour_nb',44,'db',-128,127],
 ['pitch_est_tables.c','silk_CB_lags_stage3','sp_contour',136,'db',-128,127]
];
let output='; Normative RFC6716 SILK reconstruction data, IETF Trust/Skype2006-2012.\n; Integer data only, BSD conditions in THIRD_PARTY_NOTICES.\n';
for(const [file,symbol,label,count,type,min,max]of entries){
 const source=fs.readFileSync(path.join(ref,'silk',file),'utf8');
 const at=source.search(new RegExp('\\b'+symbol+'\\s*\\['));
 if(at<0)throw Error('Missing '+symbol);
 const begin=source.indexOf('{',at),end=source.indexOf('};',begin);
 const body=source.slice(begin,end).replace(/\/\*[\s\S]*?\*\//g,'').replace(/\/\/[^\n]*/g,'');
 const values=body.match(/-?\b\d+\b/g).map(Number);
 if(values.length!==count||values.some(n=>n<min||n>max))throw Error('Bad '+symbol+' count='+values.length);
 for(let i=0;i<count;i+=16)output+=(i===0?label+' ':'    ')+type+' '+values.slice(i,i+16).join(',')+'\n';
}
output+='align 8\nsp_ltp_ptr dq sp_ltp0,sp_ltp1,sp_ltp2\n';
const destination=path.join(root,'src','opus_silk_parameters_tables.inc');
if(process.argv.includes('--check')){
 if(fs.readFileSync(destination,'utf8').replace(/\r\n/g,'\n')!==output)throw Error('SILK reconstruction tables differ from normative source');
 console.log('Verified eight normative SILK pitch/LTP reconstruction tables.');
}else{fs.writeFileSync(destination,output);console.log('Extracted eight normative SILK pitch/LTP reconstruction tables.');}
// Unchanged voiced/nonvoiced reconstruction decisions, test-only.
const source=fs.readFileSync(path.join(ref,'silk','decode_parameters.c'),'utf8');
const begin=source.indexOf('    if( psDec->indices.signalType == TYPE_VOICED )');
const end=source.lastIndexOf('}');
if(begin<0||end<=begin)throw Error('Missing normative pitch/LTP reconstruction');
const oracle=`/* Extracted unchanged RFC6716 decode_parameters.c pitch/LTP block. Test-only BSD reference. */
static void reference_pitch_ltp(silk_decoder_state *psDec,silk_decoder_control *psDecCtrl){
 opus_int i,k,Ix;const opus_int8 *cbk_ptr_Q7;
${source.slice(begin,end)}
}
`;
fs.mkdirSync(path.join(root,'bin'),{recursive:true});
fs.writeFileSync(path.join(root,'bin','silk-pitch-ltp-reference.inc'),oracle);
