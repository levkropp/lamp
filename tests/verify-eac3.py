#!/usr/bin/env python3
"""Conventional E-AC-3 substream 0: PCM, containers, timing and parser bounds.

FFmpeg encoder fixtures plus model-written fields/frames it does not produce.
Enhanced coupling, dependent/additional substreams and reduced rates
have explicit unsupported checks. This is a partial E-AC-3 profile, not Atmos
rendering. Linux or native Windows; --skip-playback omits sink capture.
--wine-only checks the Windows CLI against a completed Linux run; provide a
display (for example, xvfb-run -a python3 tests/verify-eac3.py --wine-only).
Spectral extension and AHT have separate suites.
"""
import importlib.util
import json
import math
import struct
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import eac3_model as model
import eac3_vectors as vectors
from lamp_test import (Failure, build_lamp, build_oracles, decode_f32, exe, ffmpeg, main_guard,
                       out_dir, play, playback_requested, run, scratch, write_report)

_spec = importlib.util.spec_from_file_location('verify_ac3', Path(__file__).with_name('verify-ac3.py'))
ac3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ac3)


def against(path, checks, crc=False):
    h = model.header(next(model.frames(path.read_bytes())))
    pcm = Path(str(path) + '.f32')
    stats = decode_f32(path, pcm)
    ref = Path(str(path) + '.ffmpeg.f32')
    ac3.reference(path, ref, h['acmod'], h['lfe'], crc)
    peak, snr = ac3.compare(pcm, ref)
    if peak > 1e-6 * max(1.0, max(map(abs, ac3.floats(ref)))) or snr < 130:
        raise Failure(f'{path.name}: {peak:.3g} peak error, {snr:.1f} dB against FFmpeg')
    checks.append({'test': path.name, 'result': 'matched', 'comparator': 'FFmpeg (shared stereo weights)',
                   'snr_db': None if math.isinf(snr) else round(snr, 1), 'peak_error': peak, 'stats': stats})
    print(f'{path.name}: {snr:.1f} dB against FFmpeg', flush=True)
    return pcm


def model_check(path, checks, ffmpeg_vq4=False):
    channels, decoder = model.decode(path.read_bytes(), ffmpeg_vq4=ffmpeg_vq4)
    native = Path(str(path)+'.native')
    ffmpeg('-cpuflags', '0', '-i', path, '-f', 'f32le', native)
    theirs = ac3.floats(native)
    positions = ac3.CHANNEL_MAP[(decoder.acmod, decoder.lfe)]
    worst = math.inf
    if len(theirs) != len(channels[0])*len(channels):
        raise Failure(f'{path.name}: model frame count mismatch')
    for ch, samples in enumerate(channels):
        ref = theirs[positions[ch]::len(channels)]
        error = sum((x-y)**2 for x,y in zip(samples, ref))
        signal = sum(y*y for y in ref) or 1.0
        worst = min(worst, math.inf if not error else 10*math.log10(signal/error))
    if worst < 130 or 'block error' in decoder.used:
        raise Failure(f'{path.name}: model {worst:.1f} dB, coverage {decoder.used}')
    checks.append({'test': 'model '+path.name, 'result': 'matched', 'snr_db': round(worst, 1),
                   **({'comparator':'stock FFmpeg; test model emulates its omitted VQ4 row zero'} if ffmpeg_vq4 else {})})
    return decoder.used


def reject(chain, path, checks, code=101):
    line = run([chain, 'reject', path]).splitlines()[-1]
    if json.loads(line)['decode_error'] != code:
        raise Failure(f'{path.name}: expected error {code}: {line}')
    checks.append({'test': path.name, 'result': 'rejected', 'oracle': json.loads(line)})


def transport_signalling_checks(work, checks):
    """Exercise each PMT route without a preceding descriptor masking it."""
    def crc(data):
        value = 0xffffffff
        for byte in data:
            value ^= byte << 24
            for _ in range(8):
                value = ((value << 1) ^ (0x04c11db7 if value & 0x80000000 else 0)) & 0xffffffff
        return value

    pcm = Path(str(work/'stereo.ec3')+'.f32').read_bytes()
    for name, source, route in [('registered.ts', 'stereo.ts', 'registration'),
                                ('descriptor.ts', 'stereo.dvb.ts', 'descriptor'),
                                ('probed.ts', 'stereo.ts', 'probe')]:
        data = bytearray((work/source).read_bytes())
        changed = 0
        for offset in range(0, len(data), 188):
            packet = data[offset:offset+188]
            pid = ((packet[1] & 31) << 8) | packet[2]
            if pid != 4096 or not packet[1] & 64:
                continue
            control = (packet[3] >> 4) & 3
            if control not in (1, 3):
                raise Failure('PMT fixture has no payload')
            start = 4 + (1+packet[4] if control == 3 else 0)
            start += 1 + packet[start]
            size = 3 + ((packet[start+1] & 15) << 8 | packet[start+2])
            if start+size > 188:
                raise Failure('PMT fixture spans packets')
            section = packet[start:start+size]
            if section[0] != 2 or crc(section):
                raise Failure('PMT fixture has invalid section/CRC')
            es = 12 + ((section[10] & 15) << 8 | section[11])
            info = ((section[es+3] & 15) << 8) | section[es+4]
            if es+5+info != len(section)-4 or section[es+5:es+11] != b'\x05\x04EAC3':
                raise Failure('unexpected E-AC-3 PMT fixture')
            section[es] = 6
            if route == 'descriptor':
                if section[es+11:es+14] != b'\x7a\x01\x00':
                    raise Failure('missing DVB enhanced AC-3 descriptor')
                # User-private descriptor: its uninterpreted payload is valid,
                # leaving the following DVB descriptor as the audio identifier.
                section[es+5] = 0x80
            elif route == 'probe':
                del section[es+5:es+11]
                section[es+3:es+5] = b'\xf0\x00'
                length = len(section)-3
                section[1] = (section[1] & 0xf0) | (length >> 8)
                section[2] = length & 255
            section[-4:] = struct.pack('>I', crc(section[:-4]))
            packet[start:] = section + bytes([255]) * (188-start-len(section))
            data[offset:offset+188] = packet
            changed += 1
        if not changed:
            raise Failure('PMT fixture has no signalling sections')
        path = work/name
        path.write_bytes(data)
        output = Path(str(path)+'.f32')
        decode_f32(path, output)
        if output.read_bytes() != pcm:
            raise Failure(name+' signalling changed PCM')
        checks.append({'test': name, 'result': 'exact', 'PMT_route': route,
                       'comparator': 'raw E-AC-3'})


def windows_checks():
    """Shipping PE CLI vs Linux PCM on an already initialized Wine display."""
    import os
    import subprocess
    from lamp_test import ROOT
    run([sys.executable, ROOT/'tools/build-windows.py'],capture=False)
    from lamp_test import GENERATED
    work=GENERATED/'eac3'
    command=['wine',str(ROOT/'bin/lamp-cli.exe')]
    env=dict(os.environ,WINEDEBUG='-all')
    checks=[]
    linux = json.loads((out_dir()/'eac3-verification.json').read_text())
    if linux['result'] != 'passed': raise Failure('Linux E-AC-3 checks must pass before Wine')
    names = {c['test'].split()[0] for c in linux['checks'] if c['result'] != 'rejected'}
    files=[work/name for name in sorted(names) if (work/name).is_file()
           and (work/name).suffix in ('.ec3','.mka','.mp4','.ts')
           and Path(str(work/name)+'.f32').exists()]
    for path in files:
        output=work/'windows.f32';output.unlink(missing_ok=True)
        run([*command,'--decode',path,output],env=env,timeout=120)
        if output.read_bytes()!=Path(str(path)+'.f32').read_bytes():
            raise Failure('Windows '+path.name+' PCM differs')
        checks.append({'test':path.name,'result':'exact PCM'})
        if path.name.startswith('seek-') or path.name.startswith('variable.'):
            for ms in (17,60,150):
                output.unlink(missing_ok=True)
                run([*command,'--decode','--start',f'{ms/1000:.3f}',path,output],env=env,timeout=120)
                if output.read_bytes()!=Path(str(path)+'.f32').read_bytes()[ms*48*8:]:
                    raise Failure('Windows '+path.name+' --start '+str(ms)+' differs')
                checks.append({'test':f'{path.name} --start {ms} ms','result':'exact'})
    for name in ('dependent','substream1','reduced-rate','reserved-type','ecplinu',
                 'late_coupling','snr_reuse','appended-dependent','appended-substream1','layout-change','garbage','bad-size'):
        path=work/(name+'.ec3')
        result=subprocess.run([*command,'--check',str(path)],env=env,timeout=120,
                              stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        if result.returncode!=2:raise Failure('Windows '+path.name+' did not reject')
        checks.append({'test':path.name,'result':'rejected'})
    write_report('eac3-wine',{'result':'passed','checks':checks,
                 'scope':'Windows CLI under Wine vs Linux PCM; variable-frame --start and unsupported/malformed rejections'})
    print(f'Passed {len(checks)} Windows E-AC-3 checks.',flush=True)


def main():
    library = build_lamp()
    build_oracles(out_dir(), {'seek-oracle': 'seek-oracle.c', 'chain-oracle': 'chain-oracle.c',
                            'eac3-cap-oracle': 'eac3-cap-oracle.c'}, library)
    chain, seek = exe('chain-oracle'), exe('seek-oracle')
    work = scratch('eac3')
    checks = []
    profiles = [('mono',48000,'mono',96), ('stereo',48000,'stereo',192),
                ('stereo44',44100,'stereo',128), ('stereo32',32000,'stereo',64),
                ('low',48000,'stereo',32), ('high',48000,'stereo',1024),
                ('2.1',48000,'2.1',192), ('3.0',48000,'3.0',256),
                ('3.0back',48000,'3.0(back)',256), ('4.0',48000,'4.0',320),
                ('quad',48000,'quad(side)',320), ('5.0',48000,'5.0(side)',384),
                ('5.1',48000,'5.1(side)',448), ('5.1-44',44100,'5.1(side)',384),
                ('4.1-32',32000,'4.1',320)]
    for i,(name, rate, layout, bitrate) in enumerate(profiles):
        path = work/(name+'.ec3')
        ffmpeg('-f','lavfi','-i',f'anoisesrc=r={rate}:d=0.6:a=0.3:seed={i+1}',
               '-af',f'aformat=channel_layouts={layout}', '-c:a','eac3','-b:a',f'{bitrate}k','-f','eac3',path)
        against(path, checks)
    # Actual encoder streams validate the separate parser/model before it writes streams.
    used = model_check(work/'stereo.ec3', checks) | model_check(work/'5.1.ec3', checks)
    for mode in range(8):
        name = work/f'written-mode{mode}.ec3'
        data, coverage = vectors.stream(2026+mode, 8, mode, mode%2,
                                       blocks=[1,2,3,6], short=0.25, snroffststr=mode%3,
                                       bamode=mode%2, dithflage=mode%2, mixdef=mode%4)
        name.write_bytes(data)
        used |= coverage
        against(name, checks)
        model_check(name, checks)
    for lut in (True, False):
        path = work/('lut.ec3' if lut else 'defaults.ec3')
        options = dict(expstre=0, frmchexpstr=list(range(32)), bamode=0, blkswe=0, dithflage=0,
                       frmfgaincode=0, dbaflde=0, skipflde=0, snroffststr=0)
        if not lut:
            options.update(expstre=1, ahte=1, frmchexpstr=0, transproce=0, spxattene=0, metadata=0)
        data, coverage = vectors.stream(2070+lut, 32 if lut else 6, 2, **options)
        path.write_bytes(data)
        used |= coverage
        against(path, checks)
        model_check(path, checks)
    for typ in (0, 2):
        path=work/f'converted{typ}.ec3'
        data,_=vectors.stream(2080+typ,8,3,1,blocks=[6,3,2,1],typ=typ)
        path.write_bytes(data);against(path,checks);used |= model_check(path,checks)
        line=run([exe('eac3-cap-oracle'),path]).splitlines()[-1]
        checks.append({'test':path.name+' packet capacity','result':line})
    # Container copies, packet duration/trim, track selection and raw tags/truncation.
    for name in ('stereo','5.1','mono'):
        raw = work/(name+'.ec3')
        pcm = Path(str(raw)+'.f32').read_bytes()
        for suffix, flags in [('mka',[]), ('mp4',[]), ('frag.mp4',['-movflags','frag_keyframe+empty_moov+delay_moov']),
                              ('ts',['-f','mpegts']), ('dvb.ts',['-f','mpegts','-mpegts_flags','system_b'])]:
            path = work/(name+'.'+suffix)
            ffmpeg('-i',raw,'-c','copy',*flags,path)
            output = Path(str(path)+'.f32')
            decode_f32(path,output)
            if output.read_bytes() != pcm:
                raise Failure(f'{path.name}: differs from raw decode')
            checks.append({'test':path.name,'result':'exact','comparator':'raw E-AC-3'})
        tagged = work/(name+'-tagged.ec3')
        tagged.write_bytes(b'ID3\x04\0\0\0\0\0\0'+raw.read_bytes()+b'TAG'+bytes(125))
        decode_f32(tagged,Path(str(tagged)+'.f32'))
        if Path(str(tagged)+'.f32').read_bytes()!=pcm:
            raise Failure('ID3 tags altered PCM')
        checks.append({'test':tagged.name,'result':'exact'})
    transport_signalling_checks(work, checks)
    # Force explicit head and tail trimming independently of the muxer's
    # encoder-padding conventions. The raw PCM already matches FFmpeg.
    spec = importlib.util.spec_from_file_location('mp4_tests', Path(__file__).with_name('verify-mp4.py'))
    mp4 = importlib.util.module_from_spec(spec);spec.loader.exec_module(mp4)
    edited = bytearray((work/'stereo.mp4').read_bytes())
    mvhd,_ = mp4.find(edited,'moov/mvhd')
    elst,_ = mp4.find(edited,'moov/trak/edts/elst')
    if edited[mvhd] or edited[elst]: raise Failure('expected version-0 MP4 edit fixture')
    timescale = struct.unpack_from('>I',edited,mvhd+12)[0]
    struct.pack_into('>Ii',edited,elst+8,timescale//5,256)
    path=work/'trimmed.mp4';path.write_bytes(edited)
    output=Path(str(path)+'.f32');decode_f32(path,output)
    expected=Path(str(work/'stereo.ec3')+'.f32').read_bytes()[256*8:(256+9600)*8]
    if output.read_bytes()!=expected:raise Failure('explicit E-AC-3 MP4 trim')
    checks.append({'test':path.name,'result':'exact','head_trim':256,'presented_frames':9600})
    # Dither-free generated data makes overlap/seek correctness exact.
    for nb in (1,2,3,6,[1,2,3,6]):
        path = work/('seek-'+str(nb).replace(' ','')+'.ec3')
        data,_ = vectors.stream(2100,40,2,blocks=nb,dither=0,short=0,drc=0,metadata=0)
        path.write_bytes(data)
        pcm=Path(str(path)+'.f32');decode_f32(path,pcm)
        line=run([seek,path,pcm,'0']).splitlines()[-1]
        checks.append({'test':path.name+' seeks','result':line})
        print(path.name+' seeks: '+line,flush=True)
    # Variable frame lengths survive container packet tables and their seeks.
    # MP4 E-AC-3 access units aggregate exactly six audio blocks. The
    # 1+2+3, 6 sequence exercises changing sync-frame lengths within that rule.
    raw=work/'seek-[1,2,3,6].ec3'
    for suffix,flags in [('mka',[]),('mp4',[]),('frag.mp4',['-movflags','frag_keyframe+empty_moov+delay_moov'])]:
        path=work/('variable.'+suffix)
        ffmpeg('-i',raw,'-c','copy',*flags,path)
        output=Path(str(path)+'.f32');decode_f32(path,output)
        pcm=Path(str(raw)+'.f32')
        if output.read_bytes()!=pcm.read_bytes():raise Failure(path.name+' variable duration')
        line=run([seek,path,pcm,'0']).splitlines()[-1]
        checks.append({'test':path.name+' variable-frame seeks','result':line})
    data=(work/'stereo.ec3').read_bytes(); first=next(model.frames(data))
    cut=work/'truncated-final.ec3';cut.write_bytes(data[:-7])
    output=Path(str(cut)+'.f32');decode_f32(cut,output)
    expected=Path(str(work/'stereo.ec3')+'.f32').read_bytes()[:-model.header(first)['blocks']*256*8]
    if output.read_bytes()!=expected:raise Failure('truncated final frame count')
    checks.append({'test':cut.name,'result':'exact','note':'last incomplete sync frame dropped'})
    # Header-supported tools reject at read; unsupported sync profiles reject at open.
    for label,offset,mask,value in [('dependent',2,0xc0,0x40),('substream1',2,0x38,8),
                                    ('reduced-rate',4,0xc0,0xc0),('reserved-type',2,0xc0,0xc0)]:
        modified=bytearray(first);modified[offset]=(modified[offset]&~mask)|value
        path=work/(label+'.ec3');path.write_bytes(vectors.recrc(modified))
        reject(chain,path,checks,100 if label=='reserved-type' else 101)
        if label in ('dependent','substream1'):
            path=work/('appended-'+label+'.ec3');path.write_bytes(data+vectors.recrc(modified))
            reject(chain,path,checks)
    for tool in ('ecplinu', 'late_coupling', 'snr_reuse'):
        path = work/(tool+'.ec3');path.write_bytes(vectors.unsupported(tool))
        reject(chain,path,checks)
    changed=(work/'stereo44.ec3').read_bytes()
    for label,content in [('layout-change',data+changed),('garbage',data+bytes(range(256))*8),
                          ('bad-size',first[:2]+b'\0\0'+first[4:])]:
        path=work/(label+'.ec3');path.write_bytes(content);reject(chain,path,checks,100)
    # Corrupt actual mantissa data and an invalid exponent group separately.
    # A fixed byte offset can instead enable an explicitly unsupported tool.
    class Positions(ac3.model.Reader):
        def __init__(self, frame):
            super().__init__(frame, 40)
            self.positions = {}

        def get(self, n, label=None, *context):
            self.positions.setdefault(label, (self.pos, n))
            return super().get(n, label, *context)

    reader = Positions(data[len(first):2*len(first)])
    model.Decoder().decode_frame(reader, model.header(reader.data), strict=True)
    mantissa = next((reader.positions[x] for x in ('b1','b2','b4','mant') if x in reader.positions), None)
    if mantissa is None: raise Failure('no encoded mantissa in corruption fixture')
    # CRC errors conceal a whole frame; bad exponents conceal its remaining blocks.
    for label,field,fix in [('crc',mantissa,False),('payload',mantissa,True),
                           ('bad-exponents',reader.positions['exp'],True)]:
        modified=bytearray(data);size=len(first)
        position, width = field
        if label == 'bad-exponents':
            for bit in range(position,position+width):
                modified[size+bit//8] |= 1 << (7-bit%8)
        else:
            modified[size+position//8] ^= 1 << (7-position%8)
        if fix:modified[size:2*size]=vectors.recrc(modified[size:2*size])
        path=work/(label+'.ec3');path.write_bytes(modified);against(path,checks,crc=True)
    for action in ('cancel-open','cancel-read'):
        line=run([chain,action,work/'5.1.ec3']).splitlines()[-1]
        checks.append({'test':action,'result':line})
    if playback_requested(sys.argv[1:]):
        checks.append({'test':'E-AC-3 playback','result':'played','stats':play(work/'5.1.ec3')})
    required = {f'blocks {n}' for n in (1,2,3,6)} | {f'acmod {n}' for n in range(8)} | \
               {f'frame exponent row {n}' for n in range(32)} | {f'SNR strategy {n}' for n in range(3)} | \
               {'frame type 0','frame type 2','per-block exponents','LUT exponents',
                'short blocks','mixed transforms','phase flags','dynamic range','coupling','skip field'}
    missing=required-used
    if missing:raise Failure('missing E-AC-3 coverage: '+', '.join(sorted(missing)))
    write_report('eac3',{'result':'passed','profile':'E-AC-3 conventional mantissas; independent/converted substream 0',
                         'checks':checks,'coverage':sorted(used),
                         'unsupported':['enhanced coupling','dependent/additional substreams','reduced rates','coupling first activated after block 0','older-frame SNR reuse'],
                         'specification_sha256':model._gen.SHA256,
                         'limitations':['block-0 SNR packing compatible with FFmpeg; per-block updates outside profile',
                                        'transient processing and object rendering not applied']})
    print(f'Passed {len(checks)} E-AC-3 checks.')


if __name__=='__main__': main_guard(windows_checks if '--wine-only' in sys.argv[1:] else main)
