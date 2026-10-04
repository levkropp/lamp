/* Extract exact decimal float/bit-reversal data from normative BSD RFC6716. */
'use strict';
const fs=require('fs'),path=require('path'),args=process.argv.slice(2),check=args.includes('--check');
const root=path.resolve(__dirname,'..'),ref=args.find(x=>!x.startsWith('--'));
const source=fs.readFileSync(path.join(ref,'celt','static_modes_float.h'),'utf8');
function array(symbol,count,type){
 const match=new RegExp('\\b'+symbol+'\\s*\\[[^\\]]*\\]\\s*=\\s*\\{([\\s\\S]*?)\\};').exec(source);
 if(!match)throw Error('Missing '+symbol);
 const body=match[1].replace(/\/\*[\s\S]*?\*\//g,'');
 const values=type==='real4'?body.match(/[-+]?\d+(?:\.\d*)?(?:e[-+]?\d+)?f/gi).map(x=>x.slice(0,-1)):body.match(/-?\b\d+\b/g);
 if(values.length!==count)throw Error('Wrong count '+symbol+': '+values.length);return values;
}
function emit(label,type,values){let output='';for(let i=0;i<values.length;i+=8)output+=(i===0?label+' ':'    ')+type+' '+values.slice(i,i+8).join(',')+'\n';return output;}
const notice='; Normative RFC6716 transform data (BSD), see THIRD_PARTY_NOTICES.\n; Copyright (c) 2011-2012 IETF Trust, CSIRO, Xiph.Org Foundation.\n';
let fft=notice+emit('of_twiddles','real4',array('fft_twiddles48000_960',960,'real4'));
for(let lm=0;lm<4;lm++){
 const shift=3-lm,nfft=60<<lm;
 fft+=emit('of_bitrev'+lm,'dw',array('fft_bitrev'+nfft,nfft,'dw'));
 const state=new RegExp('fft_state48000_960_'+shift+'\\s*=\\s*\\{([\\s\\S]*?)\\};').exec(source);
 if(!state)throw Error('Missing FFT state');
 const factors=/\{([^}]+)\}/.exec(state[1])[1].match(/\d+/g).map(Number),stages=[];
 let stride=1;for(let i=0;factors[2*i];i++){const p=factors[2*i],m=factors[2*i+1];stages.push([p,m,stride,i?factors[2*i-1]:1,stride<<shift,(stride<<shift)*m,(stride<<shift)*m*2,0]);stride*=p;}
 if(stride!==nfft)throw Error('Wrong FFT factors');
 fft+='ALIGN 16\nof_stages'+lm+' LABEL DWORD\n';for(const stage of stages.reverse())fft+='    dd '+stage.join(',')+'\n';fft+='    dd 0,0,0,0,0,0,0,0\n';
}
fft+='of_bitrev_ptrs dq of_bitrev0,of_bitrev1,of_bitrev2,of_bitrev3\nof_stage_ptrs dq of_stages0,of_stages1,of_stages2,of_stages3\n';
let mdct=notice+emit('om_window','real4',array('window120',120,'real4'))+emit('om_trig','real4',array('mdct_twiddles960',481,'real4'));
const pi=Math.fround(3.141592653),sines=[];
for(let lm=0;lm<4;lm++)sines.push(Math.fround(Math.fround(Math.fround(2*pi)*.125)/(240<<lm)).toExponential(9));
mdct+=emit('om_sines','real4',sines);
for(const [name,output]of [['opus_fft_tables.inc',fft],['opus_mdct_tables.inc',mdct]]){
 const target=path.join(root,'src',name);
 if(check){if(fs.readFileSync(target,'utf8').replace(/\r\n/g,'\n')!==output)throw Error('Transform tables differ: '+name);}
 else fs.writeFileSync(target,output);
}
console.log((check?'Verified':'Extracted')+' normative CELT FFT/MDCT/window tables.');
const celt=fs.readFileSync(path.join(ref,'celt','celt.c'),'utf8');
const start=celt.indexOf('static void compute_inv_mdcts('),brace=celt.indexOf('{',start);let depth=1,end=brace+1;
while(depth&&end<celt.length){if(celt[end]==='{')depth++;if(celt[end]==='}')depth--;end++;}
if(start<0||depth)throw Error('Missing inverse synthesis reference');
fs.mkdirSync(path.join(root,'bin'),{recursive:true});
fs.writeFileSync(path.join(root,'bin','celt-synthesis-reference.inc'),'/* Unchanged normative BSD RFC6716 inverse synthesis helper, test-only. */\n'+celt.slice(start,end).replace('compute_inv_mdcts(','reference_synthesis('));
function helper(symbol){
 const symbolAt=celt.indexOf(symbol+'('),begin=celt.lastIndexOf('static ',symbolAt),brace=celt.indexOf('{',symbolAt);let depth=1,end=brace+1;
 while(depth&&end<celt.length){if(celt[end]==='{')depth++;if(celt[end]==='}')depth--;end++;}
 if(symbolAt<0||begin<0||depth)throw Error('Missing '+symbol);return celt.slice(begin,end);
}
fs.writeFileSync(path.join(root,'bin','celt-filter-reference.inc'),'/* Unchanged normative BSD RFC6716 output helpers, test-only. */\n'+helper('SIG2WORD16')+'\n'+helper('comb_filter').replace('comb_filter(','reference_comb(')+'\n'+helper('deemphasis').replace('deemphasis(','reference_deemphasis('));
