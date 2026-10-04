/* Extract the normative frame loop, exposing its scratch only for testing. */
'use strict';
const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..'),ref=process.argv[2];
const source=fs.readFileSync(path.join(ref,'celt','bands.c'),'utf8');
const start=source.indexOf('void quant_all_bands('),brace=source.indexOf('{',start);
let depth=1,end=brace+1;
while(depth&&end<source.length){if(source[end]==='{')depth++;if(source[end]==='}')depth--;end++;}
if(start<0||depth)throw Error('Missing normative quant_all_bands');
let body=source.slice(brace+1,end-1);
body=body.replace(/ALLOC\(_norm,[^;]+;/,'_norm = r->norm;').replace(/ALLOC\(lowband_scratch,[^;]+;/,'lowband_scratch = r->scratch;');
const output=`/* Normative BSD RFC6716 quant_all_bands; test-only buffer/budget observation. */
static void reference_bands(Bands *r) {
 const CELTMode *m=&mode48000_960_120; int encode=0,start=r->start,end=r->end;
 float *X_=r->x,*Y_=r->y;unsigned char *collapse_masks=r->masks;const float *bandE=NULL;
 int *pulses=r->pulses,*tf_res=r->tf,shortBlocks=r->short_blocks,spread=r->spread,dual_stereo=r->dual,intensity=r->intensity;
 int total_bits=r->total,balance=r->balance,LM=r->lm,codedBands=r->coded;ec_dec *ec=r->ec;uint32_t *seed=r->seed;
${body}
 r->remaining_out=remaining_bits;r->balance_out=balance;
}
`;
fs.writeFileSync(path.join(root,'bin','celt-bands-reference.inc'),output);
console.log('Extracted normative full-band loop for test comparison.');
