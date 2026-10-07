#!/usr/bin/env python3
"""2/3/5-bit IMA WAVE: modern FFmpeg/model PCM, seeks and protected buffers.

--prepare-only writes hash-checked fixtures/reference PCM on a host with
FFmpeg 9.0.1 (the old 5.1/6.1 expansion differs for 3/5-bit codes).
--wine-only uses shipping COFF objects against the completed native run.
Reference C is confined to the guard/seek executables, never the players.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import struct
import subprocess
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parent))
import adpcm_model as model
from lamp_test import (ROOT,WINDOWS,Failure,build_lamp,build_oracles,decode_f32,exe,
    ffmpeg_version,lamp_cli,main_guard,out_dir,play,playback_requested,run,scratch,stereo_view,write_report)

def chunk(name,payload):return name+struct.pack('<I',len(payload))+payload+bytes(len(payload)%2)
def riff_chunks(data):
    result=[];pos=12
    while pos+8<=len(data):
        size=struct.unpack_from('<I',data,pos+4)[0]
        result.append((data[pos:pos+4],data[pos+8:pos+8+size]));pos+=8+size+size%2
    return result

def fixture(work,name,bits,channels,align,data,fact=None,container=None):
    wave=model.wave(0x11,channels,48000,align,data,fact,bits=bits)
    basic_wave=wave
    chunks=riff_chunks(wave);fmt=chunks[0][1]
    if container=='extensible':
        # SamplesPerBlock, channel mask and subformat GUID.
        fmt=struct.pack('<HHIIHHHHI',0xfffe,channels,48000,48000*align//model.ima_samples(align,channels,bits),
                        align,bits,22,model.ima_samples(align,channels,bits),3 if channels==2 else 0)
        fmt+=bytes.fromhex('1100000000001000800000aa00389b71');chunks[0]=(b'fmt ',fmt)
        wave=b'RIFF'+struct.pack('<I',4+sum(8+len(p)+len(p)%2 for _,p in chunks))+b'WAVE'+b''.join(chunk(k,p) for k,p in chunks)
    if container=='rf64':
        body=b''.join(chunk(k,p) for k,p in chunks)
        ds64=struct.pack('<QQQI',12+36+len(body)-8,len(data),len(model.decode(data,0x11,channels,align,bits))//channels,0)
        body=body.replace(b'data'+struct.pack('<I',len(data)),b'data'+b'\xff'*4,1)
        wave=b'RF64'+b'\xff'*4+b'WAVE'+chunk(b'ds64',ds64)+body
    if container=='w64':
        tail=bytes.fromhex('f3acd3118cd100c04f8edb8a');body=b''
        for ident,payload in chunks:
            part=ident+tail+struct.pack('<Q',24+len(payload))+payload
            body+=part+bytes(-len(part)%8)
        wave=bytes.fromhex('726966662e91cf11a5d628db04c10000')+struct.pack('<Q',40+len(body))+b'wave'+tail+body
    path=work/name;path.write_bytes(wave)
    expected=model.decode(data,0x11,channels,align,bits)
    native=struct.pack('<'+'f'*len(expected),*[v/32768 for v in expected])
    stereo=stereo_view(native,channels,0)
    if fact is not None:stereo=stereo[:fact*8]
    (work/(name+'.reference.f32')).write_bytes(stereo)
    compared=False
    if channels<=2:
        comparator=path
        if container=='extensible':
            # FFmpeg interprets Samples.wSamplesPerBlock as PCM valid bits,
            # so compare the same codec blocks in their ordinary WAVE header.
            comparator=work/(name+'.plain.wav');comparator.write_bytes(basic_wave)
        result=subprocess.run([os.environ.get('FFMPEG','ffmpeg'),'-hide_banner','-loglevel','repeat+error','-i',str(comparator),'-f','s16le','-'],capture_output=True)
        # A partial channel stripe is ignored; FFmpeg may report the leftover
        # packet as invalid after already decoding every complete group.
        allowed=('invalid number of samples in packet','Invalid data found','Error submitting packet')
        errors=[line for line in result.stderr.decode().splitlines() if not any(s in line for s in allowed)]
        if errors or result.returncode:raise Failure(f'{name}: FFmpeg failed: {errors}')
        packed=struct.pack('<'+'h'*len(expected),*expected)
        if result.stdout!=packed:raise Failure(f'{name}: model differs from FFmpeg; prepare with FFmpeg 9.0.1')
        compared=True
    first=data[:align];chans=model.ima_block(first,channels,bits=bits)
    first_pcm=[chans[c][i] for i in range(len(chans[0])) for c in range(channels)]
    first_native=struct.pack('<'+'f'*len(first_pcm),*[v/32768 for v in first_pcm])
    (work/(name+'.fmt')).write_bytes(fmt);(work/(name+'.block')).write_bytes(first)
    (work/(name+'.block.f32')).write_bytes(stereo_view(first_native,channels,0))
    return dict(name=name,bits=bits,channels=channels,frames=len(stereo)//8,ffmpeg_exact=compared,ffmpeg_equivalent_header=container=='extensible',align=align)

def prepare(work):
    rng=random.Random(20261015);files=[];coverage={}
    for bits in (2,3,5):
        size=model.IMA_GROUP_BYTES[bits]
        for channels in range(1,9):
            align=channels*(4+size*5)
            data=bytearray(model.random_ima(rng,channels,align,89))
            # Every initial step index and every code value, including sign.
            for block in range(89):
                for c in range(channels):struct.pack_into('<h',data,block*align+c*4+2,(block+c)%89)
            if channels==1:
                codes=set()
                for at in range(0,len(data),align):
                    packed=int.from_bytes(data[at+4:at+align],'little')
                    codes.update(packed>>(i*bits)&((1<<bits)-1) for i in range((align-4)*8//bits))
                if codes!=set(range(1<<bits)):raise Failure('Code coverage incomplete')
                coverage[bits]=dict(initial_step_indexes=89,codes=len(codes))
            files.append(fixture(work,f'ima-{bits}bit-{channels}ch.wav',bits,channels,align,bytes(data)))
        for kind in ('fact','partial','header','maximum','extensible','rf64','w64'):
            channels=1 if kind in ('header','maximum') else 2
            align=65535 if kind=='maximum' else channels*(4+size*7)
            partial=channels*4 if kind=='header' else channels*(4+size*2)+size*channels-1 if kind=='partial' else 0
            data=model.random_ima(rng,channels,align,0 if kind=='header' else 1 if kind=='maximum' else 4,partial)
            samples=len(model.decode(data,0x11,channels,align,bits))//channels
            fact=samples-13 if kind=='fact' else None
            ext='w64' if kind=='w64' else 'wav'
            files.append(fixture(work,f'ima-{bits}bit-{kind}.{ext}',bits,channels,align,data,fact,kind))
    rejections=[]
    for bits in (2,3,5):
        for width in (1,6):
            name=f'unsupported-{bits}bit-as-{width}bit.wav'
            data=bytearray((work/f'ima-{bits}bit-2ch.wav').read_bytes())
            struct.pack_into('<H',data,data.index(b'fmt ')+8+14,width)
            (work/name).write_bytes(data);rejections.append(name)
    hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(work.iterdir()) if p.is_file() and p.name!='manifest.json' and not p.name.endswith('.ours.f32')}
    (work/'manifest.json').write_text(json.dumps(dict(files=files,rejections=rejections,coverage=coverage,hashes=hashes,ffmpeg=ffmpeg_version(),
        model_sha256=hashlib.sha256((ROOT/'tests/adpcm_model.py').read_bytes()).hexdigest(),
        environment=dict(platform=platform.platform(),python=sys.version)),indent=2)+'\n')
    print(f'Prepared {len(files)} streams, {sum(f["ffmpeg_exact"] for f in files)} exact FFmpeg comparisons.',flush=True)

def oracle(command,args,env=None):
    with tempfile.TemporaryFile() as output:
        result=subprocess.run([*map(str,command),*map(str,args)],stdout=output,stderr=subprocess.STDOUT,env=env,timeout=180)
        output.seek(0);text=output.read().decode('utf-8','replace')
    if result.returncode:raise Failure(f'{Path(str(command[-1])).name} exited {result.returncode}: {text[-1000:]}')
    return json.loads(text.splitlines()[-1])

def main():
    work=scratch('ima-widths')
    if '--prepare-only' in sys.argv:prepare(work);return
    if not (work/'manifest.json').exists():prepare(work)
    manifest=json.loads((work/'manifest.json').read_text())
    if manifest['model_sha256']!=hashlib.sha256((ROOT/'tests/adpcm_model.py').read_bytes()).hexdigest():raise Failure('Reference model changed; prepare fixtures again')
    for name,digest in manifest['hashes'].items():
        if hashlib.sha256((work/name).read_bytes()).hexdigest()!=digest:raise Failure('Fixture changed: '+name)
    wine='--wine-only' in sys.argv;env=None
    names={'ima-widths-oracle':'ima-widths-oracle.c','seek-oracle':'seek-oracle.c','chain-oracle':'chain-oracle.c'}
    if wine:
        run([sys.executable,ROOT/'tools/build-windows.py'],capture=False)
        objects=[p for p in sorted((ROOT/'bin/obj').glob('*.obj')) if p.stem not in {'player','ui','engine-probe','ui-preview','ui-list','ui-driver'}]
        libs=[p for p in sorted((ROOT/'bin/obj').glob('*.lib')) if p.name!='lamp-test.lib']
        for name,source in names.items():
            run([os.environ.get('MINGW_CC','x86_64-w64-mingw32-gcc'),'-O2','-std=c11','-municode','-I',ROOT/'tests',ROOT/'tests'/source,*objects,*libs,'-lm','-o',ROOT/'bin'/(name+'.exe')])
        env=dict(os.environ,WINEDEBUG='err+all');cli=['wine',ROOT/'bin/lamp-cli.exe']
        guard=['wine',ROOT/'bin/ima-widths-oracle.exe'];seek=['wine',ROOT/'bin/seek-oracle.exe'];chain=['wine',ROOT/'bin/chain-oracle.exe']
        prior=json.loads((out_dir()/'ima-widths-verification.json').read_text())
        if prior['result']!='passed' or prior['fixture_hashes']!=manifest['hashes']:raise Failure('Matching native run must pass first')
    else:
        library=build_lamp();build_oracles(out_dir(),names,library)
        cli=[lamp_cli()];guard=[exe('ima-widths-oracle')];seek=[exe('seek-oracle')];chain=[exe('chain-oracle')]
    checks=[]
    for entry in manifest['files']:
        name=entry['name'];path=work/name;reference=work/(name+'.reference.f32');ours=work/(name+'.ours.f32');ours.unlink(missing_ok=True)
        run([*cli,'--decode',path,ours],env=env,timeout=180)
        if ours.read_bytes()!=reference.read_bytes():raise Failure(name+': LAMP PCM differs')
        proof=oracle(guard,[work/(name+'.fmt'),work/(name+'.block'),work/(name+'.block.f32')],env)
        positions=oracle(seek,[path,reference,0],env)
        checks.append(dict(test=name,result='exact PCM',bits=entry['bits'],channels=entry['channels'],frames=entry['frames'],
            comparator=('model and FFmpeg equivalent ordinary WAVE header' if entry['ffmpeg_equivalent_header'] else 'model and FFmpeg original container') if entry['ffmpeg_exact'] else 'model through shared speaker weights',guard=proof,seeks=positions))
        print(f'{name}: exact PCM, protected bounds and {positions["checks"]} seeks',flush=True)
    for name in manifest['rejections']:
        with tempfile.TemporaryFile() as output:
            rejected=subprocess.run([*map(str,cli),'--check',str(work/name)],stdout=output,stderr=subprocess.STDOUT,env=env,timeout=120)
            output.seek(0);text=output.read().decode('utf-8','replace')
        proof=oracle(chain,['reject',work/name],env)
        if rejected.returncode!=2 or proof['decode_error']!=101:raise Failure(name+': expected unsupported code width: '+text[-1000:])
        checks.append(dict(test=name,result='unsupported width rejected',oracle=proof))
    for bits in (2,3,5):
        for mode in ('cancel-open','cancel-read'):
            proof=oracle(chain,[mode,work/f'ima-{bits}bit-8ch.wav'],env)
            checks.append(dict(test=f'{bits}-bit {mode}',result=proof))
    if playback_requested(sys.argv[1:]) and not wine:
        checks.append(dict(test='5-bit IMA playback',result='passed',stats=play(work/'ima-5bit-2ch.wav')))
    write_report('ima-widths-wine' if wine else 'ima-widths',dict(result='passed',checks=checks,fixture_hashes=manifest['hashes'],
        reference_ffmpeg=manifest['ffmpeg'],reference_environment=manifest['environment'],coverage=manifest['coverage'],
        ffmpeg_exact_cases=sum(f['ffmpeg_exact'] for f in manifest['files']),equivalent_header_cases=sum(f['ffmpeg_equivalent_header'] for f in manifest['files']),
        oracle_source_sha256=hashlib.sha256((ROOT/'tests/ima-widths-oracle.c').read_bytes()).hexdigest(),
        environment=dict(platform=platform.platform(),python=sys.version),
        scope='2/3/5-bit WAVE IMA, 1-8 channels, every initial step index, full/partial/header-only/maximum blocks, fact trimming, extensible/RF64/Wave64, exact seeks and protected packet/output bounds; modern shift/add expansion differs from FFmpeg 5.1/6.1 for 3/5-bit codes'))
    print(f'Passed {len(checks)} IMA width cases.',flush=True)
if __name__=='__main__':main_guard(main)
