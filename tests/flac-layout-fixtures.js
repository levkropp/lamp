'use strict';
// Original RFC 9639 bitstream generator; FFmpeg independently checks lossless
// channel samples. Stereo expectations implement the documented rendering
// policy from speaker positions, independent of the assembly decoder.
const fs=require('fs'),path=require('path'),cp=require('child_process');
const [cli,probe,directory,bounds]=process.argv.slice(2).map(x=>path.resolve(x));
if(!bounds)throw Error('Supply CLI, seek oracle, generated directory and guarded-read oracle paths');
fs.mkdirSync(directory,{recursive:true});
function run(exe,args){const r=cp.spawnSync(exe,args,{encoding:'utf8',maxBuffer:8*1024*1024});if(r.error||r.status)throw Error(`${path.basename(exe)} ${args.join(' ')}: ${r.status} ${r.stderr||r.error} ${r.stdout}`);return r.stdout;}
function ff(args){return run('ffmpeg',['-hide_banner','-loglevel','error','-y',...args]);}
function crc(data,width){let c=0;const top=1<<(width-1),mask=(1<<width)-1,poly=width===8?7:0x8005;for(const b of data){c^=b<<(width-8);for(let i=0;i<8;i++)c=((c<<1)^((c&top)?poly:0))&mask;}return c;}
function coded(n){n=BigInt(n);if(n<128n)return Buffer.from([Number(n)]);let length=2;while(n>=(1n<<BigInt(length*5+1)))length++;const b=Buffer.alloc(length);for(let i=length-1;i;i--){b[i]=128|Number(n&63n);n>>=6n;}b[0]=((255<<(8-length))&255)|Number(n);return b;}
class Bits{
 constructor(){this.bytes=[];this.byte=0;this.count=0;}
 put(value,width){value=BigInt(value);for(let i=width-1;i>=0;i--){this.byte=(this.byte<<1)|Number((value>>BigInt(i))&1n);if(++this.count===8){this.bytes.push(this.byte);this.byte=0;this.count=0;}}}
 unary(n){for(let i=0;i<n;i++)this.put(0,1);this.put(1,1);}
 finish(){if(this.count)this.put(0,8-this.count);return Buffer.from(this.bytes);}
}
const defaults=[4,3,7,0x33,0x37,0x3f,0x70f,0x63f];
const q=Math.SQRT1_2,a=Math.sqrt(3)/2,r=Math.sqrt(3/8);
const weights=[[1,0],[0,1],[q,q],[q,q],[a,.5],[.5,a],[q,0],[0,q],[r,r],[a,.5],[.5,a],[.5,.5],[q,0],[.5,.5],[0,q],[r,q/2],[a/2,a/2],[q/2,r]];
function coefficients(channels,mask){
 const result=[];let l=0,h=0;for(let bit=0;bit<18;bit++)if(mask&(1<<bit)){const w=weights[bit];result.push(w.slice());l+=w[0];h+=w[1];}
 const scale=result.length?(result.length<=4?1:2)/Math.max(l,h):0;
 for(const w of result){w[0]*=scale;w[1]*=scale;}while(result.length<channels)result.push([0,0]);return result;
}
function expected(samples,depth,mask){
 const channels=samples.length,n=samples[0].length,b=Buffer.alloc(n*8),coeff=coefficients(channels,mask),scale=2**(1-depth);
 for(let i=0;i<n;i++){let l=0,r=0;for(let c=0;c<channels;c++){l+=Number(samples[c][i])*coeff[c][0];r+=Number(samples[c][i])*coeff[c][1];}b.writeFloatLE(l*scale,i*8);b.writeFloatLE(r*scale,i*8+4);}return b;
}
function comment(fields,vendor='LAMP test generator'){
 const strings=[Buffer.from(vendor),...fields.map(f=>Buffer.from(f))],len=n=>{const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;};
 return Buffer.concat([len(strings[0].length),strings[0],len(fields.length),...strings.slice(1).flatMap(b=>[len(b.length),b])]);
}
function metadata(type,payload,last){const h=Buffer.alloc(4);h[0]=type|(last?128:0);h.writeUIntBE(payload.length,1,3);return Buffer.concat([h,payload]);}
function subframe(bits,values,depth,spec){
 const type=spec.type??1,wasted=spec.wasted??0,order=type>=32?type-31:type>=8?type-8:0;
 bits.put(0,1);bits.put(type,6);bits.put(wasted?1:0,1);if(wasted)bits.unary(wasted-1);
 const samples=values.map(x=>x>>BigInt(wasted)),width=depth-wasted;
 if(type===0){bits.put(samples[0],width);return;}
 if(type===1){for(const s of samples)bits.put(s,width);return;}
 for(let i=0;i<order;i++)bits.put(samples[i],width);
 const fixed=[[],[1],[2,-1],[3,-3,1],[4,-6,4,-1]],coeff=type>=32?spec.coeff:fixed[order],shift=spec.shift??0;
 if(type>=32){bits.put((spec.precision??15)-1,4);bits.put(shift,5);for(const v of coeff)bits.put(v,spec.precision??15);}
 const method=spec.method??1,partition=spec.partition??0,k=spec.k??Math.max(0,Math.min(30,depth-1));
 bits.put(method,2);bits.put(partition,4);
 const count=samples.length/(1<<partition),escape=spec.escape;
 for(let p=0;p<(1<<partition);p++){
  bits.put(escape!==undefined?(method?31:15):k,method?5:4);if(escape!==undefined)bits.put(escape,5);
  for(let i=p*count+(p===0?order:0);i<(p+1)*count;i++){
   let prediction=0n;for(let j=0;j<order;j++)prediction+=BigInt(coeff[j])*samples[i-j-1];prediction>>=BigInt(shift);
   const residual=spec.badResidual??(samples[i]-prediction);
   if(escape!==undefined){bits.put(residual,escape);continue;}
   const folded=residual<0n?-2n*residual-1n:2n*residual;
   bits.unary(Number(folded>>BigInt(k)));bits.put(folded,k);
  }
 }
}
function make(spec){
 const C=spec.channels,D=spec.depth,N=spec.block??96,F=spec.frames??5,total=N*F,min=-(1n<<BigInt(D-1)),max=-min-1n;
 const samples=Array.from({length:C},(_,c)=>Array.from({length:total},(_,i)=>{
  if(spec.sample)return BigInt(spec.sample(i,c,min,max));
  if(spec.type===0||spec.constant)return c%2?min+1n:max;
  const edge=[min,max,0n,1n,-1n,min+1n,max-1n];if(i%11<edge.length)return edge[(i+c)%edge.length];
  return BigInt.asIntN(D,BigInt(Math.imul(i+17,c*971+1229))<<BigInt(Math.max(0,D-19)));
 }));
 const frames=[],points=[];let offset=0;
 for(let f=0;f<F;f++){
  const mode=spec.mode??C-1,depthCode=({8:1,12:2,16:4,20:5,24:6,32:7})[D]??0;
  const h=Buffer.concat([Buffer.from([255,spec.variable?249:248,0x70,(mode<<4)|(spec.inherit?0:depthCode<<1)]),coded(spec.variable?f*N:f),Buffer.from([(N-1)>>8,(N-1)&255])]);
  const b=new Bits(),v=samples.map(c=>c.slice(f*N,(f+1)*N));
  if(mode>=8){const l=v[0].slice(),r=v[1].slice();for(let i=0;i<N;i++){if(mode===8)v[1][i]=l[i]-r[i];if(mode===9)v[0][i]=l[i]-r[i];if(mode===10){v[0][i]=(l[i]+r[i])>>1n;v[1][i]=l[i]-r[i];}}}
  for(let c=0;c<C;c++)subframe(b,v[c],D+Number((mode===9&&c===0)||((mode===8||mode===10)&&c===1)),spec.perChannel?.[c]??spec);
  const body=Buffer.concat([h,Buffer.from([crc(h,8)]),b.finish()]),tail=Buffer.alloc(2);tail.writeUInt16BE(crc(body,16));const frame=Buffer.concat([body,tail]);
  if(f%2===0){const p=Buffer.alloc(18);p.writeBigUInt64BE(BigInt(f*N));p.writeBigUInt64BE(BigInt(offset),8);p.writeUInt16BE(N,16);points.push(p);}frames.push(frame);offset+=frame.length;
 }
 const info=Buffer.alloc(34);info.writeUInt16BE(N,0);info.writeUInt16BE(N,2);info.writeBigUInt64BE((48000n<<44n)|(BigInt(C-1)<<41n)|(BigInt(D-1)<<36n)|BigInt(total),10);
 const blocks=[[0,info]];if(spec.fields)blocks.push([4,comment(spec.fields)]);if(spec.extraMetadata)blocks.push(...spec.extraMetadata);if(spec.index)blocks.push([3,Buffer.concat(points)]);
 return {data:Buffer.concat([Buffer.from('fLaC'),...blocks.map(([t,b],i)=>metadata(t,b,i===blocks.length-1)),...frames]),samples,total,depth:D,mask:spec.mask??defaults[C-1]};
}
const results=[],rejections=[];
function verify(name,spec,independent=true){
 const made=spec.prepared??make(spec),file=path.join(directory,name+'.flac'),ours=file+'.ours.f32',pcm=file+'.expected.f32';fs.writeFileSync(file,made.data);
 const stereo=expected(made.samples,made.depth,made.mask);fs.writeFileSync(pcm,stereo);fs.rmSync(ours,{force:true});run(cli,['--decode',file,ours]);
 const actual=fs.readFileSync(ours);if(!actual.equals(stereo)){let at=0;while(at<actual.length&&actual[at]===stereo[at])at++;throw Error(`PCM mismatch ${name} byte ${at}, got ${actual.readFloatLE(at&~3)}, expected ${stereo.readFloatLE(at&~3)}`);}
 if(independent){
  const ref=file+'.reference.s32';ff(['-i',file,'-c:a','pcm_s32le','-f','s32le',ref]);const decoded=fs.readFileSync(ref),wanted=Buffer.alloc(made.total*spec.channels*4);
  for(let i=0;i<made.total;i++)for(let c=0;c<spec.channels;c++)wanted.writeInt32LE(Number(made.samples[c][i]<<BigInt(32-spec.depth)),(i*spec.channels+c)*4);
  if(!decoded.equals(wanted))throw Error('Independent lossless channel mismatch '+name);
 }
 const seek=JSON.parse(run(probe,[file,pcm,'0',String(spec.index?2*(spec.block??96):made.total)])),guard=bounds?JSON.parse(run(bounds,[file,pcm])):{};
 results.push({file:path.basename(file),channels:spec.channels,depth:spec.depth,mask:made.mask,frames:made.total,independent_channels:independent,...seek,...guard});
 if(results.length%40===0)console.log('Verified FLAC layout/depth files: '+results.length);
}
function reject(name,spec,mutate){
 const made=make(spec),file=path.join(directory,'bad-'+name+'.flac');fs.writeFileSync(file,mutate?mutate(made.data):made.data);
 const r=cp.spawnSync(cli,['--check',file],{encoding:'utf8'});if(r.status!==2||!(/decode_error=[1-9]/.test(r.stdout)||/Unsupported, malformed/.test(r.stdout)))throw Error('Malformed FLAC accepted '+name+' '+r.stdout+' '+r.stderr);
 rejections.push({file:path.basename(file),result:'rejected'});
}
for(let depth=4;depth<=32;depth++)for(let channels=1;channels<=8;channels++)verify(`depth-${depth}-channels-${channels}`,{depth,channels,index:depth%2===0,variable:depth%3===0});
for(const depth of [4,16,24,25,31,32])for(const mode of [8,9,10])verify(`stereo-${depth}-mode-${mode}`,{depth,channels:2,mode,index:true,variable:true});
for(const type of [0,8,9,10,11,12,32,33,34,35,63])for(const channels of [1,2,5,8]){
 const order=type>=32?type-31:Math.max(0,type-8),coeff=Array(order).fill(0);if(order)coeff[0]=1;
 if(order>=2){coeff[0]=16383;coeff[1]=-16382;}
 verify(`predictor-${type}-${channels}`,{depth:32,channels,type,constant:true,coeff,k:30,index:true,variable:true});
}
for(const method of [0,1])for(const escape of [0,15,31])verify(`escape-${method}-${escape}`,{depth:32,channels:8,type:10,constant:true,method,escape,partition:1,index:true});
for(const depth of [4,16,24,32])verify(`wasted-${depth}`,{depth,channels:8,wasted:depth-2,sample:(i,c)=>BigInt((i+c)%4-2)<<BigInt(depth-2),index:true});
for(const value of [2147483647n,-2147483647n])verify(`residual-${value}`,{depth:32,channels:8,type:9,k:30,sample:i=>i%96?value:0n,index:true});
// Every defined speaker, plus RFC examples, unassigned tracks and case/padding.
for(let bit=0;bit<18;bit++)verify(`speaker-${bit}`,{depth:32,channels:1,mask:1<<bit,fields:[`WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x${(1<<bit).toString(16)}`]});
for(const [channels,mask] of [[4,0x5003],[4,0x12104],[4,3],[8,0],[8,0x63f],[6,0x60f],[8,0x2b013]])verify(`mask-${channels}-${mask}`,{depth:24,channels,mask,fields:['TITLE=unrelated',`WaVeFoRmAtExTeNsIbLe_ChAnNeL_MaSk=0X0000${mask.toString(16).toUpperCase()}`,`waveformatextensible_channel_mask=0x${mask.toString(16)}`],index:true});
verify('maximum-block',{depth:32,channels:8,type:0,block:65535,frames:2,index:true,variable:true});
const layouts=['mono','stereo','3.0','quad','5.0','5.1','6.1','7.1'];
for(const depth of [16,24,32])for(let channels=1;channels<=8;channels++)for(const level of [0,5,12]){
 const n=10003,raw=Buffer.alloc(n*channels*4),samples=Array.from({length:channels},()=>Array(n));let seed=0x593981f;
 for(let i=0;i<n;i++)for(let c=0;c<channels;c++){
  seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;
  const s=level===5?Math.round(.77*(2**(depth-1)-1)*Math.sin(i*(c+1)*.0391)):Number(BigInt.asIntN(depth,BigInt(seed)));
  samples[c][i]=BigInt(s);raw.writeInt32LE(Number(BigInt(s)<<BigInt(32-depth)),(i*channels+c)*4);
 }
 const name=`modern-${depth}-${channels}-${level}`,source=path.join(directory,name+'.s32'),encoded=path.join(directory,name+'.encoded.flac');fs.writeFileSync(source,raw);
 ff(['-f','s32le','-ar','48000','-ac',String(channels),'-channel_layout',layouts[channels-1],'-i',source,'-c:a','flac','-sample_fmt',depth===16?'s16':'s32','-bits_per_raw_sample',String(depth),'-strict','experimental','-compression_level',String(level),encoded]);
 const data=fs.readFileSync(encoded),packed=data.readBigUInt64BE(18);
 if(Number((packed>>36n)&31n)+1!==depth||Number((packed>>41n)&7n)+1!==channels)throw Error('Encoder changed tested depth/channels');
 verify(name,{depth,channels,prepared:{data,samples,total:n,depth,mask:defaults[channels-1]}});
}
const base={depth:32,channels:8,frames:1};
for(const value of ['', '0x','3','0xG','0x-1','0x40000','0x100000000','0x3ffff'])reject('mask-'+Buffer.from(value).toString('hex'),{...base,fields:['WAVEFORMATEXTENSIBLE_CHANNEL_MASK='+value]});
reject('conflicting-masks',{...base,fields:['WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x3','WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x4']});
reject('duplicate-comments',{...base,fields:[],extraMetadata:[[4,comment([])]]});
for(const payload of [Buffer.alloc(0),Buffer.from([255,255,255,255]),Buffer.from([0,0,0,0,1,0,0,0]),Buffer.from([0,0,0,0,1,0,0,0,255,255,255,255]),Buffer.from([0,0,0,0,0,0,0,0,0])])reject('comment-'+payload.toString('hex'),{...base,extraMetadata:[[4,payload]]});
reject('int-min-residual',{...base,type:9,k:30,sample:i=>i? -1n:2147483647n,badResidual:-2147483648n});
reject('folded-overflow',{...base,type:8,k:30,sample:()=>0n,badResidual:2147483648n});
reject('negative-lpc-shift',{...base,type:32,constant:true,coeff:[1],shift:-1});
reject('prediction-overflow',{...base,type:32,constant:true,coeff:[16383],badResidual:0n});
// Invalid reconstruction in a channel deliberately omitted from the mix.
reject('unassigned-overflow',{depth:4,channels:8,frames:1,mask:3,fields:['WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x3'],constant:true,perChannel:Array.from({length:8},(_,c)=>c===7?{type:9,k:3,badResidual:1n}:{type:0})});
const report={suite:'native FLAC depths and layouts',result:'passed',reference:'RFC 9639; FFmpeg independently decoded lossless channels',reference_version:run('ffmpeg',['-version']).split('\n')[0].trim(),output:'stereo float; speaker policy in docs/flac.md',files:results.length,seek_checks:results.reduce((s,r)=>s+r.checks,0),guarded_reads:results.reduce((s,r)=>s+(r.guarded_reads??0),0),cancel_checks:results.reduce((s,r)=>s+(r.cancel_checks??0),0),reopen_checks:results.reduce((s,r)=>s+(r.reopen_checks??0),0),rejections:rejections.length,results,malformed:rejections};
fs.writeFileSync(path.join(directory,'flac-layout-verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({files:report.files,seek_checks:report.seek_checks,rejections:report.rejections,result:'passed'}));
