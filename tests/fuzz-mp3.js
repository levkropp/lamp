// Bounded deterministic mutations. This checks process survival, not conformance.
const fs=require('fs'),path=require('path'),cp=require('child_process');
const root=path.resolve(__dirname,'..'),dir=path.join(__dirname,'generated');
const source=fs.readFileSync(path.join(dir,'mp3-transient-vbr.mp3'));
const file=path.join(dir,'mp3-mutated.mp3');
let seed=0x6de813a2,accepted=0,rejected=0;
function random(n) {seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;return (seed>>>0)%n;}
for(let i=0;i<256;i++) {
  let bytes=Buffer.from(source);
  if(i%4===0) bytes=bytes.subarray(0,random(bytes.length));
  else for(let j=0;j<1+i%7;j++) bytes[random(bytes.length)]^=1<<random(8);
  fs.writeFileSync(file,bytes);
  const r=cp.spawnSync(path.join(root,'bin','lamp-cli.exe'),['--check',file],{timeout:2000,windowsHide:true,encoding:'utf8'});
  if(r.error || ![0,2].includes(r.status)) throw new Error(`Mutation ${i} crashed or timed out: ${r.error||r.status}`);
  if(r.status===0) accepted++;else rejected++;
}
const report={cases:256,accepted,rejected,result:'no crash or timeout',scope:'Seeded mutations of one transient VBR fixture. Accepted mutations have no PCM correctness guarantee; this is not exhaustive fuzzing.'};
fs.writeFileSync(path.join(root,'mp3-fuzz-verification.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report));
