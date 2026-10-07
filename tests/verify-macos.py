#!/usr/bin/env python3
"""Verify native ARM64 decoding; --opus runs all 35 existing normative oracles.

--audio and --ui exercise the real Core Audio device and AppKit session.
Reference C code is compiled only into test artifacts, never into the player.
"""
import argparse
import array
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import pty
import random
import re
import subprocess
import signal
import sys
import tarfile
import termios
import time
import wave

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/macos'
TESTS = ROOT / 'tests'
SUITES = ('range packet cwrs energy silk-pulses silk-indices silk-parameters '
          'silk-nlsf silk-lpc silk-state silk-prediction silk-synthesis silk-resampler '
          'silk-cng silk-plc silk-stereo silk-frame silk-packet silk-decoder allocation '
          'vq band-transform controls theta band spectral transform filter lpc pitch '
          'decoder mode stream ogg multistream').split()


def run(args, timeout=120, live=False):
    r = subprocess.run([str(a) for a in args], cwd=ROOT, capture_output=not live,
                       text=True, timeout=timeout)
    if r.returncode:
        raise RuntimeError('%s exited %s:\n%s%s' % (args[0], r.returncode, r.stdout or '', r.stderr or ''))
    return (r.stdout or '').strip()


def library():
    objects = [p for p in (OUT/'obj').glob('*.o') if p.name not in ('mac_cli.o','mac_ui.o')]
    path = OUT/'liblamp-test.dylib'
    run(['xcrun','clang','-arch','arm64','-mmacosx-version-min=12.0','-dynamiclib',
         '-o',path,*objects,'-framework','AudioToolbox'])
    return path


def runtime_checks():
    records=[]
    for name in ('lamp','lamp-cli'):
        executable=OUT/name
        assert run(['lipo','-archs',executable])=='arm64'
        linked=run(['otool','-L',executable]).splitlines()[1:]
        imports=[s.strip().split(' (')[0] for s in linked]
        assert all(s.startswith(('/System/Library/Frameworks/','/usr/lib/')) for s in imports),imports
        records.append({'file':name,'bytes':executable.stat().st_size,
                        'sha256':hashlib.sha256(executable.read_bytes()).hexdigest(),'imports':imports})
    bundle=OUT/'LAMP.app'
    run(['codesign','--verify','--strict',bundle])
    plist=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
    assert plist['LSMinimumSystemVersion']=='12.0' and plist['NSHighResolutionCapable']
    for name in ('lamp.icns','LICENSE','THIRD_PARTY_NOTICES'):
        assert (bundle/'Contents/Resources'/name).stat().st_size>0
    return {'architecture':'arm64','system_imports_only':True,'bundle_signature':'verified ad-hoc',
            'minimum_macos':plist['LSMinimumSystemVersion'],'binaries':records}


def vorbis_reference():
    """Build pinned Xiph test sources, independent of FFmpeg's encoders."""
    base = OUT/'reference'
    base.mkdir(exist_ok=True)
    pins = json.loads((TESTS/'reference/vorbis-reference-hashes.json').read_text())
    for pin in pins['archives']:
        archive = TESTS/'reference'/pin['file']
        assert hashlib.sha256(archive.read_bytes()).hexdigest() == pin['sha256']
        if not (base/pin['directory']).exists():
            with tarfile.open(archive) as t: t.extractall(base, filter='data')
    vorbis, ogg = base/'libvorbis-1.3.7', base/'libogg-1.3.6'
    # libogg's configured type header is not present in its source tarball.
    (ogg/'include/ogg/config_types.h').write_text('#include <stdint.h>\n' +
        ''.join(f'typedef {typ} {name};\n' for typ,name in [
            ('int16_t','ogg_int16_t'),('uint16_t','ogg_uint16_t'),('int32_t','ogg_int32_t'),
            ('uint32_t','ogg_uint32_t'),('int64_t','ogg_int64_t'),('uint64_t','ogg_uint64_t')]))
    names = ('mdct smallft block envelope window lsp lpc analysis synthesis psy info '
             'floor1 floor0 res0 mapping0 registry codebook sharedbook lookup bitrate vorbisfile vorbisenc').split()
    sources = [vorbis/'lib'/f'{n}.c' for n in names] + [ogg/'src'/f'{n}.c' for n in ('bitwise','framing')]
    target = OUT/'vorbis-reference'
    run(['xcrun','clang','-arch','arm64','-O2','-ffp-contract=off','-Wno-cpp',
         '-I',vorbis/'include','-I',vorbis/'lib','-I',ogg/'include',
         TESTS/'mac-vorbis-reference.c',*sources,'-o',target])
    return target


def decoder_checks(libpath, vorbis):
    lib = ctypes.CDLL(str(libpath))
    assert lib.lamp_init()
    lib.decoder_open.argtypes = [ctypes.c_char_p]
    lib.decoder_read.argtypes = [ctypes.POINTER(ctypes.c_float), ctypes.c_uint]
    lib.decoder_seek.argtypes = [ctypes.c_uint64]
    lib.decoder_seek.restype = ctypes.c_uint64
    pcm = (ctypes.c_float * 8192)()
    records = []
    seeks = 0
    fixtures = sorted((TESTS/'fixtures').glob('tone.*'))
    generated = OUT/'fixtures'
    generated.mkdir(exist_ok=True)
    # Several rates/depths/layouts and lossy modes, with independent PCM output.
    formats = [('wav','pcm_s16le'),('wav','pcm_s24le'),('wav','pcm_s32le'),
               ('wav','pcm_f32le'),('wav','pcm_f64le'),('aiff','pcm_s24be'),
               ('flac','flac'),('mp3','libmp3lame'),('ogg','libvorbis'),('opus','libopus')]
    for rate in (8000,44100,48000,96000):
        for channels in (1,2):
            for suffix,codec in formats:
                if (suffix == 'opus' and rate not in (8000,48000)) or (suffix == 'mp3' and rate==96000):
                    continue
                p = generated / f'{rate}-{channels}-{codec}.{suffix}'
                if suffix == 'ogg':
                    run([vorbis,'encode',p,rate,channels,.37])
                else: run(['ffmpeg','-v','error','-f','lavfi','-i',
                     f'sine=frequency=997:sample_rate={rate}:duration=0.37',
                     '-ac',channels,'-c:a',codec,'-y',p])
                fixtures.append(p)
    for path in fixtures:
        if path.suffix not in ('.wav','.aiff','.flac','.mp3','.ogg','.opus'): continue
        assert lib.decoder_open(os.fsencode(path)), path
        actual = array.array('f')
        while True:
            n = lib.decoder_read(pcm,4096)
            if not n: break
            actual.extend(pcm[:n*2])
        assert ctypes.c_uint.in_dll(lib,'decode_error').value == 0, path
        rate = ctypes.c_uint.in_dll(lib,'sample_rate').value
        channels = ctypes.c_uint.in_dll(lib,'source_channels').value
        command = ['ffmpeg','-v','error']
        if path.suffix == '.opus': command += ['-c:a','libopus']
        command += ['-i',str(path)]
        if channels == 1: command += ['-af','pan=stereo|c0=c0|c1=c0']
        if path.suffix == '.ogg':
            reference = subprocess.check_output([vorbis,'decode',str(path)])
            if channels == 1:
                reference = array.array('f',[x for v in array.array('f',reference) for x in (v,v)]).tobytes()
        else: reference = subprocess.check_output(command+['-ar',str(rate),'-ac','2','-f','f32le','-'])
        expected = array.array('f',reference)
        assert len(actual)==len(expected),(path,len(actual),len(expected))
        assert all(math.isfinite(x) for x in actual) and all(math.isfinite(x) for x in expected),path
        peak = max((abs(x-y) for x,y in zip(actual,expected)),default=0)
        tolerance = 2e-5 if path.suffix in ('.mp3','.opus') else 2e-6
        assert math.isfinite(peak) and peak<=tolerance,(path,peak)
        assert len(actual)==ctypes.c_uint64.in_dll(lib,'total_frames').value*2, path
        # Indexed seeks return a preceding sample, as on Windows. Reopen, then
        # discard to the requested sample. Opus reset-reference seeks are in
        # the normative multistream oracle, rather than compared to old history.
        if path.suffix != '.opus':
            length=len(actual)//2
            for at in (0,1,length//3,max(0,length-1),length):
                lib.decoder_close()
                assert lib.decoder_open(os.fsencode(path))
                start=lib.decoder_seek(at)
                while start<at:
                    n=lib.decoder_read(pcm,min(4096,at-start));assert n
                    start+=n
                n=lib.decoder_read(pcm,128)
                expected_seek=actual[at*2:at*2+n*2]
                assert len(expected_seek)==2*n
                error=max((abs(x-y) for x,y in zip(expected_seek,pcm)),default=0)
                assert error<=2e-5,(path,at,error)
                seeks+=1
        power=sum(x*x for x in expected);noise=sum((x-y)**2 for x,y in zip(actual,expected))
        records.append({'file':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
                        'rate':rate,'channels':channels,'frames':len(actual)//2,'peak_error':peak,
                        'tolerance':tolerance,'snr_db':10*math.log10(power/noise) if noise and power else None})
        lib.decoder_close()
        assert ctypes.c_uint64.in_dll(lib,'lamp_allocated_bytes').value == 0, path
    # Unicode paths and exclusive exports, including failing destinations.
    unicode_path=generated/'音楽 café lamp.wav'
    unicode_path.write_bytes((TESTS/'fixtures/tone.wav').read_bytes())
    run([OUT/'lamp-cli','--check',unicode_path])
    protected=generated/'protected.f32';protected.write_bytes(b'keep this output')
    r=subprocess.run([OUT/'lamp-cli','--decode',unicode_path,protected],capture_output=True)
    assert r.returncode==1 and protected.read_bytes()==b'keep this output'
    # Mutations may reject or decode, but must terminate without a crash/hang.
    rng=random.Random(0x1a64);mutations=0
    for source in sorted((TESTS/'fixtures').glob('tone.*')):
        if source.suffix not in ('.wav','.aiff','.flac','.mp3','.ogg','.opus'): continue
        original=source.read_bytes()
        for kind in range(32):
            data=bytearray(original)
            if kind%4==0:data=data[:rng.randrange(len(data))]
            else:
                for _ in range(1+kind):data[rng.randrange(len(data))]=rng.randrange(256)
            path=generated/'mutation.bin';path.write_bytes(data)
            r=subprocess.run([OUT/'lamp-cli','--check',path],capture_output=True,timeout=10)
            assert r.returncode in (0,2),(source,kind,r.returncode)
            mutations+=1
    return {'files':records,'seek_checks':seeks,'mutations_without_crash_or_hang':mutations,
            'unicode_paths':True,'existing_export_preserved':True,
            'ffmpeg':run(['ffmpeg','-version']).splitlines()[0],
            'opus_reference':'FFmpeg libopus decoder, selected explicitly',
            'vorbis_reference_scope':'Hash-verified Xiph 1.3.7, full PCM including terminal granule'}


def opus_checks(libpath):
    ref=OUT/'reference/opus-rfc6716'
    archive=TESTS/'reference/opus-rfc6716.tar.gz'
    patch=TESTS/'reference/opus-rfc8251.patch'
    assert hashlib.sha1(archive.read_bytes()).hexdigest()=='86a927223e73d2476646a1b933fcd3fffb6ecc8c'
    assert hashlib.sha1(patch.read_bytes()).hexdigest()=='029e3aa88fc342c91e67a21e7bfbc9458661cd5f'
    if not (ref/'.updated').exists():
        ref.parent.mkdir(parents=True,exist_ok=True)
        with tarfile.open(archive) as t:t.extractall(ref.parent,filter='data')
        run(['git','apply','--directory='+str(ref.relative_to(ROOT)),patch])
        (ref/'.updated').write_text('RFC8251')
    for name in ('celt-controls-reference','celt-theta-reference','celt-bands-reference',
                 'celt-transform-tables','silk-parameters-tables'):
        run(['node',TESTS/f'generate-{name}.js',ref,*(['--check'] if name.endswith('tables') else [])])
    run(['node',TESTS/'generate-silk-packet-reference.js',ref,ROOT/'bin/silk-packet-reference.c'])
    source=(ref/'src/opus_decoder.c').read_text()
    header=source[:source.index('#ifdef HAVE_CONFIG_H')]+\
        '\n#include <stddef.h>\ntypedef int opus_int32;\n#define OPUS_BAD_ARG -1\n#define OPUS_INVALID_PACKET -4\n'
    header+=source[source.index('int opus_packet_get_samples_per_frame('):source.index('int opus_packet_get_nb_channels(')]
    header+=source[source.index('static int parse_size('):source.index('int opus_decode_native(')]
    (ROOT/'bin/opus_packet_reference.h').write_text(header.replace('opus_packet_get_samples_per_frame',
        'reference_samples_per_frame').replace('int opus_packet_parse(','int reference_packet_parse('))
    flags=['xcrun','clang','-arch','arm64','-O2','-ffp-contract=off','-DOPUS_BUILD',
           '-DUSE_ALLOCA','-DSMALL_FOOTPRINT','-Wno-cpp']
    for folder in ('include','celt','silk','silk/float','src'):flags+=['-I',ref/folder]
    robj=OUT/'reference-obj';robj.mkdir(exist_ok=True)
    objects=[]
    for folder in ('celt','silk','silk/float','src'):
        for p in sorted((ref/folder).glob('*.c')):
            if p.name in ('opus_demo.c','opus_compare.c','opus_custom_demo.c'):continue
            o=robj/('_'.join(p.parts[-2:])+'.o')
            run([*flags,'-c',p,'-o',o]);objects.append(o)
    reference=OUT/'libopus-reference.a';run(['ar','rcs',reference,*objects])
    init=OUT/'oracle-init.c'
    init.write_text('extern int lamp_init(void); __attribute__((constructor)) static void init(void) { if (!lamp_init()) __builtin_trap(); }\n')
    generated=OUT/'oracle-src';generated.mkdir(exist_ok=True)
    globals={'sample_rate','source_channels','source_bits','decode_error','total_frames',
             'ogg_total_granule','ogg_granule','ogg_packet_page','ogg_packet_page_end'}
    for p in TESTS.glob('*.c'):
        text=p.read_text()
        def extern(m):
            return 'extern '+m[0] if all(n.strip() in globals for n in m[2].split(',')) else m[0]
        text=re.sub(r'^(uint64_t|unsigned) ([\w,]+);',extern,text,flags=re.M)
        if p.name=='opus-theta-oracle.c':
            # RFC isqrt32(0) shifts by -1, undefined in C. LAMP's defined value
            # is zero; retain normative comparisons for every nonzero input.
            text=text.replace('isqrt32(values[j])','(values[j] ? isqrt32(values[j]) : 0)')
        if p.name=='opus-packet-oracle.c':
            start=text.index('static int guard_pages');end=text.index('int main',start)
            page=os.sysconf('SC_PAGE_SIZE')
            part=text[start:end].replace('12288',str(3*page)).replace('8192',str(2*page)).replace('4096',str(page))
            text=text[:start]+part+text[end:]
        (generated/p.name).write_text(text)
    records=[]
    for name in SUITES:
        target=OUT/f'opus-{name}-oracle'
        extra=[ROOT/'bin/silk-packet-reference.c'] if name in ('silk-packet','silk-decoder','mode','stream','ogg','multistream') else []
        run([*flags,'-I',ROOT/'bin','-I',TESTS,'-I',TESTS/'mac',generated/f'opus-{name}-oracle.c',
             *extra,init,reference,libpath,'-o',target])
        result=run([target,TESTS/'fixtures/tone.opus'])
        print(f'Opus {name}: passed',flush=True)
        records.append({'suite':name,'result':'passed','stats':result})
    return {'reference':'hash-verified RFC6716 with RFC8251 updates','suites':records,
            'adaptations':['native Apple ABI wrappers','shared globals imported rather than test stubs',
                           'protected memory uses native page size','defined sqrt(0) instead of reference C negative shift']}


def layout_checks(libpath, vorbis_encoder, suites=None):
    """Reuse existing fixture/math oracles, with test-only POSIX adapters."""
    generated=OUT/'layout-src'; generated.mkdir(exist_ok=True)
    init=generated/'init.c'
    init.write_text('extern int lamp_init(void); __attribute__((constructor)) static void init(void) { if (!lamp_init()) __builtin_trap(); }\n')
    def portable(text):
        text='#include <string.h>\n'+text
        text=text.replace('wchar_t','char').replace('wmain','main').replace('_wfopen','fopen')
        text=text.replace('_wtoi','atoi').replace('wcscmp','strcmp').replace('swprintf','snprintf')
        text=re.sub(r'\bL(?=")','',text).replace('%ls','%s')
        return text
    for name in ('seek-oracle','pcm-bounds-oracle','vorbis-native-oracle','aiff-sparse-oracle','rf64-sparse-oracle'):
        source=generated/f'{name}.c'; source.write_text(portable((TESTS/f'{name}.c').read_text()))
        run(['xcrun','clang','-arch','arm64','-O2','-ffp-contract=off','-I',TESTS/'mac',source,
             init,libpath,'-o',generated/f'{name}.exe'])
    base=OUT/'reference'; v=base/'libvorbis-1.3.7'; o=base/'libogg-1.3.6'
    names=('mdct smallft block envelope window lsp lpc analysis synthesis psy info floor1 floor0 '
           'res0 mapping0 registry codebook sharedbook lookup bitrate vorbisfile').split()
    sources=[v/'lib'/f'{n}.c' for n in names]+[o/'src'/f'{n}.c' for n in ('bitwise','framing')]
    source=generated/'vorbis-native-reference.c'
    source.write_text(portable((TESTS/'vorbis-native-reference.c').read_text()))
    run(['xcrun','clang','-arch','arm64','-O2','-ffp-contract=off','-Wno-cpp',
         '-I',v/'include','-I',v/'lib','-I',o/'include',source,*sources,'-o',generated/'vorbis-native-reference.exe'])
    records=[]
    # Keep the authoritative JS tests unchanged; only adapt test-artifact paths
    # and the optional Vorbis encoder when FFmpeg was built without libvorbis.
    has_vorbis='libvorbis' in run(['ffmpeg','-hide_banner','-encoders'])
    for name in suites or ('wav-layout','flac-layout','rf64','aiff','vorbis-multichannel'):
        script=(TESTS/f'{name}-fixtures.js').read_text()
        script=script.replace("path.join(__dirname,'reference','vorbis-reference-hashes.json')",
                              json.dumps(str(TESTS/'reference/vorbis-reference-hashes.json')))
        script=script.replace("name+'.obj'","'obj/'+name+'.o'")
        if name=='vorbis-multichannel' and not has_vorbis:
            old="function ff(args){return run('ffmpeg',['-hide_banner','-loglevel','error','-y',...args]);}"
            new="""function ff(args){
                if(args.includes('libvorbis')){
                    const m=path.basename(args.at(-1)).match(/^modern-(\\d+)-(\\d+)-q(\\d+)/);
                    if(!m)throw Error('Unknown Vorbis encoder fixture');
                    return run(ENCODER,['encode',args.at(-1),m[1],m[2],'1.373',String(Number(m[3])/10)]);
                }
                return run('ffmpeg',['-hide_banner','-loglevel','error','-y',...args]);
            }""".replace('ENCODER',json.dumps(str(vorbis_encoder)))
            assert old in script
            script=script.replace(old,new).replace('modern libvorbis encoder','pinned Xiph libvorbis 1.3.7 encoder')
        path=generated/f'{name}-fixtures.js'; path.write_text(script)
        fixtures=OUT/'layout-fixtures'/name
        args=[OUT/'lamp-cli',generated/'seek-oracle.exe',fixtures,generated/'pcm-bounds-oracle.exe']\
             if name in ('wav-layout','flac-layout') else [OUT/'lamp-cli',generated,fixtures]
        run(['node',path,*args],timeout=1800,live=True)
        report=next(fixtures.glob('*-verification.json'))
        data=json.loads(report.read_text())
        data['platform']='macOS arm64'
        data['test_adaptations']=['UTF-8 paths and native Apple ABI','native protected page size',
            'live malloc bytes replace Windows private commit','APFS sparse holes replace NTFS ioctl']
        if name=='vorbis-multichannel' and not has_vorbis:
            data['test_adaptations'].append('pinned Xiph encoder replaces unavailable FFmpeg libvorbis encoder')
        report.write_text(json.dumps(data,indent=2)+'\n')
        summary={k:data[k] for k in ('files','sparse_files','seek_checks','native_seek_checks','stereo_seek_checks','rejections') if k in data}
        records.append({'suite':name,'report':str(report.relative_to(OUT)),'summary':summary})
        print(f'Native {name} layouts: passed',flush=True)
    return records


def terminal_checks(path):
    records=[]
    for mode in ('q','sigint'):
        master,slave=pty.openpty()
        original=termios.tcgetattr(slave)
        process=subprocess.Popen([OUT/'lamp-cli',path],stdin=slave,stdout=slave,stderr=slave)
        try:
            time.sleep(.3); assert process.poll() is None
            os.write(master,b' ')
            time.sleep(2.1); assert process.poll() is None, 'Space must leave playback paused past natural EOF'
            if mode=='q': os.write(master,b' q')
            else: process.send_signal(signal.SIGINT)
            assert process.wait(timeout=3)==0
            restored=termios.tcgetattr(slave)
            # Darwin sets the transient PENDIN state when canonical processing
            # resumes. Check all settings, excluding only this kernel input state.
            restored[3] &= ~termios.PENDIN
            original[3] &= ~termios.PENDIN
            assert restored==original, ('Terminal settings must be restored',mode,original,restored)
            records.append({'stop':mode,'pause_past_duration':True,'terminal_restored':True,
                            'excluded_kernel_state':'Darwin PENDIN; all configuration/control fields checked'})
        finally:
            if process.poll() is None: process.kill();process.wait()
            os.close(master);os.close(slave)
    return records


def main():
    global OUT
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--opus',action='store_true')
    p.add_argument('--audio',action='store_true')
    p.add_argument('--ui',action='store_true')
    p.add_argument('--layouts',action='store_true',help='full WAV/FLAC/RF64/AIFF/Vorbis precision/layout suites')
    p.add_argument('--layout-suites',nargs='+',choices=['wav-layout','flac-layout','rf64','aiff','vorbis-multichannel'])
    p.add_argument('--skip-build',action='store_true')
    p.add_argument('--binary-directory',type=Path,default=OUT)
    p.add_argument('--terminal-only',action='store_true',help='focused pseudo-terminal check using existing playback.wav')
    p.add_argument('--resume',action='store_true',help='keep completed report stages when binary identities match; add requested checks')
    args=p.parse_args()
    OUT=args.binary_directory.resolve()
    assert sys.platform=='darwin' and platform.machine()=='arm64'
    if args.terminal_only:
        print(terminal_checks(OUT/'fixtures/playback.wav'));return
    if not args.skip_build:
        if args.resume: p.error('--resume requires --skip-build')
        print(run([sys.executable,ROOT/'tools/build-mac.py','--output',OUT]),flush=True)
    lib=library()
    vorbis=vorbis_reference()
    report_path=OUT/'macos-verification.json'
    current_runtime=runtime_checks()
    if args.resume:
        report=json.loads(report_path.read_text())
        assert report['runtime']==current_runtime, 'Cannot resume checks for different binaries'
    else: report={}
    report.update({'result':'in_progress','platform':platform.platform(),'architecture':platform.machine(),
                   'runtime':current_runtime,'decoder':decoder_checks(lib, vorbis)})
    def save(): report_path.write_text(json.dumps(report,indent=2)+'\n')
    save()
    print('Native PCM, seeks, Unicode, protected exports and mutation checks passed.',flush=True)
    if args.opus:
        report['opus']=opus_checks(lib);save()
    if args.layouts or args.layout_suites:
        report['layouts']=layout_checks(lib,vorbis,args.layout_suites);save()
    if args.audio:
        report['audio']=[]
        target=OUT/'mac-playback'
        run(['xcrun','clang','-arch','arm64','-mmacosx-version-min=12.0',TESTS/'mac-playback.c',lib,'-o',target])
        fixtures=OUT/'fixtures'
        for suffix,codec in [('wav','pcm_s16le'),('aiff','pcm_s24be'),('flac','flac'),
                             ('mp3','libmp3lame'),('ogg','libvorbis'),('opus','libopus')]:
            path=fixtures/f'playback.{suffix}'
            if suffix == 'ogg': run([vorbis,'encode',path,44100,2,2])
            else: run(['ffmpeg','-v','error','-f','lavfi','-i','sine=frequency=440:duration=2',
                 '-ac','2','-c:a',codec,'-y',path])
            result=run([target,path],timeout=30)
            report.setdefault('audio',[]).append({'format':suffix,'stats':result})
            print(f'Core Audio {suffix}: passed',flush=True)
        report['terminal']=terminal_checks(fixtures/'playback.wav')
        empty=fixtures/'empty.wav'
        with wave.open(str(empty),'wb') as f:
            f.setnchannels(2);f.setsampwidth(2);f.setframerate(48000);f.writeframes(b'')
        report['audio_empty']=run([target,empty,'--empty'],timeout=10)
    if args.ui:
        run([OUT/'lamp','--ui-smoke',TESTS/'fixtures/tone.flac'],timeout=10)
        report['ui']={'launch_playback_timer_and_exit':'passed',
                      'desktop_interactions':'Open dialog, Finder drops and Retina interaction need manual verification'}
    report['result']='passed'
    save()
    print(report_path)


if __name__=='__main__':main()
