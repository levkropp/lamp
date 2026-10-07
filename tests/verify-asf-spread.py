#!/usr/bin/env python3
"""Original ASF spreading serializer, exact PCM/seeks and guarded matrices.

--prepare-only makes FFmpeg-checked hash-pinned fixtures. --wine-only repeats
a native run with shipping COFF objects. --baseline-cli checks the published
pre-spreading binary. Generated media and binaries remain outside Git.
"""
import array
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import struct
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (ROOT, Failure, build_lamp, build_oracles, exe, ffmpeg,
                       ffmpeg_version, lamp_cli, main_guard, out_dir, run,
                       scratch, stereo_view, write_report)

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tests' / filename)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result); return result

writer = module('asf_writer', 'verify-asf.py')
metadata = module('asf_metadata', 'verify-asf-metadata.py')
chapters = module('asf_chapters', 'verify-asf-chapters.py')
SPREAD = writer.guid('bfc3cd50-618f-11cf-8bb2-00aa00b4e220')

def digest(data): return hashlib.sha256(data).hexdigest()

def stream(fmt, span, packet, chunk, ident=1, *, declared=True, silence=b'\0',
           correction=SPREAD, record=None, ec_length=None):
    record = struct.pack('<BHHH', span, packet, chunk, len(silence)) + silence if record is None else record
    length = len(record) if declared else 0
    if ec_length is not None: length = ec_length
    body = writer.AUDIO + correction + bytes(8) + struct.pack('<IIHI', len(fmt), length, ident, 0)
    return writer.obj(writer.STREAM, body + fmt + record)

def spread(data, span, packet, chunk):
    if len(data) != span*packet or not chunk or packet % chunk: raise ValueError('Bad matrix')
    rows = packet // chunk
    # Independent serializer: write columns of the known row-major stream.
    return b''.join(data[(row*span+col)*chunk:(row*span+col+1)*chunk]
                    for col in range(span) for row in range(rows))

def packets(data, span, packet, chunk, ident=1, *, fragmented=True, variable=False, compressed=False):
    group = span*packet
    if len(data) % group: raise ValueError('Incomplete media object')
    coded = [spread(data[i:i+group], span, packet, chunk) for i in range(0, len(data), group)]
    result = []
    if compressed:
        if group > 255: raise ValueError('Compressed object length is one byte')
        for i in range(0, len(coded), 3):
            payload = b''.join(bytes([len(d)]) + d for d in coded[i:i+3])
            result.append(writer.packet([writer.payload(payload, i&255, stream=ident, replic=1)], physical=1024))
        return result
    for k, data in enumerate(coded):
        off = 0
        cuts = [1, 17] if fragmented else []
        while off < len(data):
            size = cuts.pop(0) if cuts else min(400, len(data)-off)
            piece = data[off:off+size]
            physical = (512 if k%2 else 768) if variable else 512
            item = writer.payload(piece, (254+k)&255, off, len(data), stream=ident, replic=8 if not off else 0)
            result.append(writer.packet([item], physical=physical, replic=1 if not off else 0))
            off += len(piece)
    return result

def wave(fmt, data):
    body = b'fmt '+struct.pack('<I', len(fmt))+fmt+bytes(len(fmt)%2)
    body += b'data'+struct.pack('<I', len(data))+data+bytes(len(data)%2)
    return b'RIFF'+struct.pack('<I', len(body)+4)+b'WAVE'+body

def writer_hash():
    return digest(Path(__file__).read_bytes().split(b'def main():')[0] +
                  Path(writer.__file__).read_bytes().split(b'def main():')[0])

def prepare(work):
    cases, rejects = [], []
    if spread(b'ABCDEF', 2, 3, 1) != b'ACEBDF' or spread(b'abcdefghijkl', 2, 6, 2) != b'abefijcdghkl':
        raise Failure('Literal spreading convention differs')

    def add(name, fmt, data, span, packet, chunk, *, raw=None, channels=2, choice=0,
            count=1, selected=1, comparator=True, streams=None, extra=(), note='', **options):
        raw = raw or name+'.wav'
        if not (work/raw).exists(): (work/raw).write_bytes(wave(fmt, data))
        framing = {k:options.pop(k) for k in ('fragmented','variable','compressed') if k in options}
        physical = 1024 if framing.get('compressed') else 512
        maximum = 768 if framing.get('variable') else physical
        stream_id = selected
        envelope = writer.asf(streams or [stream(fmt,span,packet,chunk,stream_id,**options)],
                              packets(data,span,packet,chunk,stream_id,**framing), physical, maximum, extra=extra)
        (work/name).write_bytes(envelope)
        if comparator:
            ref = work/(name+'.ffmpeg.f32')
            decoder = ['-c:a','mp2float'] if name.startswith('mp2') else []
            ffmpeg(*decoder,'-i',work/name,'-map',f'0:a:{selected-1}','-af','asetpts=N','-f','f32le',ref)
            ref.write_bytes(stereo_view(ref.read_bytes(),channels,0))
        cases.append(dict(name=name,raw=raw,channels=channels,choice=choice,count=count,selected=selected,
                          span=span,packet=packet,chunk=chunk,ffmpeg=comparator,
                          note=note,
                          identity=span==1 or packet==chunk))
        return envelope

    codecs = [('pcm_u8',1),('pcm_s16le',1),('pcm_s16le',2),('pcm_s24le',2),('pcm_s32le',2),
              ('pcm_f32le',2),('pcm_f64le',1),('pcm_alaw',1),('pcm_alaw',2),('pcm_mulaw',2),
              ('adpcm_ima_wav',1),('adpcm_ima_wav',2),('adpcm_ms',1),('adpcm_ms',2),
              ('mp2',2),('libmp3lame',2)]
    for i,(codec,channels_) in enumerate(codecs):
        rate = 8000 if codec in ('pcm_alaw','pcm_mulaw') else 48000
        original = work/f'source-{i}.wav'; writer.source(original,channels_,rate,12288,73+i)
        name = f'{codec}-{channels_}.asf'; raw = name+'.wav'
        ffmpeg('-i',original,'-c:a',codec,*(['-b:a','128k'] if codec in ('mp2','libmp3lame') else []),work/raw)
        writer.untrimmed_wave(work/raw); fmt,data = writer.wave_parts((work/raw).read_bytes())
        group = math.gcd(len(data),3072); span = 2 if group%2==0 else 3
        packet = group//span; chunk = 4 if packet%4==0 else 1
        if packet <= chunk: raise Failure('Encoded fixture has no nonidentity matrix')
        add(name,fmt,data,span,packet,chunk,raw=raw,channels=channels_)
    import ac3_vectors
    coded,_ = ac3_vectors.stream(8251,12,2,0,dither=0.0)
    ac3fmt = struct.pack('<HHIIHHH',0x2000,2,48000,16000,1,0,0)
    group = math.gcd(len(coded),3072)
    add('ac3.asf',ac3fmt,coded,2,group//2,1)
    # Every AAC media object must remain exactly one packet after spreading.
    original = work/'aac-source.wav'; writer.source(original,2,48000,12288,814)
    adts = work/'aac-encoded.aac'; ffmpeg('-i',original,'-c:a','aac','-b:a','128k','-aac_pns','0',adts)
    encoded = adts.read_bytes(); pos = 0; frames = []
    while pos < len(encoded):
        size = (encoded[pos+3]&3)<<11 | encoded[pos+4]<<3 | encoded[pos+5]>>5
        header = 7 if encoded[pos+1]&1 else 9
        frames.append(encoded[pos:pos+size]); pos += size
    frame = next(f for f in frames[2:] if (len(f)-7)%2==0 and len(f)>11)
    aacraw = 'aac.asf.aac'; (work/aacraw).write_bytes(frame*12)
    asc = struct.pack('>H',2<<11|3<<7|2<<3) # AAC-LC, 48 kHz, stereo
    aacfmt = struct.pack('<HHIIHHH',0xff,2,48000,16000,1,0,len(asc))+asc
    add('aac.asf',aacfmt,frame[7:]*12,2,(len(frame)-7)//2,1,raw=aacraw)

    fmt,pcm = writer.source(work/'packet-source.wav',rate=48000,frames=12288)
    for name,span,packet,chunk,opts in [
        ('legacy-zero-length.asf',2,768,3,dict(declared=False)),
        ('odd-chunks.asf',3,256,1,{}),('wide-span.asf',128,384,3,{}),
        ('compressed-objects.asf',2,64,4,dict(compressed=True)),
        ('variable-packets.asf',3,256,4,dict(variable=True)),
        ('span-one.asf',1,768,3,{}),('one-row.asf',2,768,768,{}),
        ('seven-byte-record.asf',2,768,3,dict(silence=b'',comparator=False,
            note='Zero-length silence data: ASF has seven spreading bytes; FFmpeg requires eight and skips the transform')),
        ('silence-data.asf',2,768,3,dict(silence=bytes(range(255)))),
        ('Unicode-音楽-Ω.asf',2,768,3,{})]:
        add(name,fmt,pcm,span,packet,chunk,raw='packet-source.wav',**opts)
    for name,channels_,frames_,codec,span,packet,chunk in [
        ('max-span.asf',1,65535,'pcm_u8',255,257,1),
        ('max-packet.asf',1,65535,'pcm_s16le',2,65535,1),
        ('max-chunk.asf',2,32767,'pcm_s16le',2,65534,32767)]:
        source = work/(name+'.source.wav'); raw = work/(name+'.wav')
        writer.source(source,channels_,48000,frames_,991)
        ffmpeg('-i',source,'-c:a',codec,raw); writer.untrimmed_wave(raw)
        boundary_fmt,boundary_pcm = writer.wave_parts(raw.read_bytes())
        add(name,boundary_fmt,boundary_pcm,span,packet,chunk,raw=raw.name,channels=channels_)
    # Unknown correction is a counted but unavailable track; later supported
    # spreading is selected automatically. Explicit choices must also work.
    second = stream(fmt,2,768,3,2)
    for choice in (0,2):
        add(f'skip-unavailable-{choice}.asf',fmt,pcm,2,768,3,raw='packet-source.wav',choice=choice,
            count=2,selected=2,comparator=False,streams=[stream(fmt,2,768,3,correction=bytes(16)),second])
    otherfmt,otherpcm = writer.source(work/'other.wav',rate=48000,frames=12288,seed=85)
    streams = [stream(fmt,2,768,3),stream(otherfmt,3,256,4,2)]
    a,b = packets(pcm,2,768,3),packets(otherpcm,3,256,4,2)
    interleaved = [p for i in range(max(len(a),len(b))) for p in (a[i:i+1]+b[i:i+1])]
    for choice in (0,1,2):
        name = f'multitrack-{choice}.asf'; (work/name).write_bytes(writer.asf(streams,interleaved))
        selected = choice or 1
        ref = work/(name+'.ffmpeg.f32')
        ffmpeg('-i',work/name,'-map',f'0:a:{selected-1}','-af','asetpts=N','-f','f32le',ref)
        cases.append(dict(name=name,raw='other.wav' if choice==2 else 'packet-source.wav',channels=2,
                          choice=choice,count=2,selected=selected,span=3 if choice==2 else 2,
                          packet=256 if choice==2 else 768,chunk=4 if choice==2 else 3,ffmpeg=True,identity=False))
    extra = [metadata.basic('Spread 漢字','LAMP Test'),chapters.markers([chapters.entry(0,'Start'),chapters.entry(1250000,'Part')])]
    add('metadata-chapters.asf',fmt,pcm,2,768,3,raw='packet-source.wav',extra=extra)

    def reject(name, streams_, payloads=None, error=101, choice=0, physical=512):
        (work/name).write_bytes(writer.asf(streams_,payloads or packets(pcm,2,768,3),physical))
        rejects.append(dict(name=name,error=error,choice=choice))
    for name,s,p,c in [('zero-span',0,768,3),('zero-packet',2,0,3),('zero-chunk',2,768,0),
                       ('indivisible',2,767,3),('no-rows',2,2,3)]:
        reject(name+'.asf',[stream(fmt,s,p,c)])
    reject('unknown-correction.asf',[stream(fmt,2,768,3,correction=bytes(16))])
    reject('no-correction-spread.asf',[stream(fmt,2,768,3,correction=writer.NONE)])
    reject('short-record.asf',[stream(fmt,2,768,3,record=bytes(6))])
    reject('short-silence.asf',[stream(fmt,2,768,3,record=struct.pack('<BHHH',2,768,3,65535))])
    reject('short-advertised-record.asf',[stream(fmt,2,768,3,ec_length=6)])
    reject('error-length-past-end.asf',[stream(fmt,2,768,3,ec_length=65535)],error=100)
    reject('unavailable-selected.asf',[stream(fmt,2,768,3,correction=bytes(16)),second],
           packets(pcm,2,768,3,2),choice=1)
    base_stream = [stream(fmt,2,768,3)]
    for name,items in [
        ('short-object',[writer.payload(pcm[:1535])]),
        ('long-object',[writer.payload(pcm[:1537])]),
        ('partial-object',[writer.payload(pcm[:128],size=1536)]),
        ('fragment-gap',[writer.payload(pcm[:128],size=1536),writer.payload(pcm[128:256],offset=129,size=1536)]),
        ('duplicate-fragment',[writer.payload(pcm[:128],size=1536),writer.payload(pcm[:128],offset=0,size=1536)])]:
        reject(name+'.asf',base_stream,[writer.packet([item],physical=2048) for item in items],error=100,physical=2048)
    bad = packets(pcm,2,768,3)
    bad.append(writer.packet([writer.payload(b'abcd',number=30)]))
    reject('failure-after-transform.asf',base_stream,bad,error=100)
    names = {c['name'] for c in cases} | {c['raw'] for c in cases} | {c['name']+'.ffmpeg.f32' for c in cases if c['ffmpeg']} | {c['name'] for c in rejects}
    manifest = dict(files=cases,rejections=rejects,fixture_ffmpeg=ffmpeg_version(),writer_sha256=writer_hash(),
                    hashes={name:digest((work/name).read_bytes()) for name in sorted(names)})
    (work/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f'Prepared {len(cases)} streams and {len(rejects)} rejected layouts.',flush=True)

def main():
    work = scratch('asf-spread')
    if '--prepare-only' in sys.argv: prepare(work); return
    if not (work/'manifest.json').exists(): prepare(work)
    manifest = json.loads((work/'manifest.json').read_text())
    if manifest['writer_sha256'] != writer_hash(): raise Failure('Fixture writer changed; prepare again')
    for name,sha in manifest['hashes'].items():
        if digest((work/name).read_bytes()) != sha: raise Failure('Fixture changed: '+name)
    names = {'asf-spread-oracle':'asf-spread-oracle.c','asf-seek-oracle':'asf-seek-oracle.c',
             'seek-oracle':'seek-oracle.c','chain-oracle':'chain-oracle.c',
             'track-catalog-oracle':'track-catalog-oracle.c','asf-boundary-oracle':'asf-boundary-oracle.c'}
    wine = '--wine-only' in sys.argv
    env = dict(os.environ,WINEDEBUG='err+all') if wine else None
    if wine:
        prior = json.loads((out_dir()/'asf-spread-verification.json').read_text())
        if prior['result']!='passed' or prior['fixture_hashes']!=manifest['hashes']: raise Failure('Matching native run must pass first')
        run([sys.executable,ROOT/'tools/build-windows.py'],capture=False)
        objects = [p for p in sorted((ROOT/'bin/obj').glob('*.obj')) if p.stem not in
                   {'player','ui','engine-probe','ui-preview','ui-list','ui-driver'}]
        libs = [p for p in sorted((ROOT/'bin/obj').glob('*.lib')) if p.name!='lamp-test.lib']
        for name,source in names.items():
            run(['x86_64-w64-mingw32-gcc','-O2','-std=c11','-municode','-I',ROOT/'tests',ROOT/'tests'/source,
                 *objects,*libs,'-lm','-o',ROOT/'bin'/(name+'.exe')])
        cli = ['wine',ROOT/'bin/lamp-cli.exe']; command = lambda name: ['wine',ROOT/'bin'/(name+'.exe')]
    else:
        library = build_lamp(); build_oracles(out_dir(),names,library)
        cli = [lamp_cli()]; command = lambda name: [exe(name)]
    checks = []
    def oracle(name,*args,timeout=180):
        return json.loads(run([*command(name),*args],env=env,timeout=timeout).splitlines()[-1])
    checks.append(dict(test='guarded spreading kernel',result=oracle('asf-spread-oracle',timeout=300)))
    for case in manifest['files']:
        name = case['name']; path = work/name; ours = work/(name+'.'+('wine' if wine else 'native')+'.f32')
        ours.unlink(missing_ok=True); options = ['--track',case['choice']] if case['choice'] else []
        run([*cli,*options,'--decode',path,ours],env=env,timeout=180)
        pcm = ours.read_bytes(); reference = work/(name+'.reference.f32')
        stats = None
        if not wine:
            raw = work/'raw-output.f32'; raw.unlink(missing_ok=True)
            run([*cli,'--decode',work/case['raw'],raw],env=env,timeout=180)
            if pcm != raw.read_bytes(): raise Failure(name+': raw stream PCM differs')
            if case['ffmpeg']:
                other = (work/(name+'.ffmpeg.f32')).read_bytes()
                if len(pcm)!=len(other): raise Failure(name+': FFmpeg length differs')
                a,b = array.array('f',pcm),array.array('f',other)
                error = sum((x-y)**2 for x,y in zip(a,b)); signal = sum(y*y for y in b) or 1
                snr = 999 if not error else 10*math.log10(signal/error); peak = max(abs(x-y) for x,y in zip(a,b))
                if name.startswith('adpcm_ima_wav'):
                    if peak>127/32768: raise Failure(name+': FFmpeg IMA peak differs')
                elif snr<(75 if name.startswith('aac') else 95): raise Failure(name+': FFmpeg SNR differs: '+str(snr))
                stats = dict(snr_db=snr,peak_error=peak)
            reference.write_bytes(pcm)
        if pcm!=reference.read_bytes(): raise Failure(name+': verified native PCM differs')
        catalog = oracle('track-catalog-oracle',path,case['choice'],case['count'],case['selected'])
        cold = oracle('asf-seek-oracle',path,work/case['raw'],case['choice'])
        continuous = None if case['choice'] else oracle('seek-oracle',path,reference,0)
        checks.append(dict(test=name,result='exact',pcm_sha256=digest(pcm),frames=len(pcm)//8,
                           spreading=[case['span'],case['packet'],case['chunk']],identity=case['identity'],
                           catalog=catalog,cold_seeks=cold,continuous_seeks=continuous,ffmpeg=stats,note=case.get('note','')))
        print(name+': PCM, catalog and seeks passed',flush=True)
    for case in manifest['rejections']:
        proof = oracle('chain-oracle','reject',work/case['name'],case['choice'])
        if proof['decode_error']!=case['error']: raise Failure(case['name']+': wrong error '+str(proof))
        checks.append(dict(test=case['name'],result=proof))
    for name in ('legacy-zero-length.asf','aac.asf','compressed-objects.asf'):
        checks.append(dict(test=name+' protected input',result=oracle('asf-boundary-oracle',work/name)))
        checks.append(dict(test=name+' guarded mutations',result=oracle('asf-spread-oracle','mutate',work/name,120 if wine else 1200)))
    import random
    robustness = module('robustness_writer','verify-robustness.py')
    rng = random.Random(9431); mutation = work/'mutated-full-decode.asf'
    for name in ('legacy-zero-length.asf','aac.asf','adpcm_ima_wav-2.asf'):
        data = (work/name).read_bytes(); decoded = rejected = seeks = 0
        for i in range(50 if wine else 500):
            mutation.write_bytes(robustness.mutate(data,rng))
            seek = ['--start',f'{rng.random()*0.4:.6f}'] if i%4==0 else []
            args = [str(a) for a in [*cli,'--check',*seek,mutation]]
            if wine:
                result = robustness.wine_run(args,env=env,timeout=30)
            else:
                result = subprocess.run(args,env=env,timeout=30,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                    preexec_fn=robustness.limit_memory if robustness.resource else None)
            if result.returncode not in (0,2): raise Failure(name+f': mutation {i} exited {result.returncode}: '+str(result.stdout[-1024:]))
            decoded += result.returncode==0; rejected += result.returncode==2; seeks += bool(seek)
        checks.append(dict(test=name+' full decoder mutations',result='no crash, hang or runaway allocation',
                           mutations=decoded+rejected,decoded=decoded,rejected=rejected,seeks=seeks,seed=9431,
                           address_space_limit_bytes=None if wine or not robustness.resource else robustness.LIMIT))
        print(name+': full decoder mutations passed',flush=True)
    path = work/'legacy-zero-length.asf'
    checks.append(dict(test='open, cancellation and scratch ownership',result=oracle('asf-spread-oracle',path)))
    checks.append(dict(test='failed transform then reopen',result=oracle('asf-spread-oracle',path,work/'failure-after-transform.asf')))
    for name in ('legacy-zero-length.asf','aac.asf'):
        for mode in ('cancel-open','cancel-read'):
            checks.append(dict(test=name+' '+mode,result=oracle('chain-oracle',mode,work/name)))
    path = work/'metadata-chapters.asf'
    tags = run([*cli,'--tags',path],env=env,timeout=120)
    if '\n'.join(tags.splitlines())!='title=Spread 漢字\nartist=LAMP Test': raise Failure('Spreading changed tags')
    chapter_text = run([*cli,'--chapters',path],env=env,timeout=120)
    if '\n'.join(chapter_text.splitlines())!='00:00:00.000 Start\n00:00:00.125 Part': raise Failure('Spreading changed chapters')
    checks.append(dict(test='spread file tags and chapters',result='exact'))
    if '--baseline-cli' in sys.argv:
        baseline = Path(sys.argv[sys.argv.index('--baseline-cli')+1]).resolve()
        report = ROOT/'reports/asf-chapters-verification.json'; published = json.loads(report.read_text())
        if digest(baseline.read_bytes())!=published['cli_sha256']: raise Failure('Baseline differs from published report')
        for name in ('legacy-zero-length.asf','aac.asf','compressed-objects.asf'):
            result = subprocess.run([str(baseline),'--check',str(work/name)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
            if result.returncode!=2: raise Failure('Published binary unexpectedly supports spreading')
            checks.append(dict(test=name+' published negative control',result='rejected before, exact PCM after',
                               baseline_commit='a300968e926e216bba30b48cedeeded9d0f46c04',baseline_cli_sha256=digest(baseline.read_bytes()),
                               baseline_report_sha256=digest(report.read_bytes())))
    sources = ['src/asf.s','src/asf_spread.inc','src/avi.s','src/track.s','src/mpegts.s','src/decoder.s',
               'tests/verify-asf-spread.py','tests/asf-spread-oracle.c','tests/asf-seek-oracle.c','tests/asf-boundary-oracle.c',
               'tests/seek-oracle.c','tests/chain-oracle.c','tests/track-catalog-oracle.c','tests/verify-asf.py','tests/verify-robustness.py']
    write_report('asf-spread-wine' if wine else 'asf-spread',dict(result='passed',checks=checks,
                 fixture_hashes=manifest['hashes'],fixture_ffmpeg=manifest['fixture_ffmpeg'],runtime_ffmpeg=ffmpeg_version(),
                 runtime_platform=platform.platform(),runtime_sources={n:digest((ROOT/n).read_bytes()) for n in sources},
                 cli_sha256=digest(Path(cli[-1]).read_bytes()),oracle_sha256={n:digest(Path(command(n)[-1]).read_bytes()) for n in names},
                 reference_hashes={c['name']:digest((work/(c['name']+'.reference.f32')).read_bytes()) for c in manifest['files']}))
    print(f'Passed {len(checks)} checks.',flush=True)

if __name__ == '__main__': main_guard(main)
