/* Generate src/mp3_tables.inc from dr_mp3 (MIT-0) data and exact float bit patterns.
   usage: node tests/generate-mp3-tables.js [dr_mp3.h] [--check] */
'use strict';
const fs=require('fs'),path=require('path');
const args=process.argv.slice(2),check=args.includes('--check');
const header=args.find(x=>!x.startsWith('--'))||path.join(__dirname,'reference','dr_mp3.h');
const source=fs.readFileSync(header,'utf8');
let text='# Data tables adapted from dr_mp3 by David Reid (MIT-0), based on minimp3 (CC0).\n# See THIRD_PARTY_NOTICES. No C implementation is linked into the player.\n';
function cArray(name){
 const match=new RegExp('\\b'+name.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'\\s*\\[[^;=]*=\\s*\\{([\\s\\S]*?)\\};').exec(source);
 if(!match)throw Error('Missing reference array '+name);
 return [...match[1].matchAll(/(?<![A-Za-z_])[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?[fF]?/g)].map(m=>m[0].replace(/[fF]+$/,''));
}
function emit(name,type,values){
 if(type==='DWORD')text+='.p2align 4\n';
 text+=name+':\n';
 const directive={BYTE:'.byte',WORD:'.short',DWORD:'.long'}[type];
 for(let i=0;i<values.length;i+=16)text+='    '+directive+' '+values.slice(i,i+16).join(', ')+'\n';
 text+='.equ '+name+'_count, '+values.length+'\n';
}
for(const [name,array,type]of[['mp_sfb_long','g_scf_long','BYTE'],['mp_sfb_short','g_scf_short','BYTE'],['mp_sfb_mixed','g_scf_mixed','BYTE'],['mp_huff_tabs','tabs','WORD'],['mp_huff_index','tabindex','WORD'],['mp_huff_linbits','g_linbits','BYTE'],['mp_count32','tab32','BYTE'],['mp_count33','tab33','BYTE'],['mp_partitions','g_scf_partitions','BYTE'],['mp_scfc','g_scfc_decode','BYTE'],['mp_mod','g_mod','BYTE'],['mp_preamp','g_preamp','BYTE']])
 emit(name,type,cArray(array));
const view=new DataView(new ArrayBuffer(4));
function floatBits(value){view.setFloat32(0,value);return '0x'+view.getUint32(0).toString(16).toUpperCase().padStart(8,'0');}
for(const [name,array]of[['mp_aa','g_aa'],['mp_pan','g_pan'],['mp_twid9','g_twid9'],['mp_mdct_win','g_mdct_window'],['mp_twid3','g_twid3'],['mp_synth_win','g_win'],['mp_dct_sec','g_sec']])
 emit(name,'DWORD',cArray(array).map(x=>floatBits(Number(x))));
emit('mp_pow43','DWORD',Array.from({length:8207},(_,i)=>floatBits(Math.pow(i,4/3))));
emit('mp_gain','DWORD',Array.from({length:901},(_,i)=>floatBits(Math.pow(2,(i-800)/4))));
const dct9=[];for(let i=0;i<9;i++)for(let j=0;j<9;j++)dct9.push(floatBits(Math.cos(Math.PI*j*(2*i+1)/18)));
emit('mp_dct9','DWORD',dct9);
const target=path.join(__dirname,'..','src','mp3_tables.inc');
if(check){
 const committed=fs.readFileSync(target,'utf8').replace(/\r\n/g,'\n').split('\n'),generated=text.split('\n');
 const differing=generated.filter((line,i)=>line!==committed[i]).length;
 if(committed.length!==generated.length||differing)throw Error(`MP3 tables differ from the reference (${differing} lines)`);
 console.log('Verified MP3 tables against dr_mp3 and exact float bit patterns.');
}else{fs.writeFileSync(target,text);console.log('Generated '+target);}
