/* Extract integer CELT mode data from the normative BSD RFC6716 archive. */
'use strict';
const fs=require('fs'),path=require('path');
const args=process.argv.slice(2),check=args.includes('--check');
const root=path.resolve(__dirname,'..'),ref=path.resolve(args.find(x=>!x.startsWith('--'))||path.join(__dirname,'reference','opus-rfc6716'));
const tables=[
 ['celt/modes.c','eband5ms','op_celt_ebands',22,'dw'],
 ['celt/modes.c','band_allocation','op_celt_alloc_vectors',231,'db'],
 ['celt/static_modes_float.h','logN400','op_celt_logn',21,'dw'],
 ['celt/static_modes_float.h','cache_index50','op_celt_cache_index',105,'dw'],
 ['celt/static_modes_float.h','cache_bits50','op_celt_cache_bits',392,'db'],
 ['celt/static_modes_float.h','cache_caps50','op_celt_cache_caps',168,'db']
];
let output='; Normative CELT integer mode data, extracted from the BSD RFC6716 reference.\n; Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation.\n; See THIRD_PARTY_NOTICES. No reference executable code.\n';
for(const [file,symbol,label,count,type]of tables){
 const text=fs.readFileSync(path.join(ref,file),'utf8');
 const match=new RegExp('\\b'+symbol+'\\s*\\[[^\\]]*\\]\\s*=\\s*\\{([\\s\\S]*?)\\};').exec(text);
 if(!match)throw Error('Missing '+symbol);
 const values=match[1].replace(/\/\*[\s\S]*?\*\//g,'').match(/-?\b\d+\b/g).map(Number);
 if(values.length!==count||values.some(x=>type==='db'?(x<0||x>255):(x< -32768||x>32767)))throw Error('Invalid '+symbol);
 for(let i=0;i<count;i+=16)output+=(i===0?label+' ':'    ')+type+' '+values.slice(i,i+16).join(',')+'\n';
}
const target=path.join(root,'src','opus_celt_tables.inc');
if(check){if(fs.readFileSync(target,'utf8').replace(/\r\n/g,'\n')!==output)throw Error('Committed CELT tables differ from the normative source');}
else fs.writeFileSync(target,output);
console.log((check?'Verified':'Extracted')+' six normative CELT integer mode tables.');
