'use strict';
const fs=require('fs'),path=require('path'),cp=require('child_process'),assert=require('assert');
const root=path.resolve(__dirname,'..'),bin=process.argv[2]?path.resolve(process.argv[2]):path.join(root,'bin'),exe=path.join(bin,'lamp-cli.exe');
const tempRoot=path.resolve(require('os').tmpdir());
const temp=fs.mkdtempSync(path.join(tempRoot,'lamp-smoke-')),report=[];
assert(path.dirname(temp)===tempRoot&&path.basename(temp).startsWith('lamp-smoke-'),'Unsafe temporary path');
const run=args=>{const r=cp.spawnSync(exe,args,{encoding:'utf8',timeout:10000,windowsHide:true});if(r.error)throw r.error;return r;};
try{
 const help=run([]);
 assert.match(help.stdout,/LAMP 0\.4\.0-dev - Lev's Assembly Media Player/);
 for(const [codec,ext]of[['wav','wav'],['flac','flac'],['mp3','mp3'],['vorbis','ogg'],['opus','opus']]){
  const fixture=path.join(__dirname,'fixtures','tone.'+ext),check=run(['--check',fixture]);
  assert.strictEqual(check.status,0,codec+' check failed '+check.stdout+check.stderr);
  assert.match(check.stdout,/rate=48000 channels=2/);
  assert.match(check.stdout,/frames=12000(?:\s|$)/);
  const output=path.join(temp,codec+'.f32'),decoded=run(['--decode',fixture,output]);
  assert.strictEqual(decoded.status,0,codec+' export failed');
  const pcm=fs.readFileSync(output);assert.strictEqual(pcm.length,12000*2*4);
  let peak=0;for(let i=0;i<pcm.length;i+=4){const x=pcm.readFloatLE(i);assert(Number.isFinite(x));peak=Math.max(peak,Math.abs(x));}
  assert(peak>.03&&peak<.2,codec+' invalid tone amplitude '+peak);
  if(codec==='flac')assert.deepStrictEqual(pcm,fs.readFileSync(path.join(temp,'wav.f32')),'Lossless PCM mismatch');
  const overwrite=run(['--decode',fixture,output]);assert.notStrictEqual(overwrite.status,0,'Existing export must be rejected');
  report.push({codec,frames:12000,rate:48000,peak,result:'passed'});
 }
 fs.mkdirSync(bin,{recursive:true});
 fs.writeFileSync(path.join(bin,'branding-smoke-verification.json'),JSON.stringify(report,null,2)+'\n');
 console.log(JSON.stringify(report));
}finally{fs.rmSync(temp,{recursive:true,force:true});}
