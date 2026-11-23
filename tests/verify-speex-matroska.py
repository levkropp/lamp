#!/usr/bin/env python3
"""Matroska ACM/Speex versus official float PCM, lacing, ordinals and guards."""
import argparse
from datetime import datetime,timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lamp_test import ROOT,WINDOWS,compile_c

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

def run(args,timeout=180):
    p=subprocess.run([str(x) for x in args],capture_output=True,text=True,timeout=timeout,
                     **({'creationflags':subprocess.CREATE_NO_WINDOW} if WINDOWS else {}))
    if p.returncode:raise RuntimeError(f'{Path(str(args[0])).name} ({p.returncode}): {p.stdout[-2200:]} {p.stderr[-2200:]}')
    return p.stdout

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--bin',type=Path,default=ROOT/('bin/speex-mkv-check' if WINDOWS else 'build/speex-mkv-check'));p.add_argument('--fixtures',type=Path);p.add_argument('--probe',action='store_true',help='run marked muted native Windows playback probes');args=p.parse_args()
    out=args.bin.resolve();work=out/'speex-matroska';work.mkdir(parents=True,exist_ok=True);suffix='.exe' if WINDOWS else '';cli=out/('lamp-cli'+suffix)
    mkv=module('mkv_helpers',ROOT/'tests/verify-matroska.py');fixture_source=args.fixtures.resolve() if args.fixtures else None
    if fixture_source:
        manifest=json.loads((fixture_source/'fixtures.json').read_text(encoding='utf-8'));version=(fixture_source/'ffmpeg-version.txt').read_text(encoding='utf-8').strip()
        if fixture_source!=work:
            for case in manifest['cases']:
                for name in [case['file'],case['reference']]:shutil.copyfile(fixture_source/name,work/name)
            for case in manifest['bad']:shutil.copyfile(fixture_source/case['file'],work/case['file'])
            for name in manifest['extras']:shutil.copyfile(fixture_source/name,work/name)
    else:
        version=run(['ffmpeg','-version']).splitlines()[0];manifest={'cases':[],'bad':[],'extras':[]};tracks={}
        def ff(*args):return run(['ffmpeg','-hide_banner','-loglevel','error','-y',*args])
        def add(name,track,description,*,data=None,choice=0,fuzz=False):
            if data is not None:(work/name).write_bytes(data)
            private=track['private'];size=struct.unpack_from('<H',private,16)[0];header=private[18:18+size];rate,channels=struct.unpack_from('<I',header,36)[0],struct.unpack_from('<I',header,48)[0]
            packets=track['frames'];reference=name+'.packets';(work/reference).write_bytes(struct.pack('<I',len(header))+header+struct.pack('<I',len(packets))+b''.join(struct.pack('<I',len(x))+x for x in packets))
            trim=(track.get('discard',0)*rate+500000000)//1000000000
            start=(track.get('codec_delay',0)*rate+500000000)//1000000000
            lead=max(0,(track['timestamps_ns'][0]*rate+500000000)//1000000000) if track.get('timestamps_ns') else 0
            manifest['cases'].append({'file':name,'reference':reference,'rate':rate,'channels':channels,'trim_samples':trim,'start_samples':start,'leading_frames':lead,'track_choice':choice,'fuzz':fuzz,'description':description})
        def encode(name,rate,channels,quality=8,group=1,vbr=False,duration=.53,video=False):
            tone=f'aevalsrc=if(lt(mod(t\\,0.4)\\,0.22)\\,0.23*sin(2*PI*337*t)\\,0)|0.14*sin(2*PI*911*t):s={rate}:d={duration}'
            cmd=['-f','lavfi','-i',tone]
            if video:cmd+=['-f','lavfi','-i',f'testsrc=size=64x48:rate=10:duration={duration}','-c:v','mpeg4']
            cmd+=['-ac',channels,'-c:a','libspeex','-cbr_quality',quality,'-frames_per_packet',group,'-metadata','title='+name]
            if vbr:cmd+=['-q:a','5','-vad','1','-dtx','1']
            ff(*cmd,work/name);t=mkv.parse(work/name);assert t['codec']=='A_MS/ACM' and t['private'][:2]==b'\x09\xa1';tracks[name]=t;add(name,t,f'FFmpeg {rate} Hz/{channels} channels, quality {quality}, group {group}'+(', VBR/VAD/DTX' if vbr else '')+(', interleaved MPEG-4 video' if video else ''),fuzz=name=='16000-2-q5.mka');return t
        for rate in (8000,16000,32000):
            for channels in (1,2):
                for quality,group in [(0,1),(5,5),(10,8)]:encode(f'{rate}-{channels}-q{quality}.mka',rate,channels,quality,group)
                encode(f'{rate}-{channels}-vbr.mka',rate,channels,group=2,vbr=True,duration=.93)
        encode('video.mkv',16000,2,group=5,video=True)
        for rate,channels in [(8000,1),(16000,2),(32000,2)]:encode(f'lifecycle-{rate}.mka',rate,channels,group=8,duration=12)
        # Lacing/unknown-size variants retain the independent encoder packets.
        for rate in (8000,16000,32000):
            t=tracks[f'{rate}-2-q5.mka']
            for mode in (1,2,3):
                for unknown in (False,True):add(f'laced-{rate}-{mode}-{int(unknown)}.mka',t,f'lace {mode}, unknown Segment/Cluster={unknown}',data=mkv.mux(t,lacing=mode,unknown=unknown))
            # Exercise the packet/output bound in every mode with stereo.
            band={8000:0,16000:1,32000:2}[rate];frames=[]
            for count in (1,2,64,3):
                bits=('00000'+'1000'*band)*count
                if len(bits)%8:bits+='0'+'1'*((-len(bits)-1)%8)
                frames.append(int(bits,2).to_bytes(len(bits)//8,'big'))
            private=bytearray(t['private']);struct.pack_into('<I',private,18+64,64)
            bounded=dict(t,private=bytes(private),frames=frames,discard=0,rate=rate,sample_lengths=[n*rate//50 for n in (1,2,64,3)])
            add(f'maximum-group-{rate}.mka',bounded,'64-frame packet capacity, stereo, null submodes',data=mkv.mux(bounded,lacing=3))
        t=tracks['16000-2-q5.mka'];private=t['private']
        # cbSize is authoritative; permitted trailing private bytes are ignored.
        padded=dict(t,private=private+b'ignored trailer');add('private-trailer.mka',padded,'undeclared trailing CodecPrivate bytes ignored',data=mkv.mux(padded))
        extended=bytearray(private);struct.pack_into('<H',extended,16,96);struct.pack_into('<I',extended,18+32,96);extended+=bytes(16);extended=dict(t,private=bytes(extended));add('extended-header.mka',extended,'extended Speex identification header',data=mkv.mux(extended))
        padded=dict(t,discard=1250000);add('discard-padding.mka',padded,'final DiscardPadding trims 20 samples at 16 kHz',data=mkv.mux(padded,lacing=3))
        ignored_audio=dict(t,audio=mkv.element(0xB5,struct.pack('>d',44100.0))+mkv.uint(0x9F,7));add('codec-header-authority.mka',ignored_audio,'WAVE/Speex headers determine decoded rate/channels',data=mkv.mux(ignored_audio))
        # A real mixed-codec file exercises default flags and explicit ordinals.
        ff('-i',work/'8000-1-q5.mka','-i',work/'32000-2-q5.mka','-f','lavfi','-i','sine=frequency=557:sample_rate=48000:duration=0.53','-map','0:a','-map','1:a','-map','2:a','-c:a:0','copy','-c:a:1','copy','-c:a:2','libopus','-disposition:a:0','0','-disposition:a:1','default','-disposition:a:2','0',work/'multiple.mka')
        manifest['extras'].append('multiple.mka')
        for choice,base in [(0,'32000-2-q5.mka'),(1,'8000-1-q5.mka'),(2,'32000-2-q5.mka')]:
            name=f'multiple-{choice}.mka';shutil.copyfile(work/'multiple.mka',work/name);add(name,mkv.parse(work/name,choice or 2),'mixed-codec default/explicit audio ordinal with its actual media origin',choice=choice)
        ff('-copyts','-i',work/'multiple.mka','-map','0:a:2','-c','copy','-avoid_negative_ts','disabled',work/'third.mka');manifest['extras'].append('third.mka')
        # Unsupported ACM tracks count but must not capture Automatic.
        unknown=bytearray(private);struct.pack_into('<H',unknown,0,0x161)
        before=mkv.uint(0xD7,91)+mkv.uint(0x83,2)+mkv.uint(0x88,1)+mkv.element(0x86,b'A_MS/ACM')+mkv.element(0x63A2,unknown)
        data=mkv.mux(t,extra_tracks=[before],selected_default=0,number=7)
        add('unsupported-before.mka',t,'unknown ACM is counted and skipped by Automatic',data=data)
        # Private before CodecID and unrelated track metadata remain valid.
        entry=mkv.element(0x63A2,private)+mkv.element(0x86,b'A_MS/ACM')+mkv.uint(0xD7,1)+mkv.uint(0x83,2)+mkv.element(0xE1,t['audio'])+mkv.uint(0x56AA,t.get('codec_delay',0))
        clusters=b''.join(mkv.element(0x1F43B675,mkv.uint(0xE7,ts//1000000)+mkv.element(0xA3,mkv.size_bytes(1)+b'\0\0\x80'+f)) for ts,f in zip(t['timestamps_ns'],t['frames']))
        data=mkv.element(0x1A45DFA3,mkv.element(0x4282,b'matroska'))+mkv.element(0x18538067,mkv.element(0x1654AE6B,mkv.element(0xAE,entry))+clusters)
        add('private-first.mka',t,'CodecPrivate precedes CodecID',data=data)
        # Malformed wrappers and headers are rejected before any unsafe read.
        def bad(name,payload=None,**change):
            track=dict(t,**change)
            if payload is not None:track['private']=bytes(payload)
            path='bad-'+name+'.mka';(work/path).write_bytes(mkv.mux(track));manifest['bad'].append({'file':path})
        bad('missing-private',private=None);bad('short-wave',private[:17]);bad('raw-header',private[18:]);bad('invented-id',codec='A_SPEEX')
        for name,offset,fmt,value in [('small-cb',16,'<H',79),('large-cb',16,'<H',65535),('wave-rate',4,'<I',8000),('wave-channels',2,'<H',1),('header-size',50,'<I',81),('mode',58,'<I',3),('version',62,'<I',3),('channels',66,'<I',3)]:
            b=bytearray(private);struct.pack_into(fmt,b,offset,value);bad(name,b)
        bad('oversized-discard',discard=1000000000000);bad('excessive-negative-discard',discard=-1000000000000)
        bad('payload',frames=[b'\x48']);bad('control-only',frames=[b'\x7f'])
    (work/'fixtures.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8');(work/'ffmpeg-version.txt').write_text(version+'\n',encoding='utf-8')
    ref=module('speex_reference',ROOT/'tests/build-speex-reference.py');_,includes,sources=ref.prepare();reference=out/('speex-matroska-reference'+suffix);compile_c(reference,[ROOT/'tests/speex-file-reference.c',*sources],defines=['FLOATING_POINT','EXPORT=','MAX_CHARS_PER_FRAME=16384'],includes=[*includes,ROOT/'tests'])
    shared={p.stem for p in (ROOT/'src').glob('*.s')}|{'platform','linux_platform'};objects=[p for p in sorted((out/'obj').glob('*.obj' if WINDOWS else '*.o')) if p.stem in shared];libraries=list((out/'obj').glob('*.lib')) if WINDOWS else ['-no-pie','-Wl,-z,noexecstack']
    seek=out/('speex-matroska-seek'+suffix);chain=out/('speex-matroska-chain'+suffix);guard=out/('speex-matroska-guard'+suffix);catalog=out/('speex-matroska-catalog'+suffix)
    for target,file in [(seek,'seek-oracle.c'),(chain,'chain-oracle.c'),(guard,'speex-matroska-oracle.c'),(catalog,'track-catalog-oracle.c')]:compile_c(target,[ROOT/'tests'/file],objects=objects,libraries=libraries)
    checks=[]
    for case in manifest['cases']:
        path=work/case['file'];raw=work/(path.stem+'.raw.f32');run([reference,work/case['reference'],raw]);expected=work/(path.stem+'.reference.f32');data=raw.read_bytes()[case.get('start_samples',0)*8:];trim=case['trim_samples'];expected.write_bytes(bytes(case.get('leading_frames',0)*8)+(data[:-trim*8] if trim else data));pcm=work/(path.stem+'.lamp.f32');pcm.unlink(missing_ok=True);choice=case['track_choice'];options=['--track',choice] if choice else [];stats=run([cli,'--decode',*options,path,pcm]);assert pcm.read_bytes()==expected.read_bytes(),(case,stats)
        detail=json.loads(run([seek,path,expected,0,0,0,choice]).strip().splitlines()[-1])
        bounds=json.loads(run([guard,path,expected,case['rate'],case['channels'],choice,int(case['fuzz'])]).strip().splitlines()[-1]);checks.append({**case,'result':'exact official float PCM','frames':pcm.stat().st_size//8,'seeks':detail,'guarded':bounds,'fixture_sha256':hashlib.sha256(path.read_bytes()).hexdigest()});print(f"{path.name}: exact PCM and guarded input/output",flush=True)
    rejected=[]
    for case in manifest['bad']:rejected.append({**case,**json.loads(run([chain,'reject',work/case['file']]).strip().splitlines()[-1])})
    catalogs=[]
    for file,choice,count,selected in [('multiple.mka',0,3,2),('multiple.mka',1,3,1),('multiple.mka',2,3,2),('multiple.mka',3,3,3),('unsupported-before.mka',0,2,2),('unsupported-before.mka',1,0,0),('unsupported-before.mka',2,2,2)]:catalogs.append({'file':file,**json.loads(run([catalog,work/file,choice,count,selected]).strip().splitlines()[-1])})
    a=work/'third-selected.f32';b=work/'third-alone.f32'
    for p in [a,b]:p.unlink(missing_ok=True)
    run([cli,'--decode','--track',3,work/'multiple.mka',a]);run([cli,'--decode',work/'third.mka',b]);assert a.read_bytes()==b.read_bytes()
    cancellation=[]
    for mode in ['cancel-open','cancel-read']:cancellation.append({'test':mode,**json.loads(run([chain,mode,work/'lifecycle-16000.mka']).strip().splitlines()[-1])})
    lifecycle=[]
    if args.probe:
        if not WINDOWS:raise RuntimeError('Native Windows required')
        probe=out/'engine-probe.exe';assert b'Muted output: lifecycle exercised with volume zero.' in probe.read_bytes()
        for rate in (8000,16000,32000):
            detail=run([probe,work/f'lifecycle-{rate}.mka'],timeout=75);assert 'Passed: playback, pause, resume, stop, reopen, seek, paused seek and cancelled open.' in detail;lifecycle.append({'rate':rate,'details':detail.splitlines(),'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest()})
    paths=['src/mkv.s','src/track.s','src/speex_track.s','src/speex_packet.s','tests/verify-speex-matroska.py','tests/verify-matroska.py','tests/speex-matroska-oracle.c','tests/speex-file-reference.c','tests/seek-oracle.c','tests/chain-oracle.c','tests/track-catalog-oracle.c']
    report={'result':'passed','suite':'speex-matroska','platform':platform.platform(),'recorded_utc':datetime.now(timezone.utc).isoformat(),'ffmpeg':version,'reference':'Unchanged test-only Speex 1.2.1 float decoder on independent packet extraction','archive_url':ref.URL,'archive_sha256':ref.SHA256,'checks':checks,'rejections':rejected,'catalogs':catalogs,'third_track_opus':'exact against standalone','cancellation':cancellation,'native_lifecycle':lifecycle,'scope':'Matroska A_MS/ACM Speex tag0xa109, NB/WB/UWB mono/stereo, packet grouping, lacing, CodecDelay, final padding and selected ordinals. Timestamp scheduling/gaps, broader ACM codecs and native Mac execution are not established.','binaries':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [cli,reference,seek,chain,guard,catalog]},'sources':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}}
    report['scope']='Matroska A_MS/ACM Speex tag 0xa109, NB/WB/UWB mono/stereo, packet grouping, lacing, CodecDelay, final padding and selected ordinals. References retain actual selected-track media origins, and standalone copies preserve timestamps. Guarded mutations are capped at 128 reads and seek at 64. General timestamp scheduling has a separate suite; broader ACM codecs and native Mac execution are not established.'
    report['sources'].update({p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['src/track_time.s','src/track_cuts.s','src/decoder.s']})
    (out/'speex-matroska-verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('Passed',len(checks),'files,',sum(x['seeks']['checks'] for x in checks if x['seeks']),'exact seeks and',len(rejected),'malformed cases.')
if __name__=='__main__':main()
