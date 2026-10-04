'use strict';
// Original RF64/BW64 framing, numeric PCM and malformed-header fixtures.
const fs=require('fs'),path=require('path'),cp=require('child_process');
const [cli,oracle,dir]=process.argv.slice(2).map(x=>path.resolve(x));fs.mkdirSync(dir,{recursive:true});
function run(exe,args){const r=cp.spawnSync(exe,args,{encoding:'utf8',maxBuffer:4*1024*1024,timeout:60000});if(r.error||r.status)throw Error(`${path.basename(exe)} ${args.join(' ')}: ${r.status} ${r.stderr||r.error} ${r.stdout}`);return r.stdout;}
function remove(file){try{fs.unlinkSync(file);}catch(e){if(e.code!=='ENOENT')throw e;}}
function ff(args){return run('ffmpeg',['-hide_banner','-loglevel','error','-y',...args]);}
function chunk(id,b,sentinel=false){const h=Buffer.alloc(8);h.write(id);h.writeUInt32LE(sentinel?0xffffffff:b.length,4);return Buffer.concat([h,b,...(b.length&1?[Buffer.alloc(1)]:[])]);}
const masks=[4,3,7,0x33,0x37,0x3f,0x70f,0x63f],q=Math.SQRT1_2,a=Math.sqrt(3)/2,r=Math.sqrt(3/8);
const weights=[[1,0],[0,1],[q,q],[q,q],[a,.5],[.5,a],[q,0],[0,q],[r,r],[a,.5],[.5,a]];
function pcm(bits=16,C=2,valid=bits,float=false,ext=true){
 const N=4609,raw=Buffer.alloc(N*C*bits/8),native=Buffer.alloc(N*C*8),expected=Buffer.alloc(N*8),fmt=Buffer.alloc(ext?40:16),w=[];
 for(let bit=0;bit<11;bit++)if(masks[C-1]&(1<<bit))w.push(weights[bit]);const sum=[0,0];for(const row of w){sum[0]+=row[0];sum[1]+=row[1];}const scale=(C<=4?1:2)/Math.max(...sum);
 fmt.writeUInt16LE(ext?0xfffe:float?3:1);fmt.writeUInt16LE(C,2);fmt.writeUInt32LE(48000,4);fmt.writeUInt32LE(48000*C*bits/8,8);fmt.writeUInt16LE(C*bits/8,12);fmt.writeUInt16LE(bits,14);
 if(ext){fmt.writeUInt16LE(22,16);fmt.writeUInt16LE(valid,18);fmt.writeUInt32LE(masks[C-1],20);fmt.writeUInt32LE(float?3:1,24);Buffer.from('00001000800000aa00389b71','hex').copy(fmt,28);}
 let seed=0x76492351;
 for(let i=0;i<N;i++){
  const samples=[];for(let c=0;c<C;c++){
   seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;const at=(i*C+c)*bits/8;let s;
   if(float){s=(seed>>8)/16777216;if(bits===32){s=Math.fround(s);raw.writeFloatLE(s,at);}else raw.writeDoubleLE(s,at);}
   else{let v=Number(BigInt.asIntN(valid,BigInt(seed)));if(i%11===0)v=-(2**(valid-1));if(i%11===1)v=2**(valid-1)-1;const stored=v*2**(bits-valid);s=stored*2**(1-bits);if(bits===8)raw.writeUInt8(stored+128,at);else if(bits===16)raw.writeInt16LE(stored,at);else if(bits===24)raw.writeIntLE(stored,at,3);else raw.writeInt32LE(stored,at);}
   samples.push(s);native.writeDoubleLE(s,(i*C+c)*8);
  }
  let left=0,right=0;if(C<=2){left=samples[0];right=samples[C===1?0:1];}else for(let c=0;c<C;c++){left+=samples[c]*(w[c][0]*scale);right+=samples[c]*(w[c][1]*scale);}expected.writeFloatLE(left,i*8);expected.writeFloatLE(right,i*8+4);
 }return {fmt,raw,expected,native,N,C,bits,valid,float};
}
function container(kind,m,opt={}){
 const table=opt.table??[],ds=Buffer.alloc(28+table.length*12+(opt.extraDs??0));ds.writeBigUInt64LE(BigInt(opt.dsData??m.raw.length),8);ds.writeBigUInt64LE(BigInt(opt.count??(kind==='RF64'?m.N:0)),16);ds.writeUInt32LE(table.length,24);
 table.forEach((e,i)=>{ds.write(e.id,28+i*12);ds.writeBigUInt64LE(BigInt(e.size),32+i*12);});
 const parts=[chunk('ds64',ds),...(opt.before??[]),chunk('fmt ',m.fmt),...(opt.preData??[]),chunk('data',m.raw,!opt.finiteData),...(opt.after??[])],body=Buffer.concat(parts),h=Buffer.alloc(12);h.write(kind);h.writeUInt32LE(opt.finiteTop?body.length+4:0xffffffff,4);h.write('WAVE',8);ds.writeBigUInt64LE(BigInt(body.length+4));parts[0]=chunk('ds64',ds);return Buffer.concat([h,...parts]);
}
const results=[],malformed=[],sparse=[];let guarded=0,seeks=0,cancels=0,reopens=0;
function verify(name,kind,m,opt={}){
 const file=path.join(dir,name+'.wav'),wanted=file+'.expected.f32',out=file+'.ours.f32',data=container(kind,m,opt);fs.writeFileSync(file,data);fs.writeFileSync(wanted,m.expected);remove(out);run(cli,['--decode',file,out]);if(!fs.readFileSync(out).equals(m.expected))throw Error('PCM mismatch '+name);
 const seek=JSON.parse(run(path.join(oracle,'seek-oracle.exe'),[file,wanted,'0','0'])),guard=JSON.parse(run(path.join(oracle,'pcm-bounds-oracle.exe'),[file,wanted]));run(path.join(oracle,'seek-oracle.exe'),[file,wanted,'3']);
 let reference='original container';const ref=file+'.reference.f64',args=[];
 const rawReference=(!m.float&&Math.ceil(m.valid/8)*8!==m.bits)||opt.count===0xffffffffffffffffn||opt.dsData===0xffffffffffffffffn||opt.table?.length||opt.extraDs;
 if(rawReference){const raw=file+'.reference.raw';fs.writeFileSync(raw,m.raw);args.push('-f',m.float?(m.bits===32?'f32le':'f64le'):({8:'u8',16:'s16le',24:'s24le',32:'s32le'})[m.bits],'-ar','48000','-ac',String(m.C),'-i',raw);reference='raw physical PCM; FFmpeg valid-precision, ds64-table, padding or ignored-field limitation';}
 else args.push('-i',file);
 ff([...args,'-c:a','pcm_f64le','-f','f64le',ref]);if(!fs.readFileSync(ref).equals(m.native))throw Error('FFmpeg channel mismatch '+name);
 guarded+=guard.guarded_reads;seeks+=seek.checks;cancels+=guard.cancel_checks+1;reopens+=guard.reopen_checks;
 results.push({file:path.basename(file),kind,channels:m.C,container_bits:m.bits,valid_bits:m.valid,float:m.float,frames:m.N,reference,...seek,...guard});if(results.length%64===0)console.log('Verified RF64/BW64 files: '+results.length);
}
for(const kind of ['RF64','BW64'])for(const [bits,float] of [[8,false],[16,false],[24,false],[32,false],[32,true],[64,true]])for(let C=1;C<=8;C++)for(const ext of [false,true])verify(`${kind}-${bits}-${float}-${C}-${ext}`,kind,pcm(bits,C,bits,float,ext));
for(const kind of ['RF64','BW64'])for(const bits of [8,16,24,32])for(let valid=1;valid<=bits;valid++)for(const C of [1,8])verify(`${kind}-precision-${bits}-${valid}-${C}`,kind,pcm(bits,C,valid));
const m=pcm();
for(const kind of ['RF64','BW64']){
 const fact=Buffer.alloc(4);fact.writeUInt32LE(m.N);const sentinelFact=Buffer.alloc(4,255);
 for(const [name,opt] of [
  ['finite-sizes',{finiteTop:true,finiteData:true,dsData:0xffffffffffffffffn,count:0xffffffffffffffffn}],
  ['finite-data',{finiteData:true,dsData:0xffffffffffffffffn}],['finite-top',{finiteTop:true}],
  ['unknown-count',{count:0}],['ignored-count',{count:0xffffffffffffffffn}],
  ['odd-metadata',{before:[chunk('JUNK',Buffer.from('odd'))],after:[chunk('LIST',Buffer.from('INFO')),chunk('tail',Buffer.from('x'))]}],
  ['fact-before',{preData:[chunk('fact',fact)]}],['fact-after',{after:[chunk('fact',fact)]}],
  ['ds64-extension',{extraDs:5}],
  ['repeat-tables',{table:[{id:'meta',size:3},{id:'meta',size:5}],before:[chunk('meta',Buffer.from('abc'),true)],after:[chunk('meta',Buffer.from('12345'),true)]}],
  ['table-order',{table:[{id:'last',size:2},{id:'JUNK',size:3}],before:[chunk('JUNK',Buffer.from('abc'),true)],after:[chunk('last',Buffer.from('xy'),true)]}],
  ['table-limit',{table:Array.from({length:4096},()=>({id:'meta',size:1})),after:Array.from({length:4096},()=>chunk('meta',Buffer.from('x'),true))}]
 ])verify(`${kind}-${name}`,kind,m,opt);
 if(kind==='RF64')verify('RF64-fact64',kind,m,{preData:[chunk('fact',sentinelFact)]});
}
verify('unicode-灯-лампа-ضوء-🎵','BW64',m,{count:0xffffffffffffffffn});
function reject(name,kind,mutate,opt={}){const file=path.join(dir,'bad-'+name+'.wav');fs.writeFileSync(file,mutate(container(kind,m,opt)));const r=cp.spawnSync(cli,['--check',file],{encoding:'utf8',timeout:5000});if(r.status!==2||!(/decode_error=[1-9]/.test(r.stdout)||/Unsupported, malformed/.test(r.stdout)))throw Error('Malformed accepted '+name+' '+r.status+' '+r.stdout);malformed.push({file:path.basename(file),result:'rejected'});}
for(const kind of ['RF64','BW64']){
 for(const [name,offset,bytes,value] of [['wave',8,4,0],['missing-ds64',12,4,0],['ds64-small',16,4,27],['ds64-sentinel',16,4,0xffffffff],['table-truncated',44,4,1],['table-cap',44,4,4097],['riff-overflow',20,8,0xffffffffffffffffn],['riff-outside',20,8,1n<<63n],['riff-short',20,8,3n],['riff-cut',20,8,40n],['data-overflow',28,8,0xffffffffffffffffn],['data-outside',28,8,1n<<63n],['data-partial',28,8,BigInt(m.raw.length-1)]])reject(kind+'-'+name,kind,b=>{if(bytes===4)b.writeUInt32LE(value,offset);else b.writeBigUInt64LE(value,offset);return b;});
 reject(kind+'-late-ds64',kind,b=>Buffer.concat([b.subarray(0,12),b.subarray(48,96),b.subarray(12,48),b.subarray(96)]));
 reject(kind+'-duplicate-ds64',kind,b=>b,{after:[chunk('ds64',Buffer.alloc(28))]});
 reject(kind+'-duplicate-fmt',kind,b=>b,{after:[chunk('fmt ',m.fmt)]});
 reject(kind+'-duplicate-data',kind,b=>b,{after:[chunk('data',Buffer.alloc(4))]});
 reject(kind+'-tail-truncated',kind,b=>b.subarray(0,-1),{after:[chunk('JUNK',Buffer.from('abc'))]});
 reject(kind+'-tail-fragment',kind,b=>b,{after:[Buffer.from('xx')]});
 reject(kind+'-missing-table',kind,b=>b,{after:[chunk('meta',Buffer.from('x'),true)]});
 reject(kind+'-unused-table',kind,b=>b,{table:[{id:'meta',size:1}]});
 reject(kind+'-wrong-table-id',kind,b=>b,{table:[{id:'oops',size:1}],after:[chunk('meta',Buffer.from('x'),true)]});
 reject(kind+'-reused-table',kind,b=>b,{table:[{id:'meta',size:1}],after:[chunk('meta',Buffer.from('x'),true),chunk('meta',Buffer.from('x'),true)]});
 reject(kind+'-table-size-overflow',kind,b=>b,{table:[{id:'meta',size:0xffffffffffffffffn}],after:[chunk('meta',Buffer.from('x'),true)]});
 const badFact=Buffer.alloc(4);badFact.writeUInt32LE(m.N+1);reject(kind+'-fact-mismatch',kind,b=>b,{after:[chunk('fact',badFact)]});
 reject(kind+'-fact-short',kind,b=>b,{after:[chunk('fact',Buffer.alloc(3))]});
 const fact=Buffer.alloc(4);fact.writeUInt32LE(m.N);reject(kind+'-fact-duplicate',kind,b=>b,{preData:[chunk('fact',fact)],after:[chunk('fact',fact)]});
}
reject('RF64-fact64-mismatch','RF64',b=>b,{count:m.N+1,after:[chunk('fact',Buffer.alloc(4,255))]});reject('BW64-fact64-undefined','BW64',b=>b,{after:[chunk('fact',Buffer.alloc(4,255))]});
// Seeded mutations always put a nonzero high word in a selected size: these
// tiny files cannot contain the claimed extent, regardless of the low word.
let fuzz=0x839f1073;for(let i=0;i<256;i++){
 fuzz^=fuzz<<13;fuzz^=fuzz>>>17;fuzz^=fuzz<<5;const value=(BigInt((fuzz>>>0)||1)<<32n)|BigInt((fuzz^0x79231abc)>>>0),kind=i&1?'RF64':'BW64';
 if(i%3===2)reject(`seeded-table-${i}`,kind,b=>b,{table:[{id:'meta',size:value}],after:[chunk('meta',Buffer.from('x'),true)]});
 else reject(`seeded-size-${i}`,kind,b=>{b.writeBigUInt64LE(value,i%3===0?20:28);return b;});
}
for(const kind of [1,2])for(const [bits,C,float,mode] of [[8,1,0,0],[16,2,0,0],[24,2,0,0],[32,1,0,0],[32,2,1,0],[64,2,1,0],[16,2,0,1],[16,2,0,2]]){
 const file=path.join(dir,`sparse-${kind}-${bits}-${C}-${float}-${mode}.wav`),r=JSON.parse(run(path.join(oracle,'rf64-sparse-oracle.exe'),[file,String(kind),String(bits),String(C),String(float),String(mode)]));
 try{
  // LAMP has already checked the original nonzero BW64 dummy above. FFmpeg
  // n8.0.1 reads it as a signed RF64 count and rejects UINT64_MAX. Normalize
  // only that ignored field for the external parser/PCM comparison.
  if(kind===2){const fd=fs.openSync(file,'r+');try{fs.writeSync(fd,Buffer.alloc(8),0,8,36);}finally{fs.closeSync(fd);}}
  let duration=null,input,header=kind===2?'BW64 dummy normalized to zero; original UINT64_MAX checked by LAMP':'original RF64';
  if(mode){
   input=['-skip_initial_bytes',String(r.data_offset+r.reference_frame*C*bits/8),'-f',float?(bits===32?'f32le':'f64le'):({8:'u8',16:'s16le',24:'s24le',32:'s32le'})[bits],'-ar','48000','-ac',String(C),'-i',file];header='raw PCM at known 64-bit data offset; FFmpeg ignores ds64 metadata table';
  }else{
   const probe=JSON.parse(run('ffprobe',['-v','error','-show_entries','stream=duration_ts,sample_rate,channels','-of','json',file])).streams[0];duration=probe.duration_ts;
   if(Number(probe.sample_rate)!==48000||probe.channels!==C||duration!==r.frames)throw Error('FFprobe framing mismatch '+file);
   input=['-ss',String(r.reference_seconds),'-i',file];
  }
  const ref=file+'.reference.f32';ff([...input,'-af','atrim=end_sample=257','-c:a','pcm_f32le','-f','f32le',ref]);if(!fs.readFileSync(ref).equals(fs.readFileSync(file+'.channels.f32')))throw Error('Sparse FFmpeg PCM mismatch '+file);
  sparse.push({file:path.basename(file),kind:kind===1?'RF64':'BW64',container_bits:bits,channels:C,float:!!float,metadata:mode,...r,reference_duration_frames:duration,reference_pcm:'257 native-channel samples at a bounded offset/seek',reference_header:header});seeks+=r.seek_checks;cancels+=r.cancel_checks;reopens+=r.reopen_checks;
 }finally{remove(file);}
}
const report={suite:'RF64/BW64 framing and large files',result:'passed',reference:'EBU Tech 3306 (2009); ITU-R BS.2088-2 (2025); FFmpeg independent native-channel PCM; original numeric stereo and sparse-file oracles',reference_version:run('ffmpeg',['-version']).split('\n')[0].trim(),files:results.length,sparse_files:sparse.length,seek_checks:seeks,guarded_reads:guarded,cancel_checks:cancels,reopen_checks:reopens,rejections:malformed.length,maximum_logical_bytes:Math.max(...sparse.map(x=>x.logical_bytes)),maximum_allocated_bytes:Math.max(...sparse.map(x=>x.allocated_bytes)),results,sparse,malformed};
fs.writeFileSync(path.join(dir,'rf64-verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({files:report.files,sparse_files:report.sparse_files,seek_checks:seeks,rejections:report.rejections,result:report.result}));
