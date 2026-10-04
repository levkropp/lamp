'use strict';
// Original RIFF/WAVE constructor and numeric stereo oracle. FFmpeg separately
// checks source channels; the C harness exercises guarded reads and seeking.
const fs=require('fs'),path=require('path'),cp=require('child_process');
const [cli,seek,directory,bounds]=process.argv.slice(2).map(x=>path.resolve(x));
if(!bounds)throw Error('Supply CLI, seek oracle, generated directory and guarded-read oracle');
fs.mkdirSync(directory,{recursive:true});
function run(exe,args){const r=cp.spawnSync(exe,args,{encoding:'utf8',maxBuffer:8*1024*1024});if(r.error||r.status)throw Error(`${path.basename(exe)} ${args.join(' ')}: ${r.status} ${r.stderr||r.error} ${r.stdout}`);return r.stdout;}
function ff(args){return run('ffmpeg',['-hide_banner','-loglevel','error','-y',...args]);}
function removeExport(file){try{fs.unlinkSync(file);}catch(e){if(e.code!=='ENOENT')throw e;}if(fs.existsSync(file))throw Error('Export cleanup failed '+file);}
const defaults=[4,3,7,0x33,0x37,0x3f,0x70f,0x63f],q=Math.SQRT1_2,a=Math.sqrt(3)/2,r=Math.sqrt(3/8),maxFloat=3.4028234663852886e38;
const weights=[[1,0],[0,1],[q,q],[q,q],[a,.5],[.5,a],[q,0],[0,q],[r,r],[a,.5],[.5,a],[.5,.5],[q,0],[.5,.5],[0,q],[r,q/2],[a/2,a/2],[q/2,r]];
function matrix(C,mask){
 const w=[];let l=0,h=0;for(let bit=0;bit<18&&w.length<C;bit++)if(mask&(1<<bit)){w.push(weights[bit].slice());l+=weights[bit][0];h+=weights[bit][1];}
 const scale=w.length?(w.length<=4?1:2)/Math.max(l,h):0;for(const row of w){row[0]*=scale;row[1]*=scale;}while(w.length<C)w.push([0,0]);return w;
}
function finite(x){return Number.isFinite(x)?Math.max(-maxFloat,Math.min(maxFloat,x)):0;}
function stereo(samples,mask){
 const C=samples.length,N=samples[0].length,out=Buffer.alloc(N*8),w=matrix(C,mask),direct=(C===1&&mask===4)||(C===2&&mask===3);
 for(let i=0;i<N;i++){
  let l=0,r=0;if(direct){l=finite(samples[0][i]);r=finite(samples[C===1?0:1][i]);}
  else for(let c=0;c<C;c++){const s=finite(samples[c][i]);l+=s*w[c][0];r+=s*w[c][1];}
  out.writeFloatLE(finite(l),i*8);out.writeFloatLE(finite(r),i*8+4);
 }return out;
}
function chunk(id,data){const h=Buffer.alloc(8);h.write(id);h.writeUInt32LE(data.length,4);return Buffer.concat([h,data,...(data.length%2?[Buffer.alloc(1)]:[])]);}
function riff(chunks){const b=Buffer.concat(chunks),h=Buffer.alloc(12);h.write('RIFF');h.writeUInt32LE(b.length+4,4);h.write('WAVE',8);return Buffer.concat([h,b]);}
function make(spec){
 const C=spec.channels,B=spec.bits,V=spec.valid??B,N=spec.frames??1237,R=spec.rate??48000,bytes=B/8,float=spec.float??false,ext=spec.ext??true;
 const samples=Array.from({length:C},()=>Array(N)),raw=Buffer.alloc(N*C*bytes),min=-(2**(V-1)),max=-min-1;let seed=0x5ac33972;
 for(let i=0;i<N;i++)for(let c=0;c<C;c++){
  seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;
  const edge=[min,max,0,1,-1,min+1,max-1];let s=spec.sample?spec.sample(i,c):float?Math.sin(i*(c+1)*.0613)*.73:i%13<7?edge[(i+c)%7]:Number(BigInt.asIntN(V,BigInt(seed)));
  const at=(i*C+c)*bytes;
  if(float){if(B===32){s=Math.fround(s);raw.writeFloatLE(s,at);}else raw.writeDoubleLE(s,at);samples[c][i]=s;}
  else{
   s=Number(BigInt.asIntN(V,BigInt(s)));let stored=s*2**(B-V);samples[c][i]=stored*2**(1-B);
   if(spec.dirtyPadding&&B>V)stored+=2**(B-V)-1;
   if(B===8)raw.writeUInt8(stored+128,at);else if(B===16)raw.writeInt16LE(stored,at);else if(B===24)raw.writeIntLE(stored,at,3);else raw.writeInt32LE(stored,at);
  }
 }
 const fmt=Buffer.alloc(ext?40+(spec.extraFmt??0):16);fmt.writeUInt16LE(ext?0xfffe:float?3:1);fmt.writeUInt16LE(C,2);fmt.writeUInt32LE(R,4);fmt.writeUInt32LE(R*C*bytes,8);fmt.writeUInt16LE(C*bytes,12);fmt.writeUInt16LE(B,14);
 const mask=spec.mask??defaults[C-1];
 if(ext){fmt.writeUInt16LE(22+(spec.extraFmt??0),16);fmt.writeUInt16LE(spec.validHeader??V,18);fmt.writeUInt32LE(mask,20);fmt.writeUInt32LE(float?3:1,24);Buffer.from('00001000800000aa00389b71','hex').copy(fmt,28);}
 const before=spec.junk?[chunk('JUNK',Buffer.from('odd')),chunk('LIST',Buffer.from('INFO'))]:[];
 return {data:riff([...before,chunk('fmt ',fmt),chunk('data',raw)]),raw,samples,mask:ext&&mask===0?(C===1?4:3):mask,fmt,C,B,V,N,R,float};
}
const results=[],rejected=[];
function verify(name,spec,independent=true){
 const m=spec.prepared??make(spec),file=path.join(directory,name+'.wav'),ours=file+'.ours.f32',expected=file+'.expected.f32';
 fs.writeFileSync(file,m.data);const wanted=stereo(m.samples,m.mask);fs.writeFileSync(expected,wanted);removeExport(ours);run(cli,['--decode',file,ours]);
 const actual=fs.readFileSync(ours);if(!actual.equals(wanted)){let at=0;while(at<actual.length&&actual[at]===wanted[at])at++;throw Error(`Stereo mismatch ${name} byte ${at}: got ${actual.readFloatLE(at&~3)}, expected ${wanted.readFloatLE(at&~3)}`);}
 let referenceInput='original WAVE header';
 if(independent){
  const reference=file+'.reference.f64';let input=['-i',file];
  // riffdec.c in FFmpeg n8.0.1 selects the PCM codec from valid precision,
  // instead of physical container width. Cross a byte bucket and it reads
  // a different sample size. Keep Microsoft semantics in the implementation;
  // check those samples through the independent raw-container PCM reader.
  if(!m.float&&Math.ceil(m.V/8)*8!==m.B){
   const source=file+'.reference.raw';fs.writeFileSync(source,m.raw);
   input=['-f',({8:'u8',16:'s16le',24:'s24le',32:'s32le'})[m.B],'-ar',String(m.R),'-ac',String(m.C),'-i',source];
   referenceInput='raw physical PCM container; FFmpeg valid-bits header limitation';
  }
  ff([...input,'-c:a','pcm_f64le','-f','f64le',reference]);const b=fs.readFileSync(reference);
  if(b.length!==m.N*m.C*8)throw Error('Independent channel count changed '+name);
  for(let i=0;i<m.N;i++)for(let c=0;c<m.C;c++)if(!Object.is(b.readDoubleLE((i*m.C+c)*8),m.samples[c][i]))throw Error(`Independent PCM mismatch ${name}, frame ${i}, channel ${c}`);
 }
 const seekResult=JSON.parse(run(seek,[file,expected,'0','0'])),guard=JSON.parse(run(bounds,[file,expected]));
 const cancelledSeek=JSON.parse(run(seek,[file,expected,'3']));if(cancelledSeek.result!=='rejected')throw Error('Cancelled seek did work '+name);
 results.push({file:path.basename(file),channels:m.C,container_bits:m.B,valid_bits:m.V,rate:m.R,float:m.float,mask:m.mask,frames:m.N,independent_channels:independent,reference_input:referenceInput,...seekResult,...guard,cancel_checks:guard.cancel_checks+1,cancelled_seek:'no work'});
 if(results.length%80===0)console.log('Verified WAV precision/layout files: '+results.length);
}
function reject(name,spec,mutate){
 const m=make(spec),file=path.join(directory,'bad-'+name+'.wav');fs.writeFileSync(file,mutate(m.data,m));const r=cp.spawnSync(cli,['--check',file],{encoding:'utf8'});
 if(r.status!==2||!(/decode_error=[1-9]/.test(r.stdout)||/Unsupported, malformed/.test(r.stdout)))throw Error('Malformed WAV accepted '+name+' '+r.stdout+' '+r.stderr);
 rejected.push({file:path.basename(file),result:'rejected'});
}
for(const bits of [8,16,24,32])for(let valid=1;valid<=bits;valid++)for(let channels=1;channels<=8;channels++)verify(`pcm-${bits}-${valid}-${channels}`,{bits,valid,channels,rate:[8000,48000,192000][valid%3],junk:valid%5===0});
for(const bits of [8,16,24,32])for(let channels=1;channels<=8;channels++)verify(`basic-${bits}-${channels}`,{bits,channels,ext:false});
for(const bits of [32,64])for(let channels=1;channels<=8;channels++)for(const ext of [false,true])verify(`float-${bits}-${channels}-${ext}`,{bits,channels,float:true,ext});
for(const bits of [8,16,24,32,64])for(let channels=1;channels<=8;channels++)verify(`unspecified-precision-${bits}-${channels}`,{bits,channels,float:bits===64,validHeader:0,extraFmt:4});
for(const bits of [8,16,24,32,64])for(let channels=1;channels<=8;channels++)verify(`directout-${bits}-${channels}`,{bits,channels,mask:0,float:bits===64});
for(let bit=0;bit<18;bit++)verify(`speaker-${bit}`,{bits:64,channels:1,float:true,mask:1<<bit});
for(const [channels,mask] of [[4,0x5003],[4,0x12104],[4,3],[8,0x63f],[6,0x60f],[8,0x2b013],[2,7],[1,0x3ffff]])verify(`mask-${channels}-${mask}`,{bits:24,valid:20,channels,mask});
for(const bits of [8,16,24,32])verify(`padding-${bits}`,{bits,valid:bits-3,channels:8,dirtyPadding:true},false);
for(const bits of [32,64])for(const channels of [1,2,8]){
 const edge=[0,-0,Infinity,-Infinity,NaN,Number.MAX_VALUE,-Number.MAX_VALUE,Number.MIN_VALUE,-Number.MIN_VALUE,maxFloat,-maxFloat,2**-149,-(2**-149),.5,-.5];
 verify(`float-extremes-${bits}-${channels}`,{bits,channels,float:true,sample:(i,c)=>edge[(i+c)%edge.length]});
}
verify('unicode-灯-лампа-ضوء-🎵',{bits:32,valid:24,channels:8,junk:true});
const layouts=['mono','stereo','3.0','quad','5.0','5.1','6.1','7.1'];
for(const [bits,codec,float] of [[8,'pcm_u8',false],[16,'pcm_s16le',false],[24,'pcm_s24le',false],[32,'pcm_s32le',false],[32,'pcm_f32le',true],[64,'pcm_f64le',true]])for(let channels=1;channels<=8;channels++)for(const rate of [8000,48000,192000]){
 const name=`modern-${codec}-${channels}-${rate}`,m=make({bits,channels,float,rate,frames:16387}),source=path.join(directory,name+'.raw'),encoded=path.join(directory,name+'.encoded.wav');fs.writeFileSync(source,m.raw);
 const rawFormat=({pcm_u8:'u8',pcm_s16le:'s16le',pcm_s24le:'s24le',pcm_s32le:'s32le',pcm_f32le:'f32le',pcm_f64le:'f64le'})[codec];
 ff(['-f',rawFormat,'-ar',String(rate),'-ac',String(channels),'-channel_layout',layouts[channels-1],'-i',source,'-c:a',codec,encoded]);m.data=fs.readFileSync(encoded);verify(name,{prepared:m});
}
const base={bits:32,channels:8};
for(const [name,offset,width,value] of [['channels-zero',22,2,0],['channels-nine',22,2,9],['rate-low',24,4,7999],['rate-high',24,4,192001],['avg-bytes',28,4,1],['align-zero',32,2,0],['align-wrong',32,2,31],['bits-zero',34,2,0],['pcm-64',34,2,64],['cb-small',36,2,21],['cb-big',36,2,23],['valid-too-big',38,2,33],['reserved-mask',40,4,0x40000],['guid-tail',52,4,1],['subformat',44,4,0x10001]])reject(name,base,b=>{if(width===2)b.writeUInt16LE(value,offset);else b.writeUInt32LE(value,offset);return b;});
reject('float-valid-bits',{bits:64,channels:8,float:true},b=>{b.writeUInt16LE(32,38);return b;});
reject('float-16',{bits:32,channels:8,float:true},b=>{b.writeUInt16LE(16,34);return b;});
reject('compression',base,b=>{b.writeUInt16LE(2,20);return b;});
reject('guid',base,b=>{b[59]^=1;return b;});
reject('riff-overflow',base,b=>{b.writeUInt32LE(0xffffffff,4);return b;});
reject('riff-short',base,b=>{b.writeUInt32LE(3,4);return b;});
reject('chunk-overflow',base,b=>{b.writeUInt32LE(0xffffffff,16);return b;});
reject('fmt-truncated',base,b=>{b.writeUInt32LE(39,16);return b;});
reject('basic-fmt-17',{bits:16,channels:2,ext:false},(b,m)=>riff([chunk('fmt ',Buffer.concat([m.fmt,Buffer.alloc(1)])),chunk('data',m.raw)]));
reject('duplicate-fmt',base,(b,m)=>riff([chunk('fmt ',m.fmt),chunk('fmt ',m.fmt),chunk('data',m.raw)]));
reject('data-before-fmt',base,(b,m)=>riff([chunk('data',m.raw),chunk('fmt ',m.fmt)]));
reject('partial-frame',base,(b,m)=>riff([chunk('fmt ',m.fmt),chunk('data',m.raw.subarray(0,-1))]));
reject('truncated-data',base,b=>b.subarray(0,-1));
const report={suite:'RIFF/WAVE precision and layouts',result:'passed',reference:'Microsoft WAVEFORMATEXTENSIBLE; FFmpeg independent channel PCM; original stereo numeric oracle',reference_version:run('ffmpeg',['-version']).split('\n')[0].trim(),output:'stereo float; docs/wav.md',files:results.length,seek_checks:results.reduce((n,r)=>n+r.checks,0),guarded_reads:results.reduce((n,r)=>n+r.guarded_reads,0),cancel_checks:results.reduce((n,r)=>n+r.cancel_checks,0),reopen_checks:results.reduce((n,r)=>n+r.reopen_checks,0),rejections:rejected.length,results,malformed:rejected};
fs.writeFileSync(path.join(directory,'wav-layout-verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({files:report.files,seek_checks:report.seek_checks,rejections:report.rejections,result:'passed'}));
