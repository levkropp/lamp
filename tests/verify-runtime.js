/* Check the delivered binaries' architecture, subsystem and DLL dependencies. */
'use strict';
const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..');
const bin=process.argv[2]?path.resolve(process.argv[2]):path.join(root,'bin');
const audio=['KERNEL32.dll','ole32.dll','SHELL32.dll','AVRT.dll'];
const report=[];
for(const [name,subsystem,expected]of[
 ['lamp-cli.exe',3,audio],['lamp.exe',2,[...audio,'USER32.dll','GDI32.dll','COMDLG32.dll']]
]){
 const data=fs.readFileSync(path.join(bin,name)),pe=data.readUInt32LE(0x3c);
 if(data.readUInt16LE(0)!==0x5a4d||data.readUInt32LE(pe)!==0x4550||data.readUInt16LE(pe+4)!==0x8664)throw Error('Invalid x86-64 PE '+name);
 const optional=pe+24,sectionCount=data.readUInt16LE(pe+6),sectionStart=optional+data.readUInt16LE(pe+20);
 if(data.readUInt16LE(optional)!==0x20b||data.readUInt16LE(optional+68)!==subsystem)throw Error('Wrong subsystem '+name);
 function offset(rva){
  for(let i=0;i<sectionCount;i++){
   const section=sectionStart+i*40,address=data.readUInt32LE(section+12),bytes=data.readUInt32LE(section+16);
   if(rva>=address&&rva-address<bytes)return data.readUInt32LE(section+20)+rva-address;
  }
  throw Error('Invalid import RVA');
 }
 const imports=[],start=offset(data.readUInt32LE(optional+120));
 for(let i=0;i<64;i++){
  const rva=data.readUInt32LE(start+i*20+12);if(!rva)break;
  const p=offset(rva),end=data.indexOf(0,p);
  if(end<0||end-p>256)throw Error('Invalid DLL name');
  imports.push(data.toString('ascii',p,end));
 }
 if(JSON.stringify(imports.slice().sort())!==JSON.stringify(expected.slice().sort()))throw Error('Unexpected runtime dependency '+name+': '+imports);
 const resourceBase=offset(data.readUInt32LE(optional+128)),leaves=[];
 function walk(relative,keys=[]){
  const p=resourceBase+relative,count=data.readUInt16LE(p+12)+data.readUInt16LE(p+14);
  if(keys.length>3||count>256)throw Error('Invalid resource tree '+name);
  for(let i=0;i<count;i++){
   const entry=p+16+i*8,id=data.readUInt32LE(entry),child=data.readUInt32LE(entry+4),next=[...keys,id];
   if(child&0x80000000)walk(child&0x7fffffff,next);
   else{const leaf=resourceBase+child,rva=data.readUInt32LE(leaf),length=data.readUInt32LE(leaf+4),start=offset(rva);leaves.push({keys:next,data:data.subarray(start,start+length)});}
  }
 }
 walk(0);
 const group=leaves.find(x=>x.keys[0]===14&&x.keys[1]===101),version=leaves.find(x=>x.keys[0]===16);
 if(!group||!version)throw Error('Missing LAMP resources '+name);
 const sizes=[];
 for(let i=0;i<group.data.readUInt16LE(4);i++)sizes.push(group.data[6+i*14]||256);
 if(JSON.stringify(sizes)!==JSON.stringify([16,24,32,48,64,128,256])||leaves.filter(x=>x.keys[0]===3).length!==7)throw Error('Missing icon sizes '+name);
 const text=version.data.toString('utf16le');
 if(!text.includes("Lev's Assembly Media Player")||!text.includes('0.4.0-dev')||!text.includes(name))throw Error('Wrong LAMP version/filename '+name);
 report.push({file:name,bytes:data.length,architecture:'x86-64',subsystem:subsystem===2?'windows':'console',imports,iconSizes:sizes,version:'0.4.0-dev',result:'passed'});
}
fs.writeFileSync(path.join(bin,'runtime-verification.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report));
