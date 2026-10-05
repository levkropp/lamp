'use strict';
// Original AIFF/AIFC constructor, ordered-speaker numeric and framing tests.
const {exe}=require('./platform');
const fs=require('fs'),path=require('path'),cp=require('child_process');
const [cli,oracle,dir]=process.argv.slice(2).map(x=>path.resolve(x));fs.mkdirSync(dir,{recursive:true});
const selection=process.env.LAMP_AIFF_CASE?new RegExp(process.env.LAMP_AIFF_CASE):null;
function run(exe,args){const r=cp.spawnSync(exe,args,{encoding:'utf8',windowsHide:true,maxBuffer:4*1024*1024,timeout:60000});if(r.error||r.status)throw Error(`${path.basename(exe)} ${args.join(' ')}: ${r.status} ${r.stderr||r.error} ${r.stdout}`);return r.stdout;}
function remove(file){try{fs.unlinkSync(file);}catch(e){if(e.code!=='ENOENT')throw e;}}
function ff(args){return run('ffmpeg',['-hide_banner','-loglevel','error','-y',...args]);}
function chunk(id,b){const h=Buffer.alloc(8);h.write(id);h.writeUInt32BE(b.length,4);return Buffer.concat([h,b,...(b.length&1?[Buffer.alloc(1)]:[])]);}
function form(kind,parts){const body=Buffer.concat(parts),h=Buffer.alloc(12);h.write('FORM');h.writeUInt32BE(body.length+4,4);h.write(kind,8);return Buffer.concat([h,body]);}
function extended(rate){const exp=Math.floor(Math.log2(rate)),b=Buffer.alloc(10);b.writeUInt16BE(exp+16383);b.writeBigUInt64BE(BigInt(rate*2**(63-exp)),2);return b;}
const q=Math.SQRT1_2,a=Math.sqrt(3)/2,r=Math.sqrt(3/8),maxFloat=3.4028234663852886e38;
const weights=[[1,0],[0,1],[q,q],[q,q],[a,.5],[.5,a],[q,0],[0,q],[r,r],[a,.5],[.5,a],[.5,.5],[q,0],[.5,.5],[0,q],[r,q/2],[a/2,a/2],[q/2,r]];
const defaults=[[3],[1,2],[1,2,3],[1,3,2,9],[1,2,3,5,6],[1,7,3,2,8,9],[1,2,3,4,5,6,9],[1,2,3,4,5,6,10,11]];
// Apple Core Audio layout constants; independent of assembly record storage.
const layouts=new Map([[100,[3]],[101,[1,2]],[102,[1,2]],[103,[1,2]],[105,[1,2]],[106,[1,2]],
 [108,[1,2,5,6]],[109,[1,2,5,6,3]],[110,[1,2,5,6,3,9]],[111,[1,2,5,6,3,9,10,11]],[112,[1,2,5,6,13,15,16,18]],
 [113,[1,2,3]],[114,[3,1,2]],[115,[1,2,3,9]],[116,[3,1,2,9]],
 [117,[1,2,3,5,6]],[118,[1,2,5,6,3]],[119,[1,3,2,5,6]],[120,[3,1,2,5,6]],
 [121,[1,2,3,4,5,6]],[122,[1,2,5,6,3,4]],[123,[1,3,2,5,6,4]],[124,[3,1,2,5,6,4]],
 [125,[1,2,3,4,5,6,9]],[126,[1,2,3,4,5,6,7,8]],[127,[3,7,8,1,2,5,6,4]],[128,[1,2,3,4,10,11,33,34]],
 [129,[1,2,5,6,3,4,7,8]],[130,[1,2,3,4,5,6,38,39]],[131,[1,2,9]],[132,[1,2,5,6]],
 [133,[1,2,4]],[134,[1,2,4,9]],[135,[1,2,4,5,6]],[136,[1,2,3,4]],[137,[1,2,3,4,9]],[138,[1,2,5,6,4]],
 [139,[1,2,5,6,3,9]],[140,[1,2,5,6,3,33,34]],[141,[3,1,2,5,6,9]],[142,[3,1,2,5,6,9,4]],[143,[3,1,2,5,6,33,34]],[144,[3,1,2,5,6,33,34,9]]]);
function role(label,index,C){if(label===0||label===0xffffffff)return 0;if(label>=65536||label===400)return C===1?3:index<2?index+1:0;return ({33:5,34:6,37:4,38:1,39:2,42:3,44:9,301:1,302:2})[label]??label;}
function labelsFor(C,opt){if(opt.labels)return opt.labels.map((v,i)=>role(v,i,C));if(opt.tag===147||opt.tag===65535)return Array.from({length:C},(_,i)=>C===1?3:i<2?i+1:0);if(opt.tag)return layouts.get(opt.tag).map((v,i)=>role(v,i,C));if(opt.bitmap!==undefined)return Array.from({length:18},(_,i)=>i+1).filter(i=>opt.bitmap&(1<<(i-1)));return defaults[C-1];}
function channelChunk(opt,C){let tag=0,bitmap=0,labels=[];if(opt.labels)labels=opt.labels;else if(opt.bitmap!==undefined){tag=0x10000;bitmap=opt.bitmap;}else tag=opt.tag*65536+C;
 const b=Buffer.alloc(12+labels.length*20+(opt.chanExtra??0));b.writeUInt32BE(tag);b.writeUInt32BE(bitmap,4);b.writeUInt32BE(labels.length,8);labels.forEach((l,i)=>b.writeUInt32BE(l,12+i*20));return chunk('CHAN',b);
}
function finite(x){return Number.isFinite(x)?Math.max(-maxFloat,Math.min(maxFloat,x)):0;}
function make(opt={}){
 const kind=opt.kind??'AIFF',code=opt.code??(kind==='AIFF'?null:'NONE'),float=/^(fl|FL)(32|64)$/.test(code??''),forced=({in24:24,in32:32,'raw ':8})[code],bits=opt.bits??(float?Number(code.slice(2)):forced??16),width=forced??Math.ceil(bits/8)*8,C=opt.C??2,N=opt.N??4609,R=opt.R??48000,little=code==='sowt',labels=labelsFor(C,opt),raw=Buffer.alloc(N*C*width/8),native=Array.from({length:C},()=>Array(N)),expected=Buffer.alloc(N*8);
 const w=labels.map(x=>x?weights[x-1]:[0,0]),active=labels.filter(x=>x).length;let sum=[0,0];for(const row of w){sum[0]+=row[0];sum[1]+=row[1];}const scale=active?(active<=4?1:2)/Math.max(...sum):0,coeff=w.map(row=>row.map(v=>v*scale));let seed=0x479abb3a;
 for(let i=0;i<N;i++){
  for(let c=0;c<C;c++){
   seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;let s,at=(i*C+c)*width/8;
   if(float){s=opt.sample?opt.sample(i,c):(seed>>8)/16777216;if(width===32){s=Math.fround(s);raw.writeFloatBE(s,at);}else raw.writeDoubleBE(s,at);}
   else{let v=Number(BigInt.asIntN(bits,BigInt(seed)));if(i%13===0)v=-(2**(bits-1));if(i%13===1)v=2**(bits-1)-1;const stored=v*2**(width-bits)+(opt.dirty?2**(width-bits)-1:0);s=v*2**(1-bits);if(code==='raw ')raw.writeUInt8(stored+128,at);else if(width===8)raw.writeInt8(stored,at);else if(little)raw.writeIntLE(stored,at,width/8);else raw.writeIntBE(stored,at,width/8);}
   native[c][i]=s;
  }
  let l=0,r=0;if(C===1&&labels[0]===3){l=r=finite(native[0][i]);}else if(C===2&&labels[0]===1&&labels[1]===2){l=finite(native[0][i]);r=finite(native[1][i]);}else for(let c=0;c<C;c++){const value=finite(native[c][i]);l+=value*coeff[c][0];r+=value*coeff[c][1];}expected.writeFloatLE(finite(l),i*8);expected.writeFloatLE(finite(r),i*8+4);
 }
 const name=Buffer.from(opt.name??'not compressed'),pstring=Buffer.concat([Buffer.from([name.length]),name,...((name.length+1)&1?[Buffer.alloc(1)]:[])]),comm=Buffer.alloc(18+(kind==='AIFC'?4+pstring.length:0)+(opt.commExtra??0));comm.writeUInt16BE(C);comm.writeUInt32BE(N,2);comm.writeUInt16BE(bits,6);extended(R).copy(comm,8);if(kind==='AIFC'){comm.write(code,18);pstring.copy(comm,22);}
 const offset=opt.offset??0,tail=opt.tail??0,ssnd=Buffer.alloc(8+offset+raw.length+tail,0x79);ssnd.writeUInt32BE(offset);ssnd.writeUInt32BE(opt.block??0,4);raw.copy(ssnd,8+offset);
 const version=Buffer.alloc(4);version.writeUInt32BE(opt.version??0xa2805140);const common=chunk('COMM',comm),sound=chunk('SSND',ssnd),chan=opt.labels||opt.tag||opt.bitmap!==undefined?[channelChunk(opt,C)]:[],parts=[...(kind==='AIFC'&&!opt.noVersion?[chunk('FVER',version)]:[]),...(opt.before??[]),...(opt.soundFirst?[sound,common]:[common,...(!opt.noSound?[sound]:[])]),...chan,...(opt.after??[])];
 return {data:form(kind,parts),comm,ssnd,parts,raw,native,expected,kind,code,float,bits,width,C,N,R:Math.floor(R+.5),originalRate:R,little,labels,opt};
}
const results=[],malformed=[];let seeks=0,guarded=0,cancels=0,reopens=0;
function verify(name,m,independent=true){
 if(selection&&!selection.test(name))return;
 const file=path.join(dir,name+'.aiff'),out=file+'.ours.f32',want=file+'.expected.f32';fs.writeFileSync(file,m.data);fs.writeFileSync(want,m.expected);remove(out);run(cli,['--decode',file,out]);if(!fs.readFileSync(out).equals(m.expected))throw Error('Stereo PCM mismatch '+name);
 let seek={};if(m.N)seek=JSON.parse(run(exe(oracle,'seek-oracle'),[file,want,'0','0']));const guard=JSON.parse(run(exe(oracle,'pcm-bounds-oracle'),[file,want]));run(exe(oracle,'seek-oracle'),[file,want,'3']);seeks+=(seek.checks??0)+guard.empty_seeks;guarded+=guard.guarded_reads;cancels+=guard.cancel_checks+1;reopens+=guard.reopen_checks;
 let reference=m.N?(independent?'original AIFF/AIFC container':'numeric stereo oracle; dirty unused-bit discard policy'):'not applicable; empty stream';if(independent&&m.N){const ref=file+'.reference.f64',args=[],limits=[];
  // FFmpeg n8.0.1 consumes odd COMM padding in both get_aiff_header and
  // aiff_read_header. Compare its raw PCM reader for this framing variant.
  if(m.opt.tail)limits.push('declared-frame trimming');if(m.opt.rawReference)limits.push('fractional-rate rounding');if(m.opt.commExtra&1)limits.push('FFmpeg double COMM padding');if(m.code==='sowt'&&m.width!==16)limits.push('FFmpeg sowt width');
  if(limits.length){const raw=file+'.reference.raw';fs.writeFileSync(raw,m.raw);args.push('-f',m.float?(m.width===32?'f32be':'f64be'):m.width===8?(m.code==='raw '?'u8':'s8'):`s${m.width}${m.little?'le':'be'}`,'-ar',String(m.R),'-ac',String(m.C),'-i',raw);reference='raw physical PCM; '+limits.join('; ');}else args.push('-i',file);
  ff([...args,'-c:a','pcm_f64le','-f','f64le',ref]);const b=fs.readFileSync(ref);if(b.length!==m.N*m.C*8)throw Error('Reference frames changed '+name);for(let i=0;i<m.N;i++)for(let c=0;c<m.C;c++)if(!Object.is(b.readDoubleLE((i*m.C+c)*8),m.native[c][i]))throw Error(`Independent native PCM mismatch ${name}, frame ${i}, channel ${c}`);
 }
 const stats=run(cli,['--check',file]);if(!stats.includes(`codec=6 rate=${m.R} channels=${m.C} bits=${m.bits} frames=${m.N} `))throw Error('Incorrect advertised metadata '+name+' '+stats);
 results.push({file:path.basename(file),kind:m.kind,compression:m.code,channels:m.C,valid_bits:m.bits,container_bits:m.width,rate:m.R,original_rate:m.originalRate,frames:m.N,labels:m.labels,independent_channels:independent&&m.N>0,reference,...seek,...guard});if(results.length%100===0)console.log('Verified AIFF/AIFC files: '+results.length);
}
for(const [kind,code] of [['AIFF',null],['AIFC','NONE'],['AIFC','twos'],['AIFC','sowt']])for(let bits=1;bits<=32;bits++)for(let C=1;C<=8;C++)verify(`${kind}-${code}-${bits}-${C}`,make({kind,code,bits,C,R:[8000,44100,192000][bits%3]}));
for(const [code,width] of [['raw ',8],['in24',24],['in32',32]])for(let bits=1;bits<=width;bits++)for(let C=1;C<=8;C++)verify(`fixed-${code.trim()}-${bits}-${C}`,make({kind:'AIFC',code,bits,C}));
for(const code of ['fl32','fl64','FL32','FL64'])for(let C=1;C<=8;C++)verify(`float-${code}-${C}`,make({kind:'AIFC',code,C}));
for(const [tag,labels] of layouts)for(const code of ['NONE','sowt','fl64'])verify(`tag-${tag}-${code}`,make({kind:'AIFC',code,C:labels.length,tag}));
for(let label=1;label<=18;label++)verify(`speaker-${label}`,make({kind:'AIFC',code:'fl64',C:1,labels:[label]}));
for(const labels of [[2,1],[1,1,2,2],[13,14,15,16,17,18],[33,34,38,39,42,301,302,0],[37,44],[0,0xffffffff],[65536,65537,65538,65539],[400],[0,0,0,0]])verify('descriptions-'+labels.join('-'),make({kind:'AIFC',code:'NONE',C:labels.length,labels}));
for(const [C,bitmap] of [[1,1],[2,3],[4,0x33],[6,0x3f],[8,0x63f],[3,0x1c000]])verify(`bitmap-${C}-${bitmap}`,make({kind:'AIFC',C,bitmap}));
for(const tag of [147,65535])for(let C=1;C<=8;C++)verify(`directout-${tag}-${C}`,make({kind:'AIFC',C,tag}));
for(const [name,opt] of [['sound-first',{soundFirst:true}],['offset-odd',{offset:3}],['block-padding',{offset:13,tail:67,block:512}],['metadata-padding',{before:[chunk('NAME',Buffer.from('odd'))],after:[chunk('ANNO',Buffer.from('after'))]}],['empty',{N:0}],['empty-no-sound',{N:0,noSound:true}],['future-comm',{commExtra:5}],['future-comm-even',{commExtra:6}],['name-empty',{name:''}],['name-255',{name:'x'.repeat(255)}],['version-absent',{noVersion:true}],['version-future',{version:0}],['future-chan',{tag:101,chanExtra:7}]])for(const kind of ['AIFF','AIFC'])verify(`${kind}-${name}`,make({kind,...opt}));
for(const R of [8000,11025,22050,44100,48000,88200,96000,176400,192000,7999.5,8191.5,32767.5,48000.25,48000.5,65535.5,131071.5,191999.5,192000.25])verify('rate-'+R,make({kind:'AIFC',R,rawReference:!Number.isInteger(R)}));
for(const code of ['fl32','fl64'])for(const C of [1,2,8]){const edge=[0,-0,NaN,Infinity,-Infinity,maxFloat,-maxFloat,Number.MAX_VALUE,-Number.MAX_VALUE,Number.MIN_VALUE,-Number.MIN_VALUE,2**-149,-(2**-149)];verify(`float-edge-${code}-${C}`,make({kind:'AIFC',code,C,sample:(i,c)=>edge[(i+c)%edge.length]}));}
for(const code of [null,'NONE','sowt'])for(const bits of [3,12,20,29])verify(`dirty-${code}-${bits}`,make({kind:code?'AIFC':'AIFF',code,bits,C:8,dirty:true}),false);
verify('unicode-灯-лампа-ضوء-🎵',make({kind:'AIFC',code:'sowt',bits:24,C:8,offset:3}));
for(const [codec,bits] of [['pcm_s8',8],['pcm_s16be',16],['pcm_s24be',24],['pcm_s32be',32],['pcm_s16le',16],['pcm_f32be',32],['pcm_f64be',64]])for(let C=1;C<=8;C++)for(const R of [8000,48000,192000]){
 if(selection&&!selection.test(`modern-${codec}-${C}-${R}`))continue;
 // FFmpeg's named layouts use WAVE channel order. In particular 6.1 is
 // L R C LFE Cs Ls Rs, unlike the ordered MPEG-6.1 Core Audio tag.
 const code=codec==='pcm_s16le'?'sowt':codec==='pcm_f32be'?'fl32':codec==='pcm_f64be'?'fl64':'NONE',m=make({kind:'AIFC',code,bits,C,R,bitmap:[4,3,7,0x33,0x37,0x3f,0x70f,0x63f][C-1]}),name=`modern-${codec}-${C}-${R}`,raw=path.join(dir,name+'.raw'),file=path.join(dir,name+'.encoded.aiff');fs.writeFileSync(raw,m.raw);
 ff(['-f',m.float?`f${bits}be`:bits===8?'s8':`s${bits}${m.little?'le':'be'}`,'-ar',String(R),'-ac',String(C),'-channel_layout',['mono','stereo','3.0','quad','5.0','5.1','6.1','7.1'][C-1],'-i',raw,'-c:a',codec,file]);m.data=fs.readFileSync(file);m.kind=m.data.toString('ascii',8,12);if(m.kind==='AIFF')m.code=null;verify(name,m);
}
function reject(name,mutate,opt={}){if(selection&&!selection.test(name))return;const m=make({kind:'AIFC',...opt}),file=path.join(dir,'bad-'+name+'.aiff');fs.writeFileSync(file,mutate(m));const r=cp.spawnSync(cli,['--check',file],{encoding:'utf8',timeout:5000,windowsHide:true});if(r.status!==2||!(/decode_error=[1-9]/.test(r.stdout)||/Unsupported, malformed/.test(r.stdout)))throw Error('Malformed AIFF accepted '+name+' '+r.stdout);malformed.push({file:path.basename(file),result:'rejected'});}
function replace(m,id,b){return form(m.kind,m.parts.map(p=>p.toString('ascii',0,4)===id?chunk(id,b):p));}
for(const [name,at,size,value] of [['channels-zero',0,2,0],['channels-nine',0,2,9],['bits-zero',6,2,0],['bits-33',6,2,33],['frames-outside',2,4,0xffffffff],['negative-rate',8,2,0xc00e],['zero-rate',8,2,0],['infinite-rate',8,2,0x7fff],['exponent-small',8,2,16394],['exponent-large',8,2,16401]])reject(name,m=>{if(size===2)m.comm.writeUInt16BE(value,at);else m.comm.writeUInt32BE(value,at);return replace(m,'COMM',m.comm);});
reject('unnormalized-rate',m=>{m.comm[10]&=0x7f;return replace(m,'COMM',m.comm);});
reject('rate-below',m=>m.data,{R:7999});reject('rate-above',m=>m.data,{R:192001});
reject('unknown-compression',m=>{m.comm.write('ima4',18);return replace(m,'COMM',m.comm);});
reject('float-depth',m=>{m.comm.writeUInt16BE(16,6);return replace(m,'COMM',m.comm);},{code:'fl64'});
for(const [code,bits] of [['raw ',9],['in24',25],['in32',33]])reject('fixed-depth-'+code.trim(),m=>{m.comm.write(code,18);m.comm.writeUInt16BE(bits,6);return replace(m,'COMM',m.comm);});
reject('name-overrun',m=>{m.comm[22]=255;return replace(m,'COMM',m.comm);});
reject('comm-short',m=>replace(m,'COMM',m.comm.subarray(0,17)));reject('name-no-pad',m=>replace(m,'COMM',m.comm.subarray(0,23)));
reject('ssnd-short',m=>replace(m,'SSND',m.ssnd.subarray(0,7)));reject('offset-outside',m=>{m.ssnd.writeUInt32BE(0xffffffff);return replace(m,'SSND',m.ssnd);});
reject('ssnd-truncated',m=>replace(m,'SSND',m.ssnd.subarray(0,-1)));reject('missing-sound',m=>form(m.kind,[chunk('COMM',m.comm)]));reject('missing-comm',m=>form(m.kind,[chunk('SSND',m.ssnd)]));
for(const id of ['COMM','SSND','FVER','CHAN'])reject('duplicate-'+id,m=>form(m.kind,[...m.parts,chunk(id,id==='COMM'?m.comm:id==='SSND'?m.ssnd:id==='FVER'?Buffer.alloc(4):Buffer.alloc(12))]),id==='CHAN'?{tag:101}:{});
reject('fver-short',m=>replace(m,'FVER',Buffer.alloc(3)));reject('form-short',m=>{m.data.writeUInt32BE(3,4);return m.data;});reject('form-outside',m=>{m.data.writeUInt32BE(0xffffffff,4);return m.data;});reject('form-fragment',m=>form(m.kind,[...m.parts,Buffer.from('xx')]));reject('missing-pad',m=>m.data.subarray(0,-1),{after:[chunk('NAME',Buffer.from('x'))]});
reject('chan-short',m=>form(m.kind,[...m.parts,chunk('CHAN',Buffer.alloc(11))]));reject('chan-descriptions-overflow',m=>{const c=Buffer.alloc(12);c.writeUInt32BE(0xffffffff,8);return form(m.kind,[...m.parts,chunk('CHAN',c)]);});
for(const [name,opt] of [['chan-count',{tag:100}],['chan-unknown',{tag:999}],['chan-mid-side',{tag:104}],['chan-ambisonic',{C:4,tag:107}],['chan-bitmap-too-few',{C:2,bitmap:1}],['chan-bitmap-too-many',{C:1,bitmap:3}],['chan-bitmap-reserved',{C:1,bitmap:0x40000}],['chan-description-count',{C:2,labels:[1]}],['chan-coordinate',{C:1,labels:[100]}],['chan-label-reserved',{C:1,labels:[199]}]]){
 // Unsupported layouts cannot supply the numeric generator's speaker matrix.
 reject(name,m=>form(m.kind,[...m.parts,channelChunk(opt,opt.C??2)]),{C:opt.C??2});
}
let seed=0x71a94230;for(let i=0;i<256;i++){seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;const v=(seed>>>0)|0x80000000;reject('seeded-size-'+i,m=>{if(i%3===0)m.data.writeUInt32BE(v>>>0,4);else if(i%3===1)m.data.writeUInt32BE(v>>>0,16);else{m.ssnd.writeUInt32BE(v>>>0);return replace(m,'SSND',m.ssnd);}return m.data;});}
const sparse=[];
for(const [kind,bits,C,float,mode] of [[1,8,1,0,0],[1,16,2,0,0],[1,24,2,0,0],[1,32,1,0,0],[2,8,1,0,0],[2,16,2,0,0],[2,24,2,0,0],[2,32,1,0,0],[2,32,2,1,0],[2,64,2,1,0],[3,16,2,0,0],[3,24,2,0,0],[3,32,1,0,0],[1,16,2,0,1],[2,64,2,1,1],[3,32,2,0,1],[1,24,2,0,2],[2,64,2,1,2],[3,16,2,0,2]]){
 const name=`sparse-${kind}-${bits}-${C}-${float}-${mode}`;if(selection&&!selection.test(name))continue;const file=path.join(dir,name+'.aiff');
 try{
  const r=JSON.parse(run(exe(oracle,'aiff-sparse-oracle'),[file,String(kind),String(bits),String(C),String(float),String(mode)]));let header='original AIFF/AIFC',input,duration=null;
  if(r.frames>0x7fffffff||kind===3&&bits!==16){header='raw physical PCM at known 64-bit offset; FFmpeg signed frame count or sowt width limitation';input=['-skip_initial_bytes',String(r.data_offset+r.reference_frame*C*bits/8),'-f',float?`f${bits}be`:bits===8?'s8':`s${bits}${kind===3?'le':'be'}`,'-ar','48000','-ac',String(C),'-i',file];}
  else{const probe=JSON.parse(run('ffprobe',['-v','error','-show_entries','stream=duration_ts,sample_rate,channels','-of','json',file])).streams[0];duration=probe.duration_ts;if(duration!==r.frames||probe.channels!==C||Number(probe.sample_rate)!==48000)throw Error('Large-file framing mismatch '+name);input=['-ss',String(r.reference_seconds),'-i',file];}
  const ref=file+'.reference.f32';ff([...input,'-af','atrim=end_sample=257','-c:a','pcm_f32le','-f','f32le',ref]);if(!fs.readFileSync(ref).equals(fs.readFileSync(file+'.channels.f32')))throw Error('Large-file PCM mismatch '+name);
  sparse.push({file:path.basename(file),kind,container_bits:bits,channels:C,float:!!float,metadata:mode,...r,reference_header:header,reference_duration_frames:duration});seeks+=r.seek_checks;cancels+=r.cancel_checks;reopens+=r.reopen_checks;
 }finally{remove(file);}
}
const report={suite:'AIFF/AIFC PCM, float and ordered layouts',scope:selection?.source??'all',result:'passed',reference:'Apple AIFF 1.3, AIFF-C 1991 and Core Audio channel-layout definitions; independent FFmpeg channels and original stereo numeric oracle',reference_version:run('ffmpeg',['-version']).split('\n')[0].trim(),files:results.length,sparse_files:sparse.length,seek_checks:seeks,guarded_reads:guarded,cancel_checks:cancels,reopen_checks:reopens,rejections:malformed.length,maximum_logical_bytes:sparse.length?Math.max(...sparse.map(r=>r.logical_bytes)):null,maximum_allocated_bytes:sparse.length?Math.max(...sparse.map(r=>r.allocated_bytes)):null,results,sparse,malformed};fs.writeFileSync(path.join(dir,'aiff-verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({files:report.files,sparse_files:sparse.length,seek_checks:seeks,rejections:report.rejections,result:'passed',scope:report.scope}));
