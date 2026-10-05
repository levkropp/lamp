// Original Ogg structure and Vorbis residue vectors. Test helpers only.
const fs=require('fs'), path=require('path');
const root=process.argv[2];
function crc(b) { let c=0; for(let i=0;i<b.length;i++){ c=(c^(b[i]<<24))>>>0;for(let j=0;j<8;j++) c=((c<<1)^((c>>>31)?0x04c11db7:0))>>>0; } return c; }
function page(body,laces,seq,flags,gp=0n) {
 const h=Buffer.alloc(27+laces.length);h.write('OggS');h[5]=flags;h.writeBigInt64LE(gp,6);h.writeUInt32LE(123456,14);h.writeUInt32LE(seq,18);h[26]=laces.length;Buffer.from(laces).copy(h,27);
 const p=Buffer.concat([h,body]);p.writeUInt32LE(crc(p),22);return p;
}
function repacket(data) {const packets=[];let partial=[];for(let i=0;i<data.length;){let n=data[i+26],o=i+27+n;for(let j=0;j<n;j++){let len=data[i+27+j];partial.push(data.subarray(o,o+len));o+=len;if(len<255){packets.push(Buffer.concat(partial));partial=[];}}i=o;}return packets;}
function emit(name,data,valid,mono=false) {const p=path.join(root,name+'.ogg');fs.writeFileSync(p,data);console.log(JSON.stringify({path:p,valid,mono}));}
const original=fs.readFileSync(path.join(root,'vorbis-48000-2-q0.ogg'));
function mutate(name,fn,fix=true) {const b=Buffer.from(original);fn(b);if(fix){let n=b[26],len=27+n;for(let i=0;i<n;i++)len+=b[27+i];b.writeUInt32LE(0,22);b.writeUInt32LE(crc(b.subarray(0,len)),22);}emit(name,b,false);}
mutate('ogg-bad-crc',b=>b[b.length-1]^=1,false);
mutate('ogg-version',b=>b[4]=1);
mutate('ogg-reserved',b=>b[5]|=8);
mutate('ogg-first-sequence',b=>b.writeUInt32LE(1,18));
mutate('ogg-first-continued',b=>b[5]|=1);
mutate('vorbis-channel-zero',b=>b[39]=0);
mutate('vorbis-block-order',b=>b[56]=0x67);
mutate('vorbis-ident-version',b=>b[35]=1);
emit('ogg-truncated',original.subarray(0,original.length-1),false);
emit('ogg-chained',Buffer.concat([original,original]),false);
// Large comment packet crosses multiple pages; final lace is exactly 255.
const packets=repacket(original), vendor=Buffer.alloc(130050,65);
const comment=Buffer.alloc(7+4+vendor.length+4+1);comment.write('\x03vorbis');comment.writeUInt32LE(vendor.length,7);vendor.copy(comment,11);comment[comment.length-1]=1;
let pages=[page(packets[0],[packets[0].length],0,2)],seq=1,o=0;
while(o<comment.length){let l=[],chunks=[];for(let j=0;j<255&&o<comment.length;j++){let len=Math.min(255,comment.length-o);l.push(len);chunks.push(comment.subarray(o,o+len));o+=len;}pages.push(page(Buffer.concat(chunks),l,seq++,seq>2?1:0,o<comment.length?-1n:0n));}
const setup=packets[2],sl=[];for(let i=0;i<Math.floor(setup.length/255);i++)sl.push(255);sl.push(setup.length%255);
pages.push(page(setup,sl,seq++,0,0n));
const audio=packets.slice(3),al=[],ab=[];for(const p of audio){for(let i=0;i<Math.floor(p.length/255);i++)al.push(255);al.push(p.length%255);ab.push(p);}
pages.push(page(Buffer.concat(ab),al,seq++,4,17760n));emit('ogg-large-comment',Buffer.concat(pages),true);
class Bits {constructor(){this.a=[];} put(v,n){for(let i=0;i<n;i++)this.a.push((v>>>i)&1);} bytes(){let b=Buffer.alloc(Math.ceil(this.a.length/8));this.a.forEach((v,i)=>b[i>>3]|=v<<(i&7));return b;}}
function vector(type,ch,ordered,sparse,sequence,coupled) {
 const id=Buffer.alloc(30);id.write('\x01vorbis');id[11]=ch;id.writeUInt32LE(48000,12);id[28]=0x66;id[29]=1;
 const co=Buffer.alloc(16);co.write('\x03vorbis');co[15]=1;
 const s=new Bits();s.put(1,8);
 for(let k=0;k<2;k++){
  s.put(0x564342,24);s.put(k?2:1,16);s.put(k?2:1,24);s.put(ordered?1:0,1);
  if(ordered){s.put(0,5);s.put(k?2:1,k?2:1);}
  else {s.put(sparse?1:0,1);for(let j=0;j<(k?2:1);j++){if(sparse)s.put(1,1);s.put(0,5);}}
  s.put(k?2:0,4);if(k){s.put(0xe0100000,32);s.put(0x60100000,32);s.put(1,4);s.put(sequence?1:0,1);[0,1,2,3].forEach(x=>s.put(x,2));}
 }
 s.put(0,6);s.put(0,16);s.put(0,6);s.put(1,16);s.put(0,5);s.put(0,2);s.put(5,4);
 s.put(0,6);s.put(type,16);s.put(0,24);s.put(type===2?32*ch:32,24);s.put(15,24);s.put(0,6);s.put(0,8);s.put(1,3);s.put(0,1);s.put(1,8);
 s.put(0,6);s.put(0,16);s.put(0,1);s.put(coupled?1:0,1);if(coupled){s.put(0,8);s.put(0,1);s.put(1,1);}s.put(0,2);s.put(0,8);s.put(0,8);s.put(0,8);
 s.put(0,6);s.put(0,1);s.put(0,16);s.put(0,16);s.put(0,8);s.put(1,1);
 const setup=Buffer.concat([Buffer.from('\x05vorbis'),s.bytes()]);const out=[page(id,[30],0,2),page(Buffer.concat([co,setup]),[co.length,setup.length],1,0)];
 const bs=[];for(let f=0;f<5;f++){const a=new Bits();a.put(0,1);for(let c=0;c<ch;c++){a.put(1,1);a.put(190+c*5,8);a.put(180+c*5,8);}let groups=type===2?1:ch,parts=type===2?ch*2:2;for(let p=0;p<parts;p++){for(let c=0;c<groups;c++)a.put(0,1);for(let c=0;c<groups;c++)for(let i=0;i<8;i++)a.put((f+p+c+i)&1,1);}bs.push(a.bytes());}
 out.push(page(Buffer.concat(bs),bs.map(b=>b.length),2,4,128n));return Buffer.concat(out);
}
for(const type of [0,1,2])for(const ch of [1,2])for(const coding of ['plain','ordered','sparse'])for(const sequence of [false,true])emit(`vorbis-vector-r${type}-c${ch}-${coding}-s${+sequence}`,vector(type,ch,coding==='ordered',coding==='sparse',sequence,ch===2),true,ch===1);
