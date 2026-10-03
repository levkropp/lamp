// Invalid structural fields with deterministic expected rejection.
const fs=require('fs'),path=require('path'),out=process.argv[2];
const raw=fs.readFileSync(path.join(out,'mp3-vector-v3-i1-m-1.mp3'));
function put(b,offset,width,value) {
  for(let i=0;i<width;i++) {
    const at=offset+i,mask=1<<(7-(at&7));
    b[at>>3]=(b[at>>3]&~mask)|(((value>>>(width-1-i))&1)?mask:0);
  }
}
function save(name,b) { const file=path.join(out,`mp3-invalid-${name}.mp3`);fs.writeFileSync(file,b);console.log(file); }
for(const [name,offset,width,value] of [
  ['missing-reservoir',32,9,511], ['big-values',64,9,511],
  ['codebook4',86,5,4], ['codebook14',86,5,14],
  ['free-format',16,4,0], ['reserved-version',11,2,1],
  ['reserved-rate',20,2,3], ['part-length',52,12,4095]
]) { const b=Buffer.from(raw);put(b,offset,width,value);save(name,b); }
save('truncated',raw.subarray(0,raw.length-1));
const protectedBytes=fs.readFileSync(path.join(out,'mp3-vector-crc.mp3'));
protectedBytes[4]^=1;save('crc',protectedBytes);
const tagged=fs.readFileSync(path.join(out,'mp3-vector-id3v2-4.mp3'));
for(const [name,index,value] of [['id3-size',6,0x80],['id3-version',3,5],['id3-flags',5,1]]) {
  const b=Buffer.from(tagged);b[index]=value;save(name,b);
}
const footer=fs.readFileSync(path.join(out,'mp3-vector-id3-footer.mp3'));footer[10]^=1;save('id3-footer',footer);
