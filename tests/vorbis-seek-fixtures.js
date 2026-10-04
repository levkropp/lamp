'use strict';
const fs=require('fs'),path=require('path'),cp=require('child_process');
const [cli,probe,directory]=process.argv.slice(2).map(x=>path.resolve(x));fs.mkdirSync(directory,{recursive:true});const checks=[];
function run(exe,args){const r=cp.spawnSync(exe,args,{encoding:'utf8',maxBuffer:8*1024*1024});if(r.error||r.status!==0)throw Error(`${exe} (${r.status}): ${r.stderr||r.error} ${r.stdout}`);return r.stdout;}
function ff(args){return run('ffmpeg',['-hide_banner','-loglevel','error','-y',...args]);}
function check(file,mono,{vector=false,reference,kind='encoded'}={}){
 const continuous=file+'.continuous.f32';fs.rmSync(continuous,{force:true});run(cli,['--decode',file,continuous]);const frames=fs.statSync(continuous).size/8;
 if(!reference){reference=file+'.reference.f32';const delay=vector?0:Number(JSON.parse(run('ffprobe',['-v','error','-select_streams','a','-show_packets','-show_entries','packet=duration','-of','json',file])).packets[0].duration);
  const filter=`atrim=start_sample=${delay}:end_sample=${delay+frames}`+(mono?',pan=stereo|c0=c0|c1=c0':'');ff([...(vector?['-c:a','libvorbis']:[]),'-flags2','+skip_manual','-i',file,'-af',filter,'-f','f32le',reference]);
 }
 const accuracy=JSON.parse(run(process.execPath,[path.join(__dirname,'compare-pcm.js'),continuous,reference,...(vector?['65','0.000062']:[])]));
 const result=JSON.parse(run(probe,[file,continuous,'0','131072']));if(!result.advanced||!result.index_points)throw Error('Vorbis index did not advance at '+file);
 checks.push({file:path.basename(file),kind,...result,continuous_reference:accuracy});return {file,continuous,reference,frames};
}
function packets(data){const out=[];let partial=[];for(let at=0;at<data.length;){const n=data[at+26];let o=at+27+n;for(let j=0;j<n;j++){const size=data[at+27+j];partial.push(data.subarray(o,o+size));o+=size;if(size<255){out.push(Buffer.concat(partial));partial=[];}}at=o;}return out;}
function crc(data){let c=0;for(const b of data){c=(c^(b<<24))>>>0;for(let j=0;j<8;j++)c=((c<<1)^((c>>>31)?0x04c11db7:0))>>>0;}return c;}
function repage(source,file,{laces=255,pad=false,origin=0,first=0,frames,audioOverride}={}){
 const p=packets(fs.readFileSync(source)),audio=audioOverride||p.slice(3+first),short=1<<(p[0][28]&15),long=1<<(p[0][28]>>4),synthetic=p[0][28]===0x66;
 const pages=[];let seq=0,continued=false;
 function page(parts,gp,eos=false){const body=Buffer.concat(parts.map(s=>s.data)),head=Buffer.alloc(27+parts.length);head.write('OggS');head[5]=(seq===0?2:continued?1:0)|(eos?4:0);head.writeBigInt64LE(BigInt(gp),6);head.writeUInt32LE(13371337,14);head.writeUInt32LE(seq++,18);head[26]=parts.length;parts.forEach((s,i)=>head[27+i]=s.data.length);const out=Buffer.concat([head,body]);out.writeUInt32LE(crc(out),22);pages.push(out);continued=parts.at(-1).data.length===255;}
 function segments(packet,gp,index){const out=[];for(let j=0;j<packet.length;j+=255)out.push({data:packet.subarray(j,Math.min(j+255,packet.length)),gp:-1,index});if(packet.length%255===0)out.push({data:Buffer.alloc(0),gp:-1,index});out.at(-1).gp=gp;out.at(-1).complete=true;return out;}
 for(let i=0;i<3;i++){const s=segments(p[i],0,-1);for(let j=0;j<s.length;j+=255){const group=s.slice(j,j+255);page(group,group.at(-1).complete?0:-1);}}
 let raw=0;const all=[];
 for(let i=0;i<audio.length;i++){
  let packet=audio[i];const big=!synthetic&&!!(packet[0]&2),n=big?long:short,left=big&&!(packet[0]&4)?(long-short)/4:0,right=big&&!(packet[0]&8)?(3*long-short)/4:n/2;
  raw+=i?right-left:right-n/2;let gp=raw-(right-n/2)+origin;if(origin<0&&i===0)gp=0;if(i===audio.length-1)gp=frames+origin;
  if(pad)packet=Buffer.concat([packet,Buffer.alloc(Math.ceil((packet.length+510)/255)*255-packet.length)]);
  all.push(...segments(packet,gp,i));
 }
 let batch=[],gp=-1;
 for(let i=0;i<all.length;i++){const segment=all[i];batch.push(segment);if(segment.complete)gp=segment.gp;
  if(batch.length===laces||i===all.length-1||((origin!==0||first!==0)&&segment.complete&&segment.index<2)){page(batch,gp,i===all.length-1);batch=[];gp=-1;}
 }
 fs.writeFileSync(file,Buffer.concat(pages));return {audio,short,long};
}
let base;
for(const rate of [8000,16000,22050,32000,44100,48000,96000,192000])for(const channels of [1,2])for(const quality of [0,8]){
 const file=path.join(directory,`seek-vorbis-${rate}-${channels}-q${quality}.ogg`);ff(['-f','lavfi','-i',`aevalsrc=0.4*sin(2*PI*317*t)|0.31*sin(2*PI*751*t):s=${rate}:d=7.723`,'-ac',String(channels),'-c:a','libvorbis','-q:a',String(quality),file]);const result=check(file,channels===1);if(rate===48000&&channels===2&&quality===8)base=result;
}
let transient;
for(const rate of [8000,48000,192000])for(const pattern of ['noise','transients']){
 const file=path.join(directory,`seek-vorbis-${rate}-${pattern}.ogg`),signal=pattern==='noise'?`anoisesrc=r=${rate}:d=17.723:seed=7351:a=0.6`:`aevalsrc=if(lt(mod(t\\,0.073)\\,0.001)\\,0.6*sin(2*PI*2999*t)\\,0.03*sin(2*PI*61*t))|0.21*sin(2*PI*431*t):s=${rate}:d=17.723`;
 ff(['-f','lavfi','-i',signal,'-ac','2','-c:a','libvorbis','-q:a','4',file]);const result=check(file,false);if(rate===48000&&pattern==='transients')transient=result;
}
for(const laces of [1,3,7,255]){
 const file=path.join(directory,`seek-vorbis-continued-${laces}.ogg`);repage(transient.file,file,{laces,pad:true,frames:transient.frames});check(file,false,{reference:transient.reference,kind:'continued audio / zero terminal laces'});
}
for(const origin of [-17,-128,12345,48000]){
 const file=path.join(directory,`seek-vorbis-origin-${origin}.ogg`),reference=file+'.reference.f32';repage(base.file,file,{laces:7,origin,frames:base.frames});fs.writeFileSync(reference,fs.readFileSync(base.reference).subarray(Math.max(0,-origin)*8));check(file,false,{reference,kind:'cropped/positive granule origin'});
}
// A cropped stream can start with a long block whose next block is short.
// Retain its unwindowed right prefix instead of dropping it during priming.
const t=packets(fs.readFileSync(transient.file)),id=t[0],short=1<<(id[28]&15),long=1<<(id[28]>>4);let raw=0,first=-1,offset=0;
for(let i=3;i<t.length;i++){const packet=t[i],big=!!(packet[0]&2),n=big?long:short,left=big&&!(packet[0]&4)?(long-short)/4:0,right=big&&!(packet[0]&8)?(3*long-short)/4:n/2;if(first<0&&i>5&&big&&!(packet[0]&8)){first=i-3;offset=raw+n/2-left;break;}raw+=i===3?right-n/2:right-left;}
if(first<0)throw Error('Independent transient encoder supplied no long/short transition');
for(const origin of [0,-17,23456]){const file=path.join(directory,`seek-vorbis-first-long-${origin}.ogg`),reference=file+'.reference.f32';repage(transient.file,file,{laces:7,origin,first,frames:transient.frames-offset});fs.writeFileSync(reference,fs.readFileSync(transient.reference).subarray((offset+Math.max(0,-origin))*8));check(file,false,{reference,kind:'first long-to-short prefix / granule origin'});}
const vectorDirectory=path.join(directory,'vectors');fs.mkdirSync(vectorDirectory,{recursive:true});ff(['-f','lavfi','-i','sine=frequency=317:sample_rate=48000:duration=0.37','-ac','2','-c:a','libvorbis','-q:a','0',path.join(vectorDirectory,'vorbis-48000-2-q0.ogg')]);
const vectors=run(process.execPath,[path.join(__dirname,'ogg-vectors.js'),vectorDirectory]).trim().split(/\r?\n/).map(JSON.parse);let capacitySource;
for(const item of vectors.filter(x=>x.valid)){
 if(!path.basename(item.path).startsWith('vorbis-vector-')){check(item.path,item.mono,{kind:'continued large comment'});continue;}
 const p=packets(fs.readFileSync(item.path)),audio=Array(41).fill(p.slice(3)).flat(),file=path.join(directory,path.basename(item.path).replace('.ogg','-extended.ogg'));repage(item.path,file,{laces:7,frames:(audio.length-1)*32,audioOverride:audio});check(file,item.mono,{vector:true,kind:'residue/codebook structural vector'});capacitySource=item;
}
const capacityPackets=packets(fs.readFileSync(capacitySource.path));
const audio=Array.from({length:65537},(_,i)=>capacityPackets[3+i%5]);
const capacityFile=path.join(directory,'seek-vorbis-index-capacity.ogg');repage(capacitySource.path,capacityFile,{frames:65536*32,audioOverride:audio});const capacity=check(capacityFile,capacitySource.mono,{vector:true,kind:'adaptive index compaction'});
const last=checks.at(-1);if(last.maximum_stride!==64||last.index_points!==1025)throw Error('Adaptive Vorbis compaction not exercised');
for(const mode of ['3','6'])if(JSON.parse(run(probe,[base.file,base.continuous,mode])).result!=='rejected')throw Error('Cancelled Vorbis work accepted');
function mutatePages(file,destination,modify){const data=Buffer.from(fs.readFileSync(file));for(let at=0;at<data.length;){let length=27+data[at+26];for(let i=0;i<data[at+26];i++)length+=data[at+27+i];const page=data.subarray(at,at+length);modify(page);page.writeUInt32LE(0,22);page.writeUInt32LE(crc(page),22);at+=length;}fs.writeFileSync(destination,data);}
let rejected=0;
function reject(file){if(JSON.parse(run(probe,[file,base.continuous,'1'])).result!=='rejected')throw Error('Contradictory Vorbis timestamps accepted');rejected++;}
const badIntermediate=path.join(directory,'bad-vorbis-page-time.ogg');mutatePages(base.file,badIntermediate,page=>{if(page.readUInt32LE(18)===3)page.writeBigInt64LE(page.readBigInt64LE(6)+1n,6);});reject(badIntermediate);
const badOrigin=path.join(directory,'bad-vorbis-origin-flush.ogg');mutatePages(base.file,badOrigin,page=>{if(page.readUInt32LE(18)>=2&&page.readBigInt64LE(6)>=0n)page.writeBigInt64LE(page.readBigInt64LE(6)+12345n,6);});reject(badOrigin);
const badFinal=path.join(directory,'bad-vorbis-final-time.ogg');mutatePages(base.file,badFinal,page=>{if(page[5]&4)page.writeBigInt64LE(0x123456789n,6);});reject(badFinal);
const report={result:'passed',scope:'Sparse packet/lace seek checkpoints and exact previous-packet overlap; byte-exact continuous assembly PCM and independent FFmpeg PCM comparison, all supported rates/channels/quality extremes, transients/noise, continued audio and comments, zero terminal laces, positive/cropped granule origins, initial long-to-short prefixes, EOF/clamping/canaries, fresh reopen, allocation release, adaptive 64-KiB index compaction, CRC-valid contradictory timestamps and cancelled seek/open',checks,cancelled_seeks:1,cancelled_opens:1,rejected_timestamps:rejected};
fs.writeFileSync(path.join(directory,'vorbis-seek-verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({result:'passed',files:checks.length,seek_checks:checks.reduce((n,c)=>n+c.checks,0),capacity:{points:last.index_points,stride:last.maximum_stride}}));
