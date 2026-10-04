'use strict';
// Seek PCM must be bit-identical to a continuous assembly decode. Separately
// compare that continuous decode against FFmpeg's independent mp3float codec.
const fs=require('fs'),path=require('path'),cp=require('child_process');
const [cli,probe,directory]=process.argv.slice(2).map(x=>path.resolve(x));
fs.mkdirSync(directory,{recursive:true});
const checks=[];
function run(exe,args){const r=cp.spawnSync(exe,args,{encoding:'utf8',maxBuffer:8*1024*1024});if(r.error||r.status!==0)throw Error(`${exe} (${r.status}): ${r.stderr||r.error} ${r.stdout}`);return r.stdout;}
function ff(args){return run('ffmpeg',['-hide_banner','-loglevel','error','-y',...args]);}
function check(file,mono,rate){
 const continuous=file+'.continuous.f32',reference=file+'.reference.f32';fs.rmSync(continuous,{force:true});run(cli,['--decode',file,continuous]);
 ff(['-c:a','mp3float','-i',file,...(mono?['-af','pan=stereo|c0=c0|c1=c0']:[]),'-c:a','pcm_f32le','-f','f32le',reference]);
 const accuracy=JSON.parse(run(process.execPath,[path.join(__dirname,'compare-pcm.js'),continuous,reference]));
 const result=JSON.parse(run(probe,[file,continuous,'0',String((rate>=32000?1152:576)*3)]));
 if(!result.advanced||!result.index_points)throw Error('MP3 index did not advance at '+file);
 checks.push({file:path.basename(file),...result,continuous_reference:accuracy});
}
for(const rate of [8000,11025,12000,16000,22050,24000,32000,44100,48000])for(const channels of [1,2])for(const mode of ['cbr','vbr']){
 const file=path.join(directory,`seek-mp3-${rate}-${channels}-${mode}.mp3`),bitrate=rate>=32000?'128k':rate>=16000?'64k':'32k';
 ff(['-f','lavfi','-i',`aevalsrc=0.4*sin(2*PI*317*t)+0.03*sin(2*PI*31*t)|0.31*sin(2*PI*751*t):s=${rate}:d=7.723`,'-ac',String(channels),'-c:a','libmp3lame',...(mode==='cbr'?['-b:a',bitrate]:['-q:a','4']),file]);check(file,channels===1,rate);
}
for(const rate of [8000,24000,48000])for(const channels of [1,2]){
 const file=path.join(directory,`seek-mp3-${rate}-${channels}-no-tags.mp3`);
 ff(['-f','lavfi','-i',`sine=frequency=711:sample_rate=${rate}:duration=7.723`,'-ac',String(channels),'-c:a','libmp3lame','-q:a','4','-write_xing','0','-id3v2_version','0',file]);check(file,channels===1,rate);
}
for(const rate of [8000,22050,48000])for(const mode of ['cbr','vbr'])for(const pattern of ['noise','transients']){
 const file=path.join(directory,`seek-mp3-${rate}-${pattern}-${mode}.mp3`),signal=pattern==='noise'?`anoisesrc=r=${rate}:d=17.723:seed=7319:a=0.6`:`aevalsrc=if(lt(mod(t\\,0.073)\\,0.001)\\,0.6*sin(2*PI*2999*t)\\,0.03*sin(2*PI*61*t))|0.21*sin(2*PI*431*t):s=${rate}:d=17.723`;
 ff(['-f','lavfi','-i',signal,'-ac','2','-c:a','libmp3lame',...(mode==='cbr'?['-b:a',rate>=32000?'192k':'64k']:['-q:a','4']),file]);check(file,false,rate);
}
// Extend redistributable original vectors so seeks cross intensity stereo,
// short/mixed/long blocks, CRC protection, every codebook and count1 tables.
const vectors=path.join(directory,'vectors');fs.mkdirSync(vectors,{recursive:true});
const names=run(process.execPath,[path.join(__dirname,'mp3-vectors.js'),vectors]).trim().split(/\r?\n/);
for(const file of names){
 const data=fs.readFileSync(file);if(data.subarray(0,3).toString()==='ID3'||data.subarray(-128,-125).toString()==='TAG')continue;
 const version=(data[1]>>3)&3,rate=version===3?44100:version===2?22050:11025,destination=path.join(directory,path.basename(file).replace('.mp3','-extended.mp3'));
 fs.writeFileSync(destination,Buffer.concat(Array(19).fill(data)));check(destination,false,rate);
}
// Exercise index compaction without allocating a 302 MB PCM reference.
// MPEG-2.5 mono alternates silence and nonzero Huffman pair frames. The
// midpoint must match a small independently checked continuous PCM window.
const frame=Buffer.alloc(72);frame.writeUInt32BE(0xffe318c0);const nonzero=Buffer.from(frame);
function put(data,offset,width,value){for(let i=0;i<width;i++){const at=offset+i,mask=1<<(7-(at&7));data[at>>3]=(data[at>>3]&~mask)|(((value>>>(width-1-i))&1)?mask:0);}}
put(nonzero,41,12,5);put(nonzero,53,9,1);put(nonzero,62,8,190);for(const at of [80,85,90])put(nonzero,at,5,1);
const capacityFrames=Array.from({length:65537},(_,i)=>i%3===0?nonzero:frame),large=path.join(directory,'seek-mp3-index-capacity.mp3');fs.writeFileSync(large,Buffer.concat(capacityFrames));
const window=path.join(directory,'seek-mp3-capacity-window.mp3');fs.writeFileSync(window,Buffer.concat(capacityFrames.slice(32764,32773)));check(window,true,8000);
const capacityReference=window+'.capacity-reference.f32';fs.writeFileSync(capacityReference,fs.readFileSync(window+'.continuous.f32').subarray((4*576+288)*8,(4*576+288+2048)*8));
const capacity=JSON.parse(run(probe,[large,capacityReference,'5']));
const cancelled=JSON.parse(run(probe,[large,large,'3']));if(cancelled.result!=='rejected')throw Error('Cancelled MP3 seek did work');
if(JSON.parse(run(probe,[large,large,'6'])).result!=='rejected')throw Error('Cancelled MP3 index build did work');
for(const delta of [-1,1]){
 const bad=fs.readFileSync(path.join(directory,'seek-mp3-48000-2-vbr.mp3')),xing=bad.indexOf('Xing');if(xing<0||!(bad.readUInt32BE(xing+4)&1))throw Error('Missing independent Xing count');bad.writeUInt32BE(bad.readUInt32BE(xing+8)+delta,xing+8);
 const file=path.join(directory,`bad-xing-count-${delta}.mp3`);fs.writeFileSync(file,bad);if(JSON.parse(run(probe,[file,large,'1'])).result!=='rejected')throw Error('Contradictory Xing count accepted');
}
const report={result:'passed',scope:'Sparse MP3 frame/reservoir index; every MPEG-1/2/2.5 sample rate, mono/stereo, CBR/VBR, encoder delay/padding, absent tags/duration recovery, noise/transients, intensity/short/mixed/CRC/Huffman structural vectors; byte-exact seek PCM against continuous assembly decoding and independent full-file FFmpeg mp3float comparison; EOF/clamping, output canaries, fresh reopen, two-frame pre-roll, bounded header skims, allocation release, adaptive index compaction, contradictory Xing counts and pre-cancelled seek/open',checks,capacity,cancelled_seeks:1,cancelled_opens:1,rejected_xing_counts:2};
fs.writeFileSync(path.join(directory,'mp3-seek-verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({result:'passed',files:checks.length,seek_checks:checks.reduce((n,c)=>n+c.checks,0),capacity}));
