/* Test-only extraction from the hash-verified normative RFC6716 archive. */
'use strict';
const fs = require('fs'), path = require('path');
const root = path.resolve(__dirname, '..');
const ref = process.argv[2] || path.join(__dirname, 'reference', 'opus-rfc6716');
const text = fs.readFileSync(path.join(ref, 'celt', 'celt.c'), 'utf8');
function definition(symbol) {
 const start = text.indexOf('static ', text.lastIndexOf('\n', text.indexOf(symbol)) + 1);
 if (start < 0 || !text.slice(start, start + 120).includes(symbol)) throw Error('Missing '+symbol);
 const brace = text.indexOf('{', start); let level = 1, end = brace + 1;
 while (level && end < text.length) { if (text[end] === '{') level++; if (text[end] === '}') level--; end++; }
 if (level) throw Error('Unclosed '+symbol);
 if (text[end] === ';') end++;
 return text.slice(start, end);
}
const decoder = text.slice(text.indexOf('int celt_decode_with_ec('));
const begin = decoder.indexOf('   if (C==1)');
const end = decoder.indexOf('   /* Decode fixed codebook */');
if (begin < 0 || end <= begin) throw Error('Missing CELT frame prefix');
let prefix = decoder.slice(begin, end).replace(/^\s*ALLOC\([^\n]*\);\r?\n/gm, '');
prefix = prefix.replace(/st->mode/g, 'm').replace(/st->start/g, 'r->start').replace(/st->end/g, 'r->end');
const header = ['trim_icdf','spread_icdf','tapset_icdf','tf_select_table','tf_decode','init_caps'].map(definition).join('\n');
const output = `/* Extracted normative RFC6716 celt.c control decisions: BSD notice in THIRD_PARTY_NOTICES. Test-only. */
${header}
static int reference_controls(Controls *r) {
 const CELTMode *m=&mode48000_960_120;
 ec_dec *dec=r->ec; float *oldBandE=r->old;
 int *tf_res=r->tf,*pulses=r->bits,*cap=r->caps,*offsets=r->offsets,*fine_priority=r->priority,*fine_quant=r->fine;
 int C=r->channels, LM=r->lm, M=1<<LM, len=(int)dec->storage;
 int i,total_bits,tell,silence,isTransient,shortBlocks,intra_ener,spread_decision;
 int postfilter_pitch,postfilter_tapset,dynalloc_logp,alloc_trim,bits,anti_collapse_rsv,intensity,dual_stereo,balance,codedBands;
 float postfilter_gain;
${prefix}
 r->silence=silence; r->transient=isTransient; r->intra=intra_ener; r->spread=spread_decision;
 r->pitch=postfilter_pitch; r->gain=postfilter_gain; r->tapset=postfilter_tapset; r->trim=alloc_trim;
 r->anti=anti_collapse_rsv; r->balance=balance; r->intensity=intensity; r->dual=dual_stereo; r->coded=codedBands; r->budget=bits;
 return codedBands;
}
`;
fs.mkdirSync(path.join(root,'tests','generated','include'),{recursive:true});
const packetSource = fs.readFileSync(path.join(ref,'src','opus_decoder.c'),'utf8');
const durationStart = packetSource.indexOf('int opus_packet_get_samples_per_frame(');
const durationEnd = packetSource.indexOf('int opus_packet_get_nb_channels(',durationStart);
const parserStart = packetSource.indexOf('static int parse_size(');
const parserEnd = packetSource.indexOf('int opus_decode_native(',parserStart);
if(durationStart<0||durationEnd<durationStart||parserStart<0||parserEnd<parserStart)throw Error('Missing normative packet helpers');
const packetHelpers = packetSource.slice(durationStart,durationEnd)+'\n'+packetSource.slice(parserStart,parserEnd);
fs.writeFileSync(path.join(root,'tests','generated','include','celt-controls-reference.inc'),output+'\n'+packetHelpers);
console.log('Extracted normative CELT frame controls for test comparison.');
