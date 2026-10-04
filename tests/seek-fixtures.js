'use strict';
// Independent FLAC packet locations come from ffprobe; encode only in tests.
const fs=require('fs'),path=require('path'),cp=require('child_process');
const indexOnly=process.argv[2]==='--index-flac';
const [cli,probe,directory]=indexOnly?[]:process.argv.slice(2).map(x=>path.resolve(x));
if(!indexOnly)fs.mkdirSync(directory,{recursive:true});
const checks=[];
function run(exe,args){const r=cp.spawnSync(exe,args,{encoding:'utf8',maxBuffer:8*1024*1024});if(r.error||r.status!==0)throw new Error(`${exe} failed (${r.status}): ${r.stderr||r.error} ${r.stdout}`);return r.stdout;}
function ff(args){return run('ffmpeg',['-hide_banner','-loglevel','error','-y',...args]);}
function reference(file,mono){const output=file+'.reference.f32';ff(['-i',file,...(mono?['-af','pan=stereo|c0=c0|c1=c0']:[]),'-c:a','pcm_f32le','-f','f32le',output]);return output;}
function check(file,pcm,indexed){run(cli,['--check',file]);const result=JSON.parse(run(probe,[file,pcm,'0']));if(indexed&&!result.advanced)throw new Error('No advanced seek at '+file);checks.push({file:path.basename(file),...result,indexed});}
function crc(data,width){let c=0,top=1<<(width-1),mask=(1<<width)-1,poly=width===8?7:0x8005;for(const b of data){c^=b<<(width-8);for(let j=0;j<8;j++)c=((c<<1)^((c&top)?poly:0))&mask;}return c;}
function coded(n){n=BigInt(n);if(n<128n)return Buffer.from([Number(n)]);let length=2;while(n>=(1n<<BigInt(length*5+1)))length++;if(length>7)throw Error('Coded number range');const out=Buffer.alloc(length);for(let i=length-1;i>0;i--){out[i]=0x80|Number(n&63n);n>>=6n;}out[0]=((0xff<<(8-length))&255)|Number(n);return out;}
function metadata(data){let at=4,last;for(;;){last=at;const count=data.readUIntBE(at+1,3),final=data[at]&128;at+=4+count;if(final)return {prefix:Buffer.from(data.subarray(0,at)),start:at,last};}}
function variableFrame(frame,sample){
 let end=5;if(frame[4]>=128){let b=frame[4],count=0;while(b&128){count++;b=(b<<1)&255;}end=4+count;}
 const numberEnd=end,block=frame[2]>>4,rate=frame[2]&15;end+=block===6?1:block===7?2:0;end+=rate===12?1:rate===13||rate===14?2:0;
 if(crc(frame.subarray(0,end),8)!==frame[end]||crc(frame.subarray(0,-2),16)!==frame.readUInt16BE(frame.length-2))throw Error('Independent source frame CRC failed');
 const fixed=Buffer.from(frame.subarray(0,4));fixed[1]|=1;
 const head=Buffer.concat([fixed,coded(sample),frame.subarray(numberEnd,end)]);
 const prefix=Buffer.concat([head,Buffer.from([crc(head,8)]),frame.subarray(end+1,-2)]),tail=Buffer.alloc(2);tail.writeUInt16BE(crc(prefix,16));return Buffer.concat([prefix,tail]);
}
function indexedFlac(file,variable){
 const data=fs.readFileSync(file),meta=metadata(data),packets=JSON.parse(run('ffprobe',['-v','error','-select_streams','a:0','-show_packets','-of','json',file])).packets;
 const frames=packets.map(p=>{const raw=data.subarray(Number(p.pos),Number(p.pos)+Number(p.size));return variable?variableFrame(raw,p.pts):Buffer.from(raw);});
 let offset=0;const points=[];for(let i=0;i<frames.length;i++){if(i%3===0){const b=Buffer.alloc(18);b.writeBigUInt64BE(BigInt(packets[i].pts));b.writeBigUInt64BE(BigInt(offset),8);b.writeUInt16BE(Number(packets[i].duration),16);points.push(b);}offset+=frames[i].length;}
 points.push(Buffer.alloc(18,255),Buffer.alloc(18,255));
 const body=Buffer.concat(points),header=Buffer.alloc(4);header[0]=0x83;header.writeUIntBE(body.length,1,3);meta.prefix[meta.last]&=127;
 const out=Buffer.concat([meta.prefix,header,body,...frames]),destination=file+(variable?'.variable-index.flac':'.index.flac');fs.writeFileSync(destination,out);
 return {file:destination,data:out,table:meta.start+4,header:meta.start,count:points.length};
}
if(indexOnly){const indexed=indexedFlac(path.resolve(process.argv[3]),false);fs.copyFileSync(indexed.file,path.resolve(process.argv[4]));process.exit(0);}
for(const rate of [8000,48000,192000])for(const channels of [1,2])for(const encoding of ['pcm_u8','pcm_s16le','pcm_s24le','pcm_s32le','pcm_f32le']){
 const file=path.join(directory,`seek-${rate}-${channels}-${encoding}.wav`);ff(['-f','lavfi','-i',`aevalsrc=0.43*sin(2*PI*317*t)|0.31*sin(2*PI*751*t):s=${rate}:d=0.723`,'-ac',String(channels),'-c:a',encoding,file]);check(file,reference(file,channels===1),true);
}
let corruptSource,corruptPcm;
for(const rate of [8000,44100,96000])for(const channels of [1,2])for(const bits of ['s16','s32']){
 const file=path.join(directory,`seek-${rate}-${channels}-${bits}.flac`);ff(['-f','lavfi','-i',`aevalsrc=0.43*sin(2*PI*317*t)|0.31*sin(2*PI*751*t):s=${rate}:d=3.723`,'-ac',String(channels),'-c:a','flac','-sample_fmt',bits,file]);const pcm=reference(file,channels===1);check(file,pcm,false);
 for(const variable of [false,true]){const indexed=indexedFlac(file,variable);check(indexed.file,pcm,true);corruptSource=indexed;corruptPcm=pcm;}
}
const original=corruptSource;let rejected=0;
function reject(name,modify,kind){const data=Buffer.from(original.data);modify(data);const file=path.join(directory,'bad-'+name+'.flac');fs.writeFileSync(file,data);const result=JSON.parse(run(probe,[file,corruptPcm,String(kind)]));if(result.result!=='rejected')throw Error('Malformed seek table accepted');rejected++;}
reject('length',b=>b.writeUIntBE(original.count*18-1,original.header+1,3),1);
reject('duplicate',b=>b.copy(b,original.table+18,original.table,original.table+8),1);
reject('unsorted',b=>b.writeBigUInt64BE(1n,original.table+36),1);
reject('late-placeholder',b=>b.writeBigUInt64BE(0xffffffffffffffffn,original.table+18),1);
reject('offset',b=>b.writeBigUInt64BE(0xffffffffffffffffn,original.table+8),1);
reject('zero-block',b=>b.writeUInt16BE(0,original.table+16),1);
reject('big-block',b=>b.writeUInt16BE(65535,original.table+16),1);
reject('sample-bound',b=>b.writeBigUInt64BE(0x1000000000n,original.table),1);
// Change the last real point, selected by the maximal request in error mode2.
const last=original.table+(original.count-3)*18;
reject('frame-offset',b=>b.writeBigUInt64BE(b.readBigUInt64BE(last+8)+1n,last+8),2);
reject('frame-sample',b=>b.writeBigUInt64BE(b.readBigUInt64BE(last)+1n,last),2);
reject('frame-count',b=>b.writeUInt16BE(b.readUInt16BE(last+16)-1,last+16),2);
// CRC-valid constant frames isolate noncanonical coded-number rejection.
function constantFlac(number){
 const info=Buffer.alloc(42);info.write('fLaC');info[4]=0x80;info.writeUIntBE(34,5,3);info.writeUInt16BE(16,8);info.writeUInt16BE(16,10);info.writeBigUInt64BE((8000n<<44n)|(15n<<36n)|16n,18);
 const head=Buffer.from([255,248,96,8,...number,15]),prefix=Buffer.concat([head,Buffer.from([crc(head,8),0,0,0])]),tail=Buffer.alloc(2);tail.writeUInt16BE(crc(prefix,16));return Buffer.concat([info,prefix,tail]);
}
const canonical=path.join(directory,'coded-canonical.flac');fs.writeFileSync(canonical,constantFlac([0]));run(cli,['--check',canonical]);
for(let length=2;length<=7;length++){
 const number=Array(length).fill(128);number[0]=(255<<(8-length))&255;const file=path.join(directory,`coded-overlong-${length}.flac`);fs.writeFileSync(file,constantFlac(number));const r=cp.spawnSync(cli,['--check',file],{encoding:'utf8'});if(r.status!==2||!/decode_error=[1-9]/.test(r.stdout))throw Error('Noncanonical FLAC number accepted');rejected++;
}
const report={result:'passed',scope:'Sample-exact WAV direct seeking and FLAC fixed/variable seek-table positioning against independent FFmpeg PCM, fresh reopen per target, EOF/clamping, canaries/untouched output, closed-state refusal, malformed index bounds/frame validation and CRC-valid noncanonical coded numbers; MP3/Vorbis/Opus indexes remain pending',checks,rejected,rejected_indexes:11,rejected_coded_numbers:6};
fs.writeFileSync(path.join(directory,'seek-verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({result:'passed',files:checks.length,seek_checks:checks.reduce((n,c)=>n+c.checks,0),rejected}));
