/* BSD RFC6716 mean energies plus original SSE2 exp2 polynomial coefficients. */
'use strict';
const fs=require('fs'),path=require('path'),args=process.argv.slice(2),check=args.includes('--check');
const root=path.resolve(__dirname,'..'),ref=args.find(x=>!x.startsWith('--'));
const source=fs.readFileSync(path.join(ref,'celt','quant_bands.c'),'utf8');
const match=/static const opus_val16 eMeans\[25\]\s*=\s*\{([\s\S]*?)\};/.exec(source);
if(!match)throw Error('Missing floating mean energy table');
const means=match[1].match(/\d+\.\d+f/g).slice(0,21).map(x=>x.slice(0,-1));
if(means.length!==21)throw Error('Wrong mean energy count');
let output='; Normative RFC6716 mean energies (BSD); see THIRD_PARTY_NOTICES.\n; Copyright (c) 2007-2012 IETF Trust, CSIRO, Xiph.Org Foundation.\n';
output+='os_means real4 '+means.join(',')+'\n';
output+='; Original degree-18 Taylor polynomial for 2^fraction, 0<=fraction<1.\n';
let coefficients=[1],factor=1;
for(let i=1;i<=18;i++){factor*=Math.LN2/i;coefficients.push(factor);}
output+='os_exp_coeff real8 '+coefficients.map(x=>x.toExponential(17)).join(',')+'\n';
const target=path.join(root,'src','opus_spectral_tables.inc');
if(check){if(fs.readFileSync(target,'utf8').replace(/\r\n/g,'\n')!==output)throw Error('Spectral tables differ');}
else fs.writeFileSync(target,output);
console.log((check?'Verified':'Extracted')+' CELT mean energies and SSE2 exponent coefficients.');
