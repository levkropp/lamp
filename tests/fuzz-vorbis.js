// Original bounded survival test. Page CRCs are repaired to exercise the decoder.
'use strict';
const fs=require('fs'),path=require('path'),cp=require('child_process');
const root=path.resolve(__dirname,'..'),dir=path.join(__dirname,'generated');
const original=fs.readFileSync(path.join(dir,'vorbis-transient.ogg'));
const pages=[];
for(let p=0;p<original.length;){
 const count=original[p+26],body=p+27+count;
 let end=body;for(let i=0;i<count;i++)end+=original[p+27+i];
 pages.push({p,body,end});p=end;
}
const crcTable=Array.from({length:256},(_,i)=>{
 let c=(i<<24)>>>0;for(let j=0;j<8;j++)c=((c<<1)^((c>>>31)?0x04c11db7:0))>>>0;return c;
});
function repair(b){for(const {p,end}of pages){b.writeUInt32LE(0,p+22);let c=0;for(let i=p;i<end;i++)c=((c<<8)^crcTable[(c>>>24)^b[i]])>>>0;b.writeUInt32LE(c,p+22);}}
const target=path.join(dir,'vorbis-mutated.ogg');
let seed=0x43719753,accepted=0,rejected=0;
function next(n){seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;return(seed>>>0)%n;}
for(let i=0;i<512;i++){
 const b=Buffer.from(original);
 // Concentrate half the cases on the comment/setup page, half on audio pages.
 const page=pages[i%2===0?1:2+next(pages.length-2)];
 for(let j=0;j<1+i%8;j++)b[page.body+next(page.end-page.body)]^=1<<next(8);
 repair(b);fs.writeFileSync(target,b);
 const r=cp.spawnSync(path.join(root,'bin','lamp-cli.exe'),['--check',target],{timeout:2000,windowsHide:true,encoding:'utf8'});
 if(r.error||![0,2].includes(r.status))throw Error('Mutation '+i+' crashed or timed out: '+(r.error||r.status));
 if(r.status===0)accepted++;else rejected++;
}
const report={cases:512,accepted,rejected,result:'no crash or timeout',scope:'Seeded setup/comment and audio mutations of one transient fixture, with page CRCs repaired. Accepted mutations are not verified for audio correctness; not exhaustive fuzzing.'};
fs.writeFileSync(path.join(root,'vorbis-fuzz-verification.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report));
