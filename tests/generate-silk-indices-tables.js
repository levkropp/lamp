/* Extract integer probability/selector data from the verified RFC archive. */
'use strict';
const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..'),ref=path.resolve(process.argv[2]||path.join(__dirname,'reference','opus-rfc6716'));
const entries=[
 ['tables_other.c','silk_type_offset_VAD_iCDF','si_type_vad',4],
 ['tables_other.c','silk_type_offset_no_VAD_iCDF','si_type_no_vad',2],
 ['tables_other.c','silk_uniform4_iCDF','si_uniform4',4],
 ['tables_other.c','silk_uniform6_iCDF','si_uniform6',6],
 ['tables_other.c','silk_uniform8_iCDF','si_uniform8',8],
 ['tables_other.c','silk_NLSF_EXT_iCDF','si_nlsf_ext',7],
 ['tables_other.c','silk_NLSF_interpolation_factor_iCDF','si_nlsf_interp',5],
 ['tables_other.c','silk_LTPscale_iCDF','si_ltp_scale',3],
 ['tables_gain.c','silk_gain_iCDF','si_gain',24],
 ['tables_gain.c','silk_delta_gain_iCDF','si_delta_gain',41],
 ['tables_pitch_lag.c','silk_pitch_lag_iCDF','si_pitch_lag',32],
 ['tables_pitch_lag.c','silk_pitch_delta_iCDF','si_pitch_delta',21],
 ['tables_pitch_lag.c','silk_pitch_contour_iCDF','si_contour',34],
 ['tables_pitch_lag.c','silk_pitch_contour_NB_iCDF','si_contour_nb',11],
 ['tables_pitch_lag.c','silk_pitch_contour_10_ms_iCDF','si_contour10',12],
 ['tables_pitch_lag.c','silk_pitch_contour_10_ms_NB_iCDF','si_contour10_nb',3],
 ['tables_LTP.c','silk_LTP_per_index_iCDF','si_ltp_per',3],
 ...[8,16,32].map((n,i)=>['tables_LTP.c','silk_LTP_gain_iCDF_'+i,'si_ltp_gain'+i,n]),
 ...[['NB_MB','nb',160,18],['WB','wb',256,30]].flatMap(([tag,label,select,pred])=>[
  ['tables_NLSF_CB_'+tag+'.c','silk_NLSF_CB1_iCDF_'+tag,'si_cb1_'+label,64],
  ['tables_NLSF_CB_'+tag+'.c','silk_NLSF_CB2_SELECT_'+tag,'si_select_'+label,select],
  ['tables_NLSF_CB_'+tag+'.c','silk_NLSF_CB2_iCDF_'+tag,'si_cb2_'+label,72],
  ['tables_NLSF_CB_'+tag+'.c','silk_NLSF_PRED_'+tag+'_Q8','si_pred_'+label,pred]
 ])
];
let output='; Normative RFC6716 SILK data, copyright2006-2012 IETF Trust/Skype.\n; Generated integer data only; BSD conditions in THIRD_PARTY_NOTICES.\n';
for(const [file,symbol,label,count]of entries){
 const source=fs.readFileSync(path.join(ref,'silk',file),'utf8');
 const at=source.search(new RegExp('\\b'+symbol+'\\s*\\['));
 if(at<0)throw Error('Missing '+symbol);
 const begin=source.indexOf('{',at),end=source.indexOf('};',begin);
 const body=source.slice(begin,end).replace(/\/\*[\s\S]*?\*\//g,'').replace(/\/\/[^\n]*/g,'');
 const values=body.match(/-?\b\d+\b/g).map(Number);
 if(values.length!==count||values.some(n=>n<0||n>255))throw Error('Bad '+symbol+' count='+values.length);
 for(let i=0;i<count;i+=16)output+=(i===0?label+' ':'    ')+'db '+values.slice(i,i+16).join(',')+'\n';
}
output+='align 8\nsi_ltp_ptr dq si_ltp_gain0,si_ltp_gain1,si_ltp_gain2\n';
const destination=path.join(root,'src','opus_silk_indices_tables.inc');
if(process.argv.includes('--check')){
 if(fs.readFileSync(destination,'utf8').replace(/\r\n/g,'\n')!==output)throw Error('SILK side-information tables differ from normative source');
 console.log('Verified 28 normative SILK side-information tables.');
}else{fs.writeFileSync(destination,output);console.log('Extracted 28 normative SILK side-information tables.');}
