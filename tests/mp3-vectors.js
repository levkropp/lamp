// Original structural vectors; reference encoders rarely emit intensity stereo.
const fs = require('fs'), path = require('path');
const out = process.argv[2];
class Bits {
  constructor() { this.bits = []; }
  put(value, width) { for (let i = width - 1; i >= 0; --i) this.bits.push((value >>> i) & 1); }
  bytes(size = Math.ceil(this.bits.length / 8)) {
    const b = Buffer.alloc(size);
    if (this.bits.length > size * 8) throw new Error('Vector overflow');
    this.bits.forEach((v, i) => { b[i >>> 3] |= v << (7 - (i & 7)); });
    return b;
  }
}
function scales(version, block, mixed, compress, intensity, position) {
  const b = new Bits();
  let sizes, counts;
  if (version === 3) {
    const s = [0,1,2,3,12,5,6,7,9,10,11,13,14,15,18,19][compress];
    sizes = [s >> 2, s >> 2, s & 3, s & 3];
    counts = block === 2 ? (mixed ? [8,9,6,12] : [9,9,6,12]) : [6,5,5,5];
  } else {
    let s = compress >> (intensity ? 1 : 0), group;
    const mods = intensity ? [[5,6,6,1],[4,4,4,1],[4,3,1,1]] : [[5,5,4,4],[5,5,4,1],[4,3,1,1]];
    for (group = 0; group < 3; ++group) {
      const mod = mods[group], product = mod.reduce((x,y) => x*y,1);
      if (s >= product) { s -= product; continue; }
      sizes = Array(4); let factor = 1;
      for (let i = 3; i >= 0; --i) { sizes[i] = Math.floor(s / factor) % mod[i]; factor *= mod[i]; }
      break;
    }
    const partitions = [
      [[6,5,5,5],[6,5,7,3],[11,10,0,0],[7,7,7,0],[6,6,6,3],[8,8,5,0]],
      [[6,9,9,9],[6,9,12,6],[15,18,0,0],[6,15,12,0],[6,12,9,6],[6,18,9,0]],
      [[9,9,9,9],[9,9,12,6],[18,18,0,0],[12,12,12,0],[12,9,9,6],[15,12,9,0]]
    ];
    counts = partitions[block === 2 ? (mixed ? 1 : 2) : 0][group + (intensity ? 3 : 0)];
  }
  for (let i = 0; i < 4; ++i) for (let j = 0; j < counts[i]; ++j) b.put(sizes[i] ? position : 0, sizes[i]);
  return b;
}
function frame(version, block, mixed, mode, compress, position, crc, coding = null) {
  const side = new Bits(), main = new Bits(), granules = version === 3 ? 2 : 1;
  side.put(0, version === 3 ? 9 : 8); // No reservoir dependency.
  side.put(0, version === 3 ? 3 : 2);
  if (version === 3) { side.put(0,4); side.put(0,4); }
  for (let gr = 0; gr < granules; ++gr) for (let ch = 0; ch < 2; ++ch) {
    const current = Array.isArray(block) ? block[gr] : block;
    const currentMixed = current ? mixed : 0;
    const sc = scales(version,current,currentMixed,ch ? compress : 0,ch !== 0, ch ? position : 0);
    const code = coding ? coding.bits : [0,0,0,0,0];
    const table = coding ? coding.table : 1;
    const big = coding && coding.quad ? 0 : 1;
    const part = sc.bits.length + (ch ? 0 : code.length);
    side.put(part,12); side.put(ch ? 0 : big,9); side.put(coding ? coding.gain : 190,8);
    side.put(ch ? compress : 0,version === 3 ? 4 : 9);
    side.put(current ? 1 : 0,1);
    if (current) {
      side.put(current,2); side.put(currentMixed,1); side.put(table,5); side.put(table,5);
      side.put(0,3); side.put(0,3); side.put(0,3);
    } else {
      side.put(table,5); side.put(table,5); side.put(table,5); side.put(0,4); side.put(0,3);
    }
    if (version === 3) side.put(0,1);
    side.put(0,1); side.put(coding && coding.quad ? coding.quad - 1 : 0,1);
    main.bits.push(...sc.bits);
    if (!ch) main.bits.push(...code);
  }
  const rate = version === 3 ? 44100 : version === 2 ? 22050 : 11025;
  const bitrate = version === 3 ? 128000 : 64000;
  const length = Math.floor((version === 3 ? 144 : 72) * bitrate / rate);
  const h = new Bits();
  h.put(0x7ff,11);h.put(version,2);h.put(1,2);h.put(crc ? 0 : 1,1);
  h.put(version === 3 ? 9 : 8,4);h.put(0,2);h.put(0,2);
  h.put(1,2);h.put(mode,2);h.put(0,4);
  const hb=h.bytes(), sb=side.bytes(version === 3 ? 32 : 17);
  let cb=Buffer.alloc(0);
  if (crc) {
    let c=0xffff;
    for (const v of Buffer.concat([hb.subarray(2),sb])) {
      c ^= v << 8;
      for (let i=0;i<8;++i) c=((c<<1)^((c&0x8000)?0x8005:0))&0xffff;
    }
    cb=Buffer.alloc(2);cb.writeUInt16BE(c);
  }
  return Buffer.concat([hb,cb,sb,main.bytes(length-4-cb.length-sb.length)]);
}
const files=[];
for (const version of [3,2,0]) for (const mode of [1,3]) for (const mixed of [-1,0,1]) {
    const name=`mp3-vector-v${version}-i${mode}-m${mixed}.mp3`;
    const sequence = mixed === -1 ? Array(8).fill(0) : [0,1,2,2,3,0,0,0];
    const frames=[];
    for (let i=0;i<8;i+=version === 3 ? 2 : 1) {
      frames.push(frame(version,version === 3 ? sequence.slice(i,i+2) : sequence[i],mixed === 1 ? 1 : 0,mode,0,0,false));
    }
    const file=path.join(out,name); fs.writeFileSync(file,Buffer.concat(frames));files.push(file);
}
for (const [version,compress,position] of [[3,15,6],[2,160,1],[2,161,1],[0,160,1]]) {
  const file=path.join(out,`mp3-vector-pan-${version}-${compress}.mp3`);
  const f=frame(version,0,0,1,compress,position,false);
  fs.writeFileSync(file,Buffer.concat([f,f,f]));files.push(file);
}
const file=path.join(out,'mp3-vector-crc.mp3'), f=frame(3,0,0,1,0,0,true);
fs.writeFileSync(file,Buffer.concat([f,f,f]));files.push(file);
for(const version of [2,3,4]) {
  const header=Buffer.from([0x49,0x44,0x33,version,0,0,0,0,0,0]);
  const file=path.join(out,`mp3-vector-id3v2-${version}.mp3`);
  fs.writeFileSync(file,Buffer.concat([header,f,f,f]));files.push(file);
}
const id3header=Buffer.from([0x49,0x44,0x33,4,0,0x10,0,0,0,0]);
const footer=Buffer.from(id3header);footer.write('3DI');
const footerFile=path.join(out,'mp3-vector-id3-footer.mp3');
fs.writeFileSync(footerFile,Buffer.concat([id3header,footer,f,f,f]));files.push(footerFile);
const tag=Buffer.alloc(128);tag.write('TAG');
const tailFile=path.join(out,'mp3-vector-id3v1.mp3');
fs.writeFileSync(tailFile,Buffer.concat([f,f,f,tag]));files.push(tailFile);
for(const name of files) console.log(name);
// Exercise every legal pair codebook, including maximum linbits escapes.
const tables=fs.readFileSync(path.join(__dirname,'../src/mp3_tables.inc'),'utf8');
function table(name) {
  const section=tables.split(`\n${name}:\n`)[1].split(`.equ ${name}_count`)[0];
  return [...section.matchAll(/^\s*\.(?:byte|short|long)\s+(.+)$/gm)].flatMap(m=>m[1].trim().split(',').map(Number));
}
const huff=table('mp_huff_tabs'), index=table('mp_huff_index'), lin=table('mp_huff_linbits');
const digits=(x,n)=>Array.from({length:n},(_,i)=>(x>>>(n-1-i))&1);
for(let book=0;book<32;book++) {
  if(book===4||book===14) continue;
  let best=null;
  function walk(offset,width,prefix) {
    for(let i=0;i<(1<<width);i++) {
      const leaf=huff[index[book]+offset+i];
      if(leaf<0) walk(-(leaf>>3),leaf&7,prefix.concat(digits(i,width)));
      else {
        const x=leaf&15,y=(leaf>>4)&15;
        if(!best || x+y>best.x+best.y) best={x,y,bits:prefix.concat(digits(i,width).slice(0,leaf>>8))};
      }
    }
  }
  walk(0,5,[]);
  const bits=best.bits.slice();
  for(const [i,v] of [best.x,best.y].entries()) {
    if(v===15) bits.push(...Array(lin[book]).fill(1));
    if(v) bits.push(i&1);
  }
  const magnitude=Math.max(1,best.x,best.y)+(Math.max(best.x,best.y)===15 ? (1<<lin[book])-1 : 0);
  const gain=190-Math.round(16/3*Math.log2(magnitude));
  const f=frame(3,0,0,0,0,0,false,{table:book,bits,gain});
  const file=path.join(out,`mp3-vector-codebook-${book}.mp3`);
  fs.writeFileSync(file,Buffer.concat([f,f,f]));console.log(file);
}
for(let which=0;which<2;which++) {
  const tab=table(which?'mp_count33':'mp_count32'); let code;
  for(let p=0;p<64&&!code;p++) {
    let leaf=tab[p>>2];
    if(!(leaf&8)) leaf=tab[(leaf>>3)+((p&3)>>(2-(leaf&3)))];
    if((leaf>>4)===15) code=digits(p,6).slice(0,leaf&7).concat([0,1,0,1]);
  }
  if(!code) throw new Error('Missing count1 vector');
  const f=frame(3,0,0,0,0,0,false,{table:0,bits:code,quad:which+1,gain:190});
  const file=path.join(out,`mp3-vector-count1-${which}.mp3`);
  fs.writeFileSync(file,Buffer.concat([f,f,f]));console.log(file);
}
