'use strict';
const fs=require('fs'),path=require('path'),cp=require('child_process');
const [cli,probe,directory]=process.argv.slice(2).map(x=>path.resolve(x));fs.mkdirSync(directory,{recursive:true});const checks=[];
function run(exe,args){const r=cp.spawnSync(exe,args,{encoding:'utf8',maxBuffer:8*1024*1024});if(r.error||r.status!==0)throw Error(`${exe} (${r.status}): ${r.stderr||r.error} ${r.stdout}`);return r.stdout;}
function ff(args){return run('ffmpeg',['-hide_banner','-loglevel','error','-y',...args]);}
function check(file,kind='encoded'){
 const result=JSON.parse(run(probe,[file]));if(result.frames>9600&&!result.advanced)throw Error('Opus index failed to advance: '+file);
 checks.push({file:path.basename(file),kind,...result});console.log(path.basename(file)+' '+JSON.stringify(result));return file;
}
let base;
run(probe,['--generate',directory]);
for(const name of fs.readdirSync(directory).filter(name=>/^seek-opus-native-\d+-\d\.opus$/.test(name)))check(path.join(directory,name),name.includes('-32-')?'native mode/channel transitions':name.includes('-33-')?'native DTX/speech transitions':'native forced configuration');
for(const rate of [8000,16000,48000])for(const channels of [1,2])for(const duration of [2.5,5,10,20,40,60,120]){
 const file=path.join(directory,`seek-opus-${rate}-${channels}-${duration}.opus`),application=duration<10?'lowdelay':rate<48000?'voip':'audio',bitrate=rate<48000&&duration>=10?'24k':'64k';
 ff(['-f','lavfi','-i',`aevalsrc=0.2*sin(2*PI*317*t)+0.07*sin(2*PI*71*t)|0.17*sin(2*PI*751*t):s=${rate}:d=7.723`,'-ac',String(channels),'-c:a','libopus','-application',application,'-frame_duration',String(duration),'-b:a',bitrate,file]);check(file);if(rate===48000&&channels===2&&duration===20)base=file;
}
for(const [pattern,signal] of [
 ['noise','anoisesrc=r=48000:d=17.723:seed=7351:a=0.6'],
 ['transients','aevalsrc=if(lt(mod(t\\,0.073)\\,0.001)\\,0.6*sin(2*PI*2999*t)\\,0.03*sin(2*PI*61*t))|0.21*sin(2*PI*431*t):s=48000:d=17.723'],
 ['silence','anullsrc=r=48000:cl=stereo:d=7.723']
])for(const vbr of ['off','on','constrained']){
 const file=path.join(directory,`seek-opus-${pattern}-${vbr}.opus`);ff(['-f','lavfi','-i',signal,'-ac','2','-c:a','libopus','-b:a','48k','-vbr',vbr,'-fec','1','-packet_loss','20',file]);check(file,pattern+' / '+vbr);
}
function packets(data){const out=[];let partial=[];for(let at=0;at<data.length;){const n=data[at+26];let o=at+27+n;for(let j=0;j<n;j++){const size=data[at+27+j];partial.push(data.subarray(o,o+size));o+=size;if(size<255){out.push(Buffer.concat(partial));partial=[];}}at=o;}return out;}
function crc(data){let c=0;for(const b of data){c=(c^(b<<24))>>>0;for(let j=0;j<8;j++)c=((c<<1)^((c>>>31)?0x04c11db7:0))>>>0;}return c;}
function samples(packet){const toc=packet[0],code=toc&3,frames=code===0?1:code===3?packet[1]&63:2;let n;if(toc&128)n=120<<((toc>>3)&3);else if((toc&96)===96)n=toc&8?960:480;else n=[480,960,1920,2880][(toc>>3)&3];return n*frames;}
function padded(packet){
 if((packet[0]&3)!==0)throw Error('Padding fixture requires an independently encoded one-frame packet');
 for(let p=510;p<1024;p++){let remain=p,bytes=[];while(remain>=255){bytes.push(255);remain-=254;}bytes.push(remain);const length=2+bytes.length+packet.length-1+p;
  if(length%255===0)return Buffer.concat([Buffer.from([(packet[0]&~3)|3,65,...bytes]),packet.subarray(1),Buffer.alloc(p)]);
 }throw Error('Could not construct exact terminal-zero lace');
}
function repage(file,{laces=255,pad=false,skip,gain=0,origin=0,first=0,comment=0,audioOverride,trim=17}={}){
 const data=fs.readFileSync(base),p=packets(data),head=Buffer.from(p[0]),audio=audioOverride||p.slice(2+first);if(skip!==undefined)head.writeUInt16LE(skip,10);head.writeInt16LE(gain,16);
 let tags=p[1];if(comment){tags=Buffer.alloc(comment+16);tags.write('OpusTags');tags.writeUInt32LE(comment,8);tags.fill(118,12,12+comment);}
 const pages=[];let sequence=0,continued=false;
 function segments(packet,gp){const out=[];for(let at=0;at<packet.length;at+=255)out.push({data:packet.subarray(at,at+255),gp:-1});if(packet.length%255===0)out.push({data:Buffer.alloc(0),gp:-1});out.at(-1).gp=gp;out.at(-1).complete=true;return out;}
 function page(group,gp,eos=false){const head=Buffer.alloc(27+group.length);head.write('OggS');head[5]=(sequence===0?2:continued?1:0)|(eos?4:0);head.writeBigInt64LE(BigInt(gp),6);head.writeUInt32LE(13371337,14);head.writeUInt32LE(sequence++,18);head[26]=group.length;group.forEach((s,i)=>head[27+i]=s.data.length);const out=Buffer.concat([head,...group.map(s=>s.data)]);out.writeUInt32LE(crc(out),22);pages.push(out);continued=group.at(-1).data.length===255;}
 for(const packet of [head,tags]){const all=segments(packet,0);for(let j=0;j<all.length;j+=255){const group=all.slice(j,j+255);page(group,group.at(-1).complete?0:-1);}}
 let raw=0,group=[],gp=-1;
 for(let i=0;i<audio.length;i++){raw+=samples(audio[i]);const all=segments(pad?padded(audio[i]):audio[i],origin+raw-(i===audio.length-1?trim:0));
  for(let j=0;j<all.length;j++){const s=all[j];group.push(s);if(s.complete)gp=s.gp;if(group.length===laces||(i===audio.length-1&&j===all.length-1)){page(group,gp,i===audio.length-1&&j===all.length-1);group=[];gp=-1;}}
 }fs.writeFileSync(file,Buffer.concat(pages));return file;
}
for(const laces of [1,3,7,255])check(repage(path.join(directory,`seek-opus-continued-${laces}.opus`),{laces,pad:true}), 'continued audio / terminal zero laces');
for(const skip of [0,1,3839,3840,65535])check(repage(path.join(directory,`seek-opus-preskip-${skip}.opus`),{laces:7,skip}), 'pre-skip');
for(const gain of [-32768,-256,256,32767])check(repage(path.join(directory,`seek-opus-gain-${gain}.opus`),{gain,origin:12345}), 'signed header gain / positive granule origin');
for(const origin of [0,12345,0x123456789])check(repage(path.join(directory,`seek-opus-cropped-${origin}.opus`),{laces:7,first:73,skip:3840,origin}), 'cropped packets / granule origin');
check(repage(path.join(directory,'seek-opus-continued-comment.opus'),{comment:130050}), 'continued large comments');
function size(n){if(n<252)return Buffer.from([n]);const first=252+(n&3);return Buffer.from([first,(n-first)>>2]);}
const framePackets=packets(fs.readFileSync(base)).slice(2);
for(const [code,vbr] of [[1,false],[2,true],[3,false],[3,true]]){
 const audio=framePackets.map(packet=>{if((packet[0]&3)!==0)throw Error('Framing fixture requires single-frame input');const payload=packet.subarray(1),n=code===3?3:2,header=[(packet[0]&~3)|code];if(code===3)header.push(n|(vbr?128:0));const lengths=code===2?[size(payload.length)]:code===3&&vbr?[size(payload.length),size(payload.length)]:[];return Buffer.concat([Buffer.from(header),...lengths,...Array(n).fill(payload)]);});
 check(repage(path.join(directory,`seek-opus-framing-${code}-${vbr}.opus`),{laces:7,audioOverride:audio}), 'RFC packet framing code '+code+(vbr?' VBR':' CBR'));
}
const capacityPackets=packets(fs.readFileSync(path.join(directory,'seek-opus-48000-2-2.5.opus'))),silent=Buffer.from([0x80]);
check(repage(path.join(directory,'seek-opus-index-capacity.opus'),{skip:0,audioOverride:Array.from({length:65537},(_,i)=>i%5===0?silent:capacityPackets[3+i%7]),trim:0}), 'adaptive index compaction / nonzero PCM and DTX');
const last=checks.at(-1);if(last.maximum_stride!==64||last.index_points!==1025)throw Error('Adaptive Opus compaction not exercised');
if((checks.reduce((mask,c)=>mask|c.configuration_mask,0)>>>0)!==0xffffffff||checks.reduce((mask,c)=>mask|c.framing_code_mask,0)!==15||!checks.some(c=>c.dtx_packets>0))throw Error('Required Opus configurations/framing/DTX were not exercised');
const report={result:'passed',reference:'Hash-verified RFC6716 + RFC8251 native decoder; independent Ogg packet reader and packet-duration API',scope:'48kHz family0 mono/stereo packet seek positions; at least3840 raw samples pre-roll, separate initial pre-skip, sample-accurate packet boundaries, reference decoder initialized at identical independently selected boundary; whole continuous PCM additionally checked, but seeks need not be byte-identical to uninterrupted history; continued audio/comments, zero terminal laces, signed gains, positive/cropped origins, EOF/clamping/canaries, allocation release, adaptive64-KiB compaction and cancelled seek/open',scale_adjusted_absolute_tolerance:0.00004,checks};
fs.writeFileSync(path.join(directory,'opus-seek-verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({result:'passed',files:checks.length,seek_checks:checks.reduce((n,c)=>n+c.seek_checks,0),capacity:{points:last.index_points,stride:last.maximum_stride}}));
