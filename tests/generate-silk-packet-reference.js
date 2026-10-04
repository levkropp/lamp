'use strict';
const fs=require('fs'),path=require('path');
const ref=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]);
const tables=fs.readFileSync(path.join(ref,'silk','tables_other.c'),'utf8');
let generated='; RFC6716 SILK LBRR flag data, IETF Trust/Skype2006-2012.\n; Verified against tables_other.c; BSD conditions in THIRD_PARTY_NOTICES.\n';
for(const [symbol,label,size]of[['silk_LBRR_flags_2_iCDF','ph_lbrr2',3],['silk_LBRR_flags_3_iCDF','ph_lbrr3',7]]){
 const at=tables.search(new RegExp('\\b'+symbol+'\\s*\\['));if(at<0)throw Error('Missing '+symbol);
 const begin=tables.indexOf('{',at),end=tables.indexOf('};',begin),values=tables.slice(begin,end).match(/\d+/g).map(Number);
 if(values.length!==size||values.some(n=>n<0||n>255))throw Error('Invalid '+symbol);generated+=label+' db '+values.join(',')+'\n';
}
const assembly=fs.readFileSync(path.join(__dirname,'..','src','opus_silk_packet_tables.inc'),'utf8').replace(/\r\n/g,'\n');
if(assembly!==generated)throw Error('SILK LBRR data differs from normative reference');
const source=fs.readFileSync(path.join(ref,'silk','dec_API.c'),'utf8');
const at=source.indexOf('    if( lostFlag != FLAG_PACKET_LOST && channel_state[ 0 ].nFramesDecoded == 0 )');
if(at<0)throw Error('Missing normative packet header');
const start=source.indexOf('{',at);let depth=1,end=start+1;
for(;depth&&end<source.length;end++){if(source[end]==='{')depth++;else if(source[end]==='}')depth--;}
if(depth)throw Error('Unbalanced normative header');
const body=source.slice(at,end);
const notice=source.slice(0,source.indexOf('*/')+2);
const code=notice+'\n/* Test-only unchanged packet-header block extracted from dec_API.c. */\n#include "API.h"\n#include "main.h"\nvoid lamp_silk_packet_reference(silk_decoder_state *channel_state,int channels,int lostFlag,ec_dec *psRangeDec){\n silk_DecControlStruct control={0},*decControl=&control;control.nChannelsInternal=channels;\n opus_int i,n,decode_only_middle=0;opus_int32 LBRR_symbol,MS_pred_Q13[2]={0};\n'+body+'\n}\n';
fs.mkdirSync(path.dirname(out),{recursive:true});fs.writeFileSync(out,code);
console.log('Verified two LBRR tables; extracted unchanged normative packet-header block.');
