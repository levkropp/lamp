'use strict';
// Original Vorbis mapping/residue constructor and independent routing oracle.
const {exe,windows}=require('./platform'),objectSuffix=windows?'.obj':'.o';
const fs=require('fs'),path=require('path'),cp=require('child_process');
const [cli,oracle,dir]=process.argv.slice(2).map(x=>path.resolve(x));fs.mkdirSync(dir,{recursive:true});
const selection=process.env.LAMP_VORBIS_CASE?new RegExp(process.env.LAMP_VORBIS_CASE):null;
function run(exe,args){const r=cp.spawnSync(exe,args,{encoding:'utf8',windowsHide:true,maxBuffer:8*1024*1024,timeout:120000});if(r.error||r.status)throw Error(`${path.basename(exe)} ${args.join(' ')}: ${r.status} ${r.stderr||r.error} ${r.stdout}`);return r.stdout;}
function remove(file){try{fs.unlinkSync(file);}catch(e){if(e.code!=='ENOENT')throw e;}}
function ff(args){return run('ffmpeg',['-hide_banner','-loglevel','error','-y',...args]);}
class Bits{
 constructor(){this.data=Buffer.alloc(2048);this.at=0;}
 reserve(bits){const size=Math.ceil((this.at+bits)/8);if(size>this.data.length){const b=Buffer.alloc(Math.max(size,this.data.length*2));this.data.copy(b);this.data=b;}}
 put(v,n){this.reserve(n);for(let i=0;i<n;i++,this.at++)this.data[this.at>>3]|=((v>>>i)&1)<<(this.at&7);}
 zeros(n){this.reserve(n);this.at+=n;}
 bytes(){return Buffer.from(this.data.subarray(0,Math.ceil(this.at/8)));}
}
function crc(data){let c=0;for(const b of data){c=(c^(b<<24))>>>0;for(let i=0;i<8;i++)c=((c<<1)^((c>>>31)?0x04c11db7:0))>>>0;}return c;}
function pack(packets,granules,{laces=255}={}){
 const pages=[];let seq=0;for(let i=0;i<packets.length;i++){
  const p=packets[i],segments=[];for(let at=0;at<p.length;at+=255)segments.push(p.subarray(at,at+255));if(p.length%255===0)segments.push(Buffer.alloc(0));
  for(let j=0;j<segments.length;j+=laces){const group=segments.slice(j,j+laces),last=j+group.length===segments.length,h=Buffer.alloc(27+group.length);h.write('OggS');h[5]=(seq===0?2:j?1:0)|(i===packets.length-1&&last?4:0);h.writeBigInt64LE(BigInt(last?granules[i]:-1),6);h.writeUInt32LE(0x1371471,14);h.writeUInt32LE(seq++,18);h[26]=group.length;group.forEach((b,k)=>h[27+k]=b.length);const page=Buffer.concat([h,...group]);page.writeUInt32LE(crc(page),22);pages.push(page);}
 }return Buffer.concat(pages);
}
function packets(data){const out=[];let partial=[];for(let at=0;at<data.length;){const n=data[at+26];let o=at+27+n;for(let j=0;j<n;j++){const size=data[at+27+j];partial.push(data.subarray(o,o+size));o+=size;if(size<255){out.push(Buffer.concat(partial));partial=[];}}at=o;}return out;}
function gcd(a,b){while(b)[a,b]=[b,a%b];return a;}
function vector(opt={}){
 const C=opt.C??6,type=opt.type??2,N=opt.N??64,F=opt.F??5,dim=opt.dim??1,submaps=opt.submaps??1,mux=opt.mux??Array.from({length:C},()=>0),couples=opt.couples??[],present=opt.present??Array.from({length:C},()=>true),coding=opt.coding??'plain',sequence=opt.sequence??false;
 // Xiph's decodevv helper rounds each partition to channel boundaries. Align
 // reference-comparison fixtures; unaligned partitions have a spec math oracle.
 const counts=Array.from({length:submaps},(_,s)=>mux.filter(x=>x===s).length);
 const part=opt.part??(type===2?2*counts.filter(Boolean).reduce((n,c)=>n/gcd(n,c)*c,1):16);
 const id=Buffer.alloc(30);id.write('\x01vorbis');id[11]=C;id.writeUInt32LE(48000,12);const log=Math.log2(N);id[28]=log*17;id[29]=1;
 const co=Buffer.alloc(16);co.write('\x03vorbis');co[15]=1;const s=new Bits();s.put(1+(opt.largeBooks??0),8);
 function book(entries,d,lookup){s.put(0x564342,24);s.put(d,16);s.put(entries,24);s.put(coding==='ordered'?1:0,1);
  const len=Math.ceil(Math.log2(entries))||1;if(coding==='ordered'){s.put(len-1,5);s.put(entries,Math.floor(Math.log2(entries))+1);}else{s.put(coding==='sparse'?1:0,1);for(let j=0;j<entries;j++){if(coding==='sparse')s.put(1,1);s.put(len-1,5);}}
  s.put(lookup,4);if(lookup){s.put(0xe0100000,32);s.put(0x60100000,32);s.put(entries===2?1:0,4);s.put(sequence?1:0,1);if(entries===2)[0,1,2,3].forEach(v=>s.put(v,2));else s.zeros(entries*d);}
 }
 book(1,dim,0);book(2,2,2);for(let i=0;i<(opt.largeBooks??0);i++)book(16384,256,2);
 s.put(0,6);s.put(0,16);s.put(0,6);s.put(1,16);s.put(0,5);s.put(0,2);s.put(log-1,4);
 s.put(submaps-1,6);for(let sub=0;sub<submaps;sub++){const count=mux.filter(x=>x===sub).length;s.put(type,16);s.put(0,24);s.put(type===2?N/2*count:N/2,24);s.put(part-1,24);s.put(0,6);s.put(0,8);s.put(1,3);s.put(0,1);s.put(1,8);}
 s.put(0,6);s.put(0,16);s.put(submaps>1?1:0,1);if(submaps>1)s.put(submaps-1,4);s.put(couples.length?1:0,1);if(couples.length){s.put(couples.length-1,8);const width=Math.ceil(Math.log2(C));for(const [m,a]of couples){s.put(m,width);s.put(a,width);}}
 s.put(opt.reserved??0,2);if(submaps>1)for(const sub of mux)s.put(sub,4);for(let sub=0;sub<submaps;sub++){s.put(0,8);s.put(opt.floorIndex??0,8);s.put(opt.residueIndex??sub,8);}
 s.put(0,6);s.put(0,1);s.put(0,16);s.put(0,16);s.put(0,8);s.put(1,1);const setup=Buffer.concat([Buffer.from('\x05vorbis'),s.bytes()]);
 const audio=[];for(let f=0;f<F;f++){
  const a=new Bits();a.put(0,1);const active=[...present];for(let c=0;c<C;c++){a.put(present[c]?1:0,1);if(present[c]){a.put(160+(c*7+f*3)%65,8);a.put(150+(c*11+f*5)%70,8);}}
  for(const [m,b]of couples)if(active[m]||active[b])active[m]=active[b]=true;
  for(let sub=0;sub<submaps;sub++){
   const channels=Array.from({length:C},(_,c)=>c).filter(c=>mux[c]===sub),groups=type===2?[channels.some(c=>active[c])]:channels.map(c=>active[c]),parts=Math.floor((N/2)*(type===2?channels.length:1)/part);
   for(let base=0;base<parts;base+=dim){for(const enabled of groups)if(enabled)a.put(0,1);for(let p=base;p<Math.min(base+dim,parts);p++)for(let g=0;g<groups.length;g++)if(groups[g]){const words=type===0?Math.floor(part/2):Math.ceil(part/2);for(let j=0;j<words;j++)a.put((f+p+g+j)&1,1);}}
  }audio.push(a.bytes());
 }
 const all=[id,co,setup,...audio],granules=[0,0,0,...audio.map((_,f)=>f*N/2)];return {data:pack(all,granules,opt),packets:all,granules,C,frames:(F-1)*N/2,opt:{...opt,C,type,N,F,part,dim}};
}
// Independent Vorbis-spec residue-2 placement, dB floor, direct cosine inverse
// MDCT and sine-window overlap. No decoder tables, FFT or parser are reused.
function* spectrumFrames(m){
 const {C,N,F,part,type}=m.opt;if(type!==2||m.opt.submaps||m.opt.couples||m.opt.sequence||part%2)throw Error('Unsupported mathematical fixture');const half=N/2;
 for(let f=0;f<F;f++){
  const spectrum=Array.from({length:C},()=>Array(half).fill(0));
  for(let p=0;p<Math.floor(half*C/part);p++)for(let j=0;j<part/2;j++){
   const word=(f+p+j)&1;for(let d=0;d<2;d++){const index=p*part+2*j+d;spectrum[index%C][Math.floor(index/C)]=word?1+d:-1+d;}
  }
  yield spectrum.map((s,c)=>{
   const y0=160+(c*7+f*3)%65,y1=150+(c*11+f*5)%70;
   const dy=y1-y0,base=Math.trunc(dy/half),rem=Math.abs(dy)-Math.abs(base)*half;
   return s.map((v,k)=>Math.fround(v*Math.fround(Math.exp((y0+base*k+Math.sign(dy)*Math.floor(k*rem/half)-255)*140*Math.LN10/20/256))));
  });
 }
}
function spectrumReference(m){const {C,N,F}=m.opt,out=Buffer.alloc(12+C*N/2*F*4);[C,N,F].forEach((v,i)=>out.writeUInt32LE(v,i*4));let at=12;for(const s of spectrumFrames(m))for(const channel of s)for(const v of channel){out.writeFloatLE(v,at);at+=4;}return out;}
function mathReference(m){
 const {C,N}=m.opt;if(N>128)throw Error('Direct cosine oracle block too large');const half=N/2,out=Buffer.alloc(m.frames*C*4),window=Array.from({length:half},(_,i)=>Math.sin(Math.PI/2*Math.sin(Math.PI*(i+.5)/N)**2));
 const kernel=Array.from({length:N},(_,i)=>Array.from({length:half},(_,k)=>Math.cos(2*Math.PI/N*(i+.5+N/4)*(k+.5))));let previous,f=0;
 for(const spectrum of spectrumFrames(m)){
  const time=spectrum.map(s=>kernel.map(row=>Math.fround(row.reduce((n,v,k)=>n+v*s[k],0))));
  if(previous)for(let i=0;i<half;i++)for(let c=0;c<C;c++)out.writeFloatLE(time[c][i]*window[i]+previous[c][half+i]*window[half-i-1],((f-1)*half*C+i*C+c)*4);
  previous=time;f++;
 }return out;
}
const q=Math.SQRT1_2,a=Math.sqrt(3)/2,r=Math.sqrt(3/8),weights=[[1,0],[0,1],[q,q],[q,q],[a,.5],[.5,a],[q,0],[0,q],[r,r],[a,.5],[.5,a]],roles=[[2],[0,1],[0,2,1],[0,1,4,5],[0,2,1,4,5],[0,2,1,4,5,3],[0,2,1,9,10,8,3],[0,2,1,9,10,4,5,3]];
function stereo(native,C){if(native.length%(C*4))throw Error('Invalid native PCM length');const N=native.length/C/4,out=Buffer.alloc(N*8);let coeff;
 if(C>2&&C<=8){const rows=roles[C-1].map(x=>weights[x]),sum=rows.reduce((v,row)=>[v[0]+row[0],v[1]+row[1]],[0,0]),scale=(C<=4?1:2)/Math.max(...sum);coeff=rows.map(row=>row.map(v=>v*scale));}
 for(let i=0;i<N;i++){let l=0,r=0;if(coeff){for(let c=0;c<C;c++){const x=native.readFloatLE((i*C+c)*4);l+=x*coeff[c][0];r+=x*coeff[c][1];}}else{l=native.readFloatLE(i*C*4);r=C===1?l:native.readFloatLE((i*C+1)*4);}out.writeFloatLE(l,i*8);out.writeFloatLE(r,i*8+4);}return out;
}
function accuracy(ours,ref){if(ours.length!==ref.length)throw Error(`Native lengths differ ${ours.length}/${ref.length}`);let error=0,signal=0,peak=0,peakError=0;for(let i=0;i<ours.length;i+=4){const x=ours.readFloatLE(i),y=ref.readFloatLE(i);if(!Number.isFinite(x)||!Number.isFinite(y))throw Error('Nonfinite native PCM');const d=x-y;signal+=y*y;error+=d*d;peak=Math.max(peak,Math.abs(y));peakError=Math.max(peakError,Math.abs(d));}const snr=error?10*Math.log10(signal/error):null,scaled=peakError/(1+peak);if(scaled>0.00004||snr!==null&&snr<90)throw Error('Native PCM differs '+JSON.stringify({snr,scaled,peakError,peak}));return {values:ours.length/4,snr_db:snr,scaled_peak_error:scaled,peak_error:peakError,reference_peak:peak};}
const results=[],malformed=[];
function verify(name,m){if(selection&&!selection.test(name))return;const file=path.join(dir,name+'.ogg'),native=file+'.native.f32',reference=file+'.reference.f32',ours=file+'.ours.f32',want=file+'.stereo.f32';fs.writeFileSync(file,m.data);
 const bounds=JSON.parse(run(exe(oracle,'vorbis-native-oracle'),[file,native,[1,2,3,8,9,16,64,128,255].includes(m.C)?'64':'8']));if(bounds.channels!==m.C||bounds.frames!==m.frames)throw Error('Incorrect metadata '+name);
 if(m.math)fs.writeFileSync(reference,mathReference(m));else if(m.spectra){const spectra=file+'.spectra.f32';fs.writeFileSync(spectra,spectrumReference(m));run(exe(oracle,'vorbis-native-reference'),['--spectra',spectra,reference]);}else run(exe(oracle,'vorbis-native-reference'),[file,reference]);const values=fs.readFileSync(native),ref=fs.readFileSync(reference);let comparison;try{comparison=accuracy(values,ref);}catch(e){throw Error(name+': '+e.message);}fs.writeFileSync(want,stereo(values,m.C));remove(ours);run(cli,['--decode',file,ours]);if(!fs.readFileSync(ours).equals(fs.readFileSync(want)))throw Error('Stereo assignment/rounding differs '+name);
 const seeks=JSON.parse(run(exe(oracle,'seek-oracle'),[file,want,'0']));if(m.capacity&&(seeks.maximum_stride!==64||seeks.index_points!==1025||!seeks.advanced))throw Error('Multichannel index compaction not exercised');run(exe(oracle,'seek-oracle'),[file,want,'3']);results.push({file:path.basename(file),kind:m.kind??'original mapping/residue vector',...bounds,stereo_seeks:seeks.checks,index_points:seeks.index_points,index_stride:seeks.maximum_stride,...comparison});if(results.length%25===0)console.log('Verified multichannel Vorbis files: '+results.length);
}
for(let C=1;C<=255;C++)verify('count-'+C,vector({C}));
for(let C=1;C<=255;C++)verify('unaligned-'+C,{...vector({C,part:16}),math:true,kind:'independent specification residue/floor/cosine/window oracle'});
for(const type of [0,1])for(const C of [1,2,3,4,5,6,7,8,9,16,32,64,127,128,129,254,255])verify(`residue-${type}-${C}`,vector({C,type}));
for(const C of [3,6,8,9,16,255])for(const type of [0,1,2])for(const pattern of ['first-silent','last-only','silent','submaps','coupled']){
 const opt={C,type};if(pattern==='first-silent')opt.present=Array.from({length:C},(_,i)=>i>1);if(pattern==='last-only')opt.present=Array.from({length:C},(_,i)=>i===C-1);if(pattern==='silent')opt.present=Array(C).fill(false);if(pattern==='submaps'){opt.submaps=3;opt.mux=Array.from({length:C},(_,i)=>i%3);}if(pattern==='coupled')opt.couples=[[0,C-1],[C-1,1],[1,C===3?0:C-2]];verify(`${pattern}-r${type}-c${C}`,vector(opt));
}
for(const C of [3,8,255])for(const dim of [3,255,256])verify(`classword-${C}-${dim}`,vector({C,dim}));
for(const C of [3,8,255])for(const type of [0,1,2])verify(`large-block-${C}-${type}`,vector({C,type,N:8192,F:3,dim:256}));
for(const C of [9,32,128,255])verify(`class-capacity-${C}`,{...vector({C,N:8192,F:3,part:2,dim:256}),spectra:true,kind:'specification residue/floor with Xiph inverse MDCT; classification capacity'});
for(const coding of ['ordered','sparse'])for(const C of [3,6,8,255])verify(`${coding}-${C}`,vector({C,coding,sequence:true}));
verify('all-256-couplings',vector({C:255,present:Array(255).fill(false),couples:Array.from({length:256},(_,i)=>[i%255,(i+1)%255])}));
verify('sixteen-submaps',vector({C:255,submaps:16,mux:Array.from({length:255},(_,i)=>i%16)}));
verify('continued-audio',vector({C:8,F:65,laces:1}));
verify('native-\u66F2\u2603-\u00E9',vector({C:8}));
if(!selection||selection.test('multichannel-index-capacity'))verify('multichannel-index-capacity',{...vector({C:3,F:65537}),capacity:true,kind:'nonzero multichannel adaptive index compaction'});
for(const R of [8000,16000,22050,32000,44100,48000,96000,192000])for(let C=1;C<=8;C++)for(const quality of [0,8]){
 const name=`modern-${R}-${C}-q${quality}`;if(selection&&!selection.test(name))continue;const file=path.join(dir,name+'.encoded.ogg'),layout=['mono','stereo','3.0','quad','5.0','5.1','6.1','7.1'][C-1];const signal=Array.from({length:C},(_,i)=>`.11*sin(2*PI*${317+i*137}*t)+.025*sin(2*PI*${53+i*11}*t)`).join('|');ff(['-f','lavfi','-i',`aevalsrc=${signal}:s=${R}:d=1.373:c=${layout}`,'-c:a','libvorbis','-q:a',String(quality),file]);const data=fs.readFileSync(file);verify(name,{data,C,frames:Math.round(R*1.373),kind:'modern libvorbis encoder'});
}
function reject(name,m){if(selection&&!selection.test(name))return;const file=path.join(dir,'bad-'+name+'.ogg');fs.writeFileSync(file,m.data);const r=cp.spawnSync(cli,['--check',file],{encoding:'utf8',windowsHide:true,timeout:15000});if(r.status!==2||!(/decode_error=[1-9]/.test(r.stdout)||/Unsupported, malformed/.test(r.stdout)))throw Error('Malformed stream accepted '+name+' '+r.stdout);const checks=JSON.parse(run(exe(oracle,'vorbis-native-oracle'),[file,'--reject']));malformed.push({file:path.basename(file),...checks});}
reject('couple-outside',vector({C:3,couples:[[0,3]]}));reject('couple-equal',vector({C:255,couples:[[254,254]]}));reject('couple-255',vector({C:255,couples:[[0,255]]}));reject('mux-outside',vector({C:255,submaps:3,mux:Array(255).fill(3)}));reject('combined-arena-cap',vector({C:255,largeBooks:2}));
reject('floor-index',vector({C:255,floorIndex:1}));reject('residue-index',vector({C:255,residueIndex:1}));reject('mapping-reserved',vector({C:255,reserved:1}));
for(const C of [3,6,8,9,128,255]){const m=vector({C});m.packets[m.packets.length-1]=Buffer.from([2]);m.data=pack(m.packets,m.granules);reject('truncated-final-'+C,m);}
const hash=file=>require('crypto').createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const report={suite:'Vorbis native multichannel and stereo routing',scope:selection?.source??'all',result:'passed',reference:'Unmodified Xiph libvorbis 1.3.7 + libogg 1.3.6 float PCM (pinned archive SHA-256); independent spec residue/floor/direct-cosine/window oracle for unaligned partitions; spec spectra + Xiph inverse MDCT for maximum classification workspaces; original Vorbis mapping/residue vectors; independent stereo weights; modern libvorbis encoder',reference_pins:JSON.parse(fs.readFileSync(path.join(__dirname,'reference','vorbis-reference-hashes.json'),'utf8')),ffmpeg:run('ffmpeg',['-version']).split(/\r?\n/)[0],objects:['decoder','ogg','vorbis','vorbis_transform'].map(name=>({file:name+objectSuffix,sha256:hash(path.join(path.dirname(cli),'obj',name+objectSuffix))})),cli_sha256:hash(cli),files:results.length,native_values:results.reduce((n,x)=>n+x.values,0),minimum_snr_db:Math.min(...results.filter(x=>x.snr_db!==null).map(x=>x.snr_db)),maximum_scaled_error:Math.max(...results.map(x=>x.scaled_peak_error)),native_seek_checks:results.reduce((n,x)=>n+x.native_seeks,0),stereo_seek_checks:results.reduce((n,x)=>n+x.stereo_seeks,0),guarded_reads:results.reduce((n,x)=>n+x.guarded_reads,0),mixed_read_checks:results.reduce((n,x)=>n+x.mixed_read_checks,0),cancel_checks:results.reduce((n,x)=>n+x.cancel_checks+1,0),reopen_checks:results.reduce((n,x)=>n+x.reopen_checks,0),rejections:malformed.length,results,malformed};fs.writeFileSync(path.join(dir,'vorbis-multichannel-verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({files:results.length,native_seeks:report.native_seek_checks,stereo_seeks:report.stereo_seek_checks,rejections:malformed.length,scope:report.scope,result:'passed'}));
