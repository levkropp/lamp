/* Test-only extraction from the hash-verified normative RFC6716 archive. */
'use strict';
const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..');
const ref=process.argv[2]||path.join(__dirname,'reference','opus-rfc6716');
const text=fs.readFileSync(path.join(ref,'celt','bands.c'),'utf8');
const start=text.indexOf('      /* Decide on the resolution to give to the split parameter theta */');
const end=text.indexOf('#ifdef FIXED_POINT',start);
if(start<0||end<=start)throw Error('Missing normative split-angle decisions');
const output=`/* Normative RFC6716 bands.c decoder-only angle decisions; BSD notice in THIRD_PARTY_NOTICES. Test-only. */
static int reference_theta(Theta *r) {
 const CELTMode *m=&mode48000_960_120;
 const int encode=0; int N=r->n,b=r->budget,i=r->band,LM=r->lm,stereo=r->stereo;
 int B=r->blocks,B0=r->original_blocks,intensity=r->intensity,fill=r->fill;
 ec_ctx *ec=r->ec; int *remaining_bits=r->remaining;
 float *X=NULL,*Y=NULL; const celt_ener *bandE=NULL;
 int qn,itheta=0,qalloc,pulse_cap,offset,orig_fill,imid=0,iside=0,delta,inv=0;
 opus_int32 tell;
${text.slice(start,end)}
 r->angle=itheta;r->mid=imid;r->side=iside;r->delta=delta;r->cost=qalloc;r->invert=inv;r->output_fill=fill;r->qn=qn;
 return 1;
}
`;
fs.mkdirSync(path.join(root,'tests','generated','include'),{recursive:true});
fs.writeFileSync(path.join(root,'tests','generated','include','celt-theta-reference.inc'),output);
console.log('Extracted normative CELT split-angle decisions for test comparison.');
