'use strict';
const fs=require('fs'),path=require('path'),assert=require('assert');
const site=path.resolve(__dirname,'..','site'),html=fs.readFileSync(path.join(site,'index.html'),'utf8');
assert.match(html,/<html lang="en">/);assert.match(html,/name="viewport"/);
assert.match(html,/Lev's Assembly Media Player/);assert.match(html,/Opus playback, video, subtitles and streaming are not yet available/);
assert.match(html,/https:\/\/levkropp\.github\.io\/lamp\//);
const ids=new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(x=>x[1]));
let checked=0;
for(const [,target]of html.matchAll(/\b(?:src|href)="([^"]+)"/g)){
 if(/^https?:\/\//.test(target))continue;
 if(target.startsWith('#')){assert(ids.has(target.slice(1)),'Missing anchor '+target);continue;}
 const full=path.resolve(site,target);
 assert(full===site||full.startsWith(site+path.sep),'Site link escapes root: '+target);
 assert(fs.existsSync(full),'Missing site asset '+target);checked++;
}
assert(fs.existsSync(path.join(site,'.nojekyll')));
const siteIcon=fs.readFileSync(path.join(site,'assets','lamp.png'));
assert(siteIcon.equals(fs.readFileSync(path.resolve(site,'..','assets','lamp.png'))));
console.log('Site passed: '+checked+' local links/assets; root and /lamp/ relative paths.');
